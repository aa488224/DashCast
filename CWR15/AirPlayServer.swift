import Foundation
import Network

protocol AirPlayServerDelegate: AnyObject {
    func airPlayServer(_ server: AirPlayServer, didConfigure avcC: Data)
    func airPlayServer(_ server: AirPlayServer, didReceive frame: Data, keyframe: Bool)
    func airPlayServer(_ server: AirPlayServer, didUpdate status: String)
}

/// 把本机伪装成一台 AirPlay 接收器：广播 `_airplay._tcp`，应答 pair / fp-setup / SETUP，
/// 然后由 AirPlayMirror 接收并解密画面。协议实现对齐 RPiPlay（无 MFi 芯片依赖）。
final class AirPlayServer: NSObject, NetServiceDelegate {

    static let shared = AirPlayServer()

    weak var delegate: AirPlayServerDelegate?

    private let queue = DispatchQueue(label: "dashcast.airplay.server")
    private let pairing = AirPlayPairing()
    private let fairPlay = AirPlayFairPlay()
    private let mirror = AirPlayMirror()

    private var listener: NWListener?
    private var service: NetService?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var port: UInt16 = 7000
    private var portCandidates: [UInt16] = [7000, 7100, 7101, 7102]
    private var aesKey: Data?
    private var aesIV: Data?

