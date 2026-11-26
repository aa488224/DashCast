import Foundation

struct VideoFormatInfo {
    let width: Int
    let height: Int
    let codec: String
    let avcC: Data?
}

protocol StreamClientDelegate: AnyObject {
    func streamClient(_ client: StreamClient, didChange state: StreamClient.State, detail: String)
    func streamClient(_ client: StreamClient, didReceive format: VideoFormatInfo)
    func streamClient(_ client: StreamClient, didReceiveVideo payload: Data, keyframe: Bool, timestampUs: UInt64)
    func streamClientDidRequestKeyframe(_ client: StreamClient)
}

/// 连主手机上的 CarWithin 浏览器输出端口（默认 9888/stream），
/// 握手声明 decoder=webcodecs，收「1 字节类型 + 8 字节时间戳 + AVCC 样本」。
final class StreamClient {

    enum State: Equatable {
        case idle
        case connecting
        case handshaking
        case streaming
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "正在连接"
            case .handshaking: return "握手中"
            case .streaming: return "已连接"
            case .failed(let reason): return "连接失败：\(reason)"
            }
        }
    }

    weak var delegate: StreamClientDelegate?

    private let queue = DispatchQueue(label: "cwr15.stream")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var heartbeat: DispatchSourceTimer?
    private var stopped = true
    private var state: State = .idle

    private var receivedFrames = 0
    private var receivedBytes = 0
    private var lastStats = Date()
    private var pingFailures = 0
    private var lastFormat: VideoFormatInfo?
    private var keyframeRequests = 0

    // MARK: 生命周期

    func start(host: String, port: Int) {
        stop(notify: false)
        guard let url = Self.makeURL(host: host, port: port) else {
            setState(.failed("地址无效"), detail: "无法解析地址：\(host)")
            return
        }
        stopped = false
        pingFailures = 0
        receivedFrames = 0
        receivedBytes = 0
        lastStats = Date()
        setState(.connecting, detail: "正在连接 \(url.host ?? host):\(url.port ?? port)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 60 * 60 * 12
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "CarWithinReceiver/1.0"]

        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 1
        opQueue.name = "cwr15.ws"
        let session = URLSession(configuration: config, delegate: nil, delegateQueue: opQueue)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024

        self.session = session
        self.task = task
        task.resume()

        setState(.handshaking, detail: "TCP 已建立，发送握手")
        sendHandshake()
        receiveLoop()
        startHeartbeat()
    }

    func stop(notify: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.heartbeat?.cancel()
            self.heartbeat = nil
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            self.lastFormat = nil
            if notify {
                self.setState(.idle, detail: "已断开")
            } else {
                self.state = .idle
            }
        }
    }

    func requestKeyframe() {
        queue.async { [weak self] in
            guard let self else { return }
            self.keyframeRequests += 1
            self.sendJSON(["type": "keyframe", "reason": "解码器需要关键帧"])
            if self.keyframeRequests <= 3 || self.keyframeRequests % 10 == 0 {
                self.log("请求关键帧（第 \(self.keyframeRequests) 次）")
            }
        }
    }

    // MARK: 内部

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveLoop()
                case .failure(let error):
                    self.fail("接收失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleText(text)
        case .data(let data):
            handleBinary(data)
        @unknown default:
            log("收到未知消息类型")
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            log("收到无法解析的文本：\(text.prefix(120))")
            return
        }
        switch type {
        case "format":
            let avcC = (object["description"] as? String).flatMap { Data(base64Encoded: $0) }
            let info = VideoFormatInfo(
                width: (object["width"] as? NSNumber)?.intValue ?? 0,
                height: (object["height"] as? NSNumber)?.intValue ?? 0,
                codec: object["codec"] as? String ?? "avc1",
                avcC: avcC)
            lastFormat = info
            let name = object["name"] as? String ?? info.codec
            log("视频格式：\(name) \(info.width)×\(info.height)，avcC \(avcC?.count ?? 0) 字节")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.streamClient(self, didReceive: info)
            }
        case "status":
            let value = object["text"] as? String ?? ""
            log("服务端状态：\(value)")
        case "error", "info":
            let value = object["text"] as? String ?? ""
            log("服务端\(type == "error" ? "错误" : "信息")：\(value)")
        default:
            log("服务端消息：\(type)")
        }
    }

    private func handleBinary(_ data: Data) {
        guard !data.isEmpty else { return }
        receivedBytes += data.count

        let kind = data[data.startIndex]
        switch kind {
        case 0, 1, 4, 5:
            guard data.count >= 9 else { return }
            var timestamp: UInt64 = 0
            var payload = Data()
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                timestamp = base.loadUnaligned(fromByteOffset: 1, as: UInt64.self).bigEndian
                payload = Data(bytes: base + 9, count: raw.count - 9)
            }
            // 4/5 是带音频时钟的 fMP4 分片，本版本不走这条路径。
            guard kind == 0 || kind == 1 else {
                if receivedFrames == 0 { log("收到 fMP4 分片，当前握手不应出现") }
                return
            }
            guard !payload.isEmpty else { return }
            receivedFrames += 1
            if receivedFrames == 1 {
                setState(.streaming, detail: "开始接收画面")
            }
            statsIfNeeded()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.streamClient(self, didReceiveVideo: payload, keyframe: kind == 1, timestampUs: timestamp)
            }
        case 3:
            // 音频包：3 + 时间戳 + 采样率 + 声道 + PCM16LE。当前版本只记录，不播放。
            if receivedFrames < 2 { log("收到音频包（本版本未启用声音）") }
        default:
            if receivedBytes < 4096 { log("未知二进制类型 \(kind)，长度 \(data.count)") }
        }
    }

    private func statsIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastStats) >= 5 else { return }
        lastStats = now
        let size = lastFormat.map { "\($0.width)×\($0.height)" } ?? "?"
        log("运行中：\(receivedFrames) 帧，\(receivedBytes / 1024) KB，\(size)")
    }

    private func sendHandshake() {
        sendJSON([
            "type": "ready",
            "decoder": "webcodecs",
            "viewer": UUID().uuidString,
            "audioClock": false
        ])
        let size = Settings.reportSize
        sendJSON([
            "type": "display",
            "w": size.width,
            "h": size.height,
            "sw": size.width,
            "sh": size.height,
            "dpr": 1,
            "hz": 60,
            "h265": false,
            "fullscreen": true
        ])
        log("已发送握手：webcodecs，上报 \(size.width)×\(size.height)")
    }

    private func sendJSON(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        send(.string(text))
    }

    func sendTouch(points: [(id: Int, x: Double, y: Double)]) {
        let list = points.map { ["id": $0.id, "x": $0.x, "y": $0.y] as [String: Any] }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.sendJSON(["type": "touches", "points": list])
        }
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        guard let task else { return }
        task.send(message) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async {
                guard !self.stopped else { return }
                self.log("发送失败：\(error.localizedDescription)")
            }
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, let task = self.task else { return }
            task.sendPing { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped else { return }
                    if let error {
                        self.pingFailures += 1
                        self.log("心跳失败（\(self.pingFailures)/2）：\(error.localizedDescription)")
                        if self.pingFailures >= 2 { self.fail("心跳超时") }
                    } else {
                        self.pingFailures = 0
                    }
                }
            }
        }
        heartbeat = timer
        timer.resume()
    }

    private func fail(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        heartbeat?.cancel(); heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        session?.invalidateAndCancel(); session = nil
        setState(.failed(reason), detail: reason)
    }

    private func setState(_ new: State, detail: String) {
        state = new
        log("状态：\(new.text)\(detail.isEmpty ? "" : " · \(detail)")")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.streamClient(self, didChange: new, detail: detail)
        }
    }

    private func log(_ message: String) {
        Log.shared.info("[流] \(message)")
    }

    // MARK: 地址

    static func makeURL(host: String, port: Int) -> URL? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        for prefix in ["ws://", "wss://", "http://", "https://"] where h.lowercased().hasPrefix(prefix) {
            h = String(h.dropFirst(prefix.count))
        }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        var finalPort = (1...65535).contains(port) ? port : 9888
        if h.filter({ $0 == ":" }).count == 1, let colon = h.lastIndex(of: ":") {
            let part = String(h[h.index(after: colon)...])
            if let value = Int(part), (1...65535).contains(value) {
                finalPort = value
                h = String(h[..<colon])
            }
        }
        guard !h.isEmpty else { return nil }
        return URL(string: "ws://\(h):\(finalPort)/stream")
    }
}