    private(set) var running = false
    private(set) var deviceName = "DashCast"

    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        init(_ connection: NWConnection) { self.connection = connection }
    }

    // MARK: 生命周期

    func start(name: String = "DashCast") {
        guard !running else { return }
        deviceName = name
        fairPlay.reset()
        aesKey = nil
        aesIV = nil
        mirror.onFormat = { [weak self] avcC in
            guard let self else { return }
            DispatchQueue.main.async { self.delegate?.airPlayServer(self, didConfigure: avcC) }
        }
        mirror.onFrame = { [weak self] frame, keyframe in
            guard let self else { return }
            DispatchQueue.main.async { self.delegate?.airPlayServer(self, didReceive: frame, keyframe: keyframe) }
        }
        running = true
        Log.shared.info("[AirPlay] 启动接收屏，名称「\(name)」")
        startListener()
    }

    func stop() {
        running = false
        listener?.cancel()
        listener = nil
        service?.stop()
        service = nil
        for (_, client) in clients { client.connection.cancel() }
        clients.removeAll()
        mirror.stop()
        Log.shared.info("[AirPlay] 已停止接收")
    }

    private func startListener() {
        guard running else { return }
        guard let candidate = portCandidates.first else {
            Log.shared.error("[AirPlay] 7000/7100-7102 都被占用，启动失败")
            report("端口被占用，无法启动")
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let endpoint = NWEndpoint.Port(rawValue: candidate) else { return }
        do {
            let listener = try NWListener(using: parameters, on: endpoint)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = candidate
                    Log.shared.info("[AirPlay] 控制通道已监听 \(candidate)")
                    self.publishService(port: candidate)
                case .failed(let error):
                    Log.shared.error("[AirPlay] 端口 \(candidate) 启动失败：\(error.localizedDescription)")
                    self.portCandidates.removeAll { $0 == candidate }
                    self.listener?.cancel()
                    self.listener = nil
                    self.startListener()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            Log.shared.error("[AirPlay] 无法监听 \(candidate)：\(error.localizedDescription)")
            portCandidates.removeAll { $0 == candidate }
            startListener()
        }
    }

    private func publishService(port: UInt16) {
        service?.stop()
        let service = NetService(domain: "local.", type: "_airplay._tcp.", name: deviceName, port: Int32(port))
        service.delegate = self
        let txt = txtRecord()
        service.setTXTRecord(txt)
        service.publish()
        self.service = service
        report("已广播「\(deviceName)」，在控制中心 › 屏幕镜像里选择它")
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients[ObjectIdentifier(client)] = client
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive(client)
            case .failed, .cancelled:
                self.clients.removeValue(forKey: ObjectIdentifier(client))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { client.buffer.append(data) }
            self.drain(client)
            if complete || error != nil {
                client.connection.cancel()
                self.clients.removeValue(forKey: ObjectIdentifier(client))
                return
            }
            if self.clients[ObjectIdentifier(client)] != nil { self.receive(client) }
        }
    }

    // MARK: 请求解析

    private func drain(_ client: Client) {
        while true {
            let buffer = client.buffer
            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerText = String(decoding: buffer[buffer.startIndex..<headerRange.lowerBound], as: UTF8.self)
            let lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { client.buffer.removeAll(); return }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { client.buffer.removeAll(); return }
            let method = String(parts[0])
            let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? "/"

            var cseq = "0"
            var contentLength = 0
            for line in lines.dropFirst() {
                let lower = line.lowercased()
                if lower.hasPrefix("cseq:") {
                    cseq = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "0"
                } else if lower.hasPrefix("content-length:") {
                    contentLength = Int(line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
                }
            }

            let headerBytes = buffer.distance(from: buffer.startIndex, to: headerRange.upperBound)
            guard buffer.count >= headerBytes + contentLength else { return }
            let bodyStart = headerRange.upperBound
            let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            client.buffer = Data(buffer[bodyEnd...])

            if path != "/feedback" {
                Log.shared.info("[AirPlay] \(method) \(path)\(body.isEmpty ? "" : "（\(body.count) 字节）")")
            }
            handle(method: method, path: path, body: body, cseq: cseq, client: client)
        }
    }

    private func handle(method: String, path: String, body: Data, cseq: String, client: Client) {
        switch (method, path) {
        case ("GET", "/info"):
            respond(client, cseq: cseq, type: "application/x-apple-binary-plist", body: infoPlist())

        case ("POST", "/pair-setup"):
            guard let reply = pairing.pairSetup(body) else {
                respond(client, cseq: cseq, type: nil, body: nil)
                return
            }
            respond(client, cseq: cseq, type: "application/octet-stream", body: reply)

        case ("POST", "/pair-verify"):
            guard let reply = pairing.pairVerify(body) else {
                respond(client, cseq: cseq, type: nil, body: nil)
                return
            }
            respond(client, cseq: cseq, type: "application/octet-stream", body: reply)

        case ("POST", "/fp-setup"):
            if body.count == 16 {
                guard let reply = fairPlay.setup(body) else {
                    respond(client, cseq: cseq, type: nil, body: nil)
                    return
                }
                respond(client, cseq: cseq, type: "application/octet-stream", body: reply)
            } else {
                guard let reply = fairPlay.handshake(body) else {
                    respond(client, cseq: cseq, type: nil, body: nil)
                    return
                }
                respond(client, cseq: cseq, type: "application/octet-stream", body: reply)
            }

        case ("OPTIONS", _):
            respond(client, cseq: cseq, type: nil, body: nil,
                    extra: [("Public", "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER")])

        case ("SETUP", _):
            handleSetup(body: body, cseq: cseq, client: client)

        case ("POST", "/feedback"), ("RECORD", _), ("FLUSH", _), ("GET_PARAMETER", _), ("SET_PARAMETER", _):
            respond(client, cseq: cseq, type: nil, body: nil)

        case ("TEARDOWN", _):
            Log.shared.info("[AirPlay] 发送端结束投屏")
            mirror.stop()
            respond(client, cseq: cseq, type: nil, body: nil)
            report("发送端已断开，等待下一次投屏")

        default:
            Log.shared.info("[AirPlay] 未处理的请求 \(method) \(path)，按空成功返回")
            respond(client, cseq: cseq, type: nil, body: nil)
        }
    }

    private func handleSetup(body: Data, cseq: String, client: Client) {
        var request: [String: Any] = [:]
        if let parsed = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil) {
            request = parsed as? [String: Any] ?? [:]
        }

        if let ekey = request["ekey"] as? Data {
            aesKey = fairPlay.decryptKey(ekey)
            Log.shared.info("[AirPlay] SETUP 携带 ekey（\(ekey.count) 字节），AES 密钥\(aesKey == nil ? "推导失败" : "已推导")")
        }
        if let eiv = request["eiv"] as? Data { aesIV = eiv }

        var response: [String: Any] = [:]
        var streams: [[String: Any]] = []

        if let requested = request["streams"] as? [[String: Any]] {
            for stream in requested {
                let type = Self.uint(stream["type"]) ?? 0
                Log.shared.info("[AirPlay] SETUP 请求流类型 \(type)")
                if type == 110 {
                    let connectionID = Self.uint(stream["streamConnectionID"]) ?? 0
                    guard let key = aesKey, let secret = pairing.sharedSecret else {
                        Log.shared.error("[AirPlay] 缺少 AES 密钥或 ECDH 密钥，无法建立镜像通道")
                        report("密钥缺失，无法建立镜像通道")
                        continue
                    }
                    if let ports = mirror.start(aesKey: key, aesIV: aesIV ?? Data(repeating: 0, count: 16),
                                                ecdhSecret: secret, streamID: connectionID) {
                        streams.append(["type": 110, "dataPort": Int(ports.data)])
                        response["timingPort"] = Int(ports.timing)
                        report("已建立镜像通道，等待画面")
                    }
                } else if type == 96 {
                    streams.append(["type": 96, "dataPort": 0, "controlPort": 0])
                }
            }
        }

        if !streams.isEmpty { response["streams"] = streams }
        response["eventPort"] = Int(port)
        response["timingPort"] = response["timingPort"] ?? 0

        let reply = (try? PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0)) ?? Data()
        respond(client, cseq: cseq, type: "application/x-apple-binary-plist", body: reply)
    }

    // MARK: 应答

    private func respond(_ client: Client, cseq: String, type: String?, body: Data?, extra: [(String, String)] = []) {
        var head = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nServer: AirTunes/220.68\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        for (key, value) in extra { head += "\(key): \(value)\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n\r\n"
        var payload = Data(head.utf8)
        if let body { payload.append(body) }
        client.connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    // MARK: 广播内容

    private func txtRecord() -> Data {
        let fields: [(String, String)] = [
            ("deviceid", Self.deviceID),
            ("features", "0x5A7FFEE6"),
            ("flags", "0x4"),
            ("model", Self.modelName),
            ("pk", Self.publicKeyHex),
            ("pi", Self.protocolID),
            ("srcvers", "220.68"),
            ("vv", "2")
        ]
        var data = Data()
        for (key, value) in fields {
            let entry = Data("\(key)=\(value)".utf8)
            guard entry.count < 255 else { continue }
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }

    private func infoPlist() -> Data {
        let features: UInt64 = (UInt64(0x1E) << 32) | UInt64(0x5A7FFFF7)
        var info: [String: Any] = [
            "txtAirPlay": txtRecord(),
            "features": NSNumber(value: features),
            "name": deviceName,
            "pi": Self.protocolID,
            "vv": NSNumber(value: 2),
            "statusFlags": NSNumber(value: 68),
            "keepAliveLowPower": true,
            "keepAliveSendStatsAsBody": true,
            "sourceVersion": "220.68",
            "pk": AirPlayCrypto.hex(Self.publicKeyHex),
            "deviceID": Self.deviceID,
            "macAddress": Self.deviceID,
            "model": Self.modelName,
            "audioFormats": [
                ["type": NSNumber(value: 100), "audioInputFormats": NSNumber(value: 67108860), "audioOutputFormats": NSNumber(value: 67108860)],
                ["type": NSNumber(value: 101), "audioInputFormats": NSNumber(value: 67108860), "audioOutputFormats": NSNumber(value: 67108860)]
            ],
            "audioLatencies": [
                ["type": NSNumber(value: 100), "audioType": "default", "inputLatencyMicros": NSNumber(value: 0), "outputLatencyMicros": NSNumber(value: 0)],
                ["type": NSNumber(value: 101), "audioType": "default", "inputLatencyMicros": NSNumber(value: 0), "outputLatencyMicros": NSNumber(value: 0)]
            ],
            "displays": [
                [
                    "uuid": "e0ff8a27-6738-3d56-8a16-cc53aacee925",
                    "widthPhysical": NSNumber(value: 0),
                    "heightPhysical": NSNumber(value: 0),
                    "width": NSNumber(value: 1920),
                    "height": NSNumber(value: 1080),
                    "widthPixels": NSNumber(value: 1920),
                    "heightPixels": NSNumber(value: 1080),
                    "rotation": false,
                    "refreshRate": 1.0 / 60.0,
                    "overscanned": true,
                    "features": NSNumber(value: 14)
                ]
            ]
        ]
        info["features"] = NSNumber(value: features)
        return (try? PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)) ?? Data()
    }

    // MARK: 工具

    private func report(_ text: String) {
        Log.shared.info("[AirPlay] \(text)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.airPlayServer(self, didUpdate: text)
        }
    }

    private static func uint(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let number = value as? UInt64 { return number }
        if let number = value as? Int { return UInt64(number) }
        return nil
    }

    private static let deviceID = "AA:BB:CC:DD:EE:01"
    private static let modelName = "AppleTV2,1"
    private static let protocolID = "2e388006-13ba-4041-9a67-25dd4a43d536"
    private static let publicKeyHex = "b07727d6f6cd6e08b58ede525ec3cdeaa252ad9f683feb212ef8a205246554e7"

    // MARK: NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        Log.shared.info("[AirPlay] 广播成功：\(sender.name)（\(sender.domain)）")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Log.shared.error("[AirPlay] 广播失败：\(errorDict)")
        report("广播失败，检查本地网络权限")
    }
}
