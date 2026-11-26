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

    // HTTP 原始流（Annex-B）
    private var rawSession: URLSession?
    private var rawTask: URLSessionDataTask?
    private var rawDelegate: RawDelegate?
    private var rawBytes: [UInt8] = []
    private var rawSPS: Data?
    private var rawPPS: Data?
    private var rawFormatSent = false
    private var rawTouchNoticed = false

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

        if Settings.transport == .raw {
            startRaw(host: host, port: port)
            return
        }

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

        setState(.handshaking, detail: "已发起连接，等待 WebSocket 升级")
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
            self.rawTask?.cancel()
            self.rawTask = nil
            self.rawSession?.invalidateAndCancel()
            self.rawSession = nil
            self.rawDelegate = nil
            self.rawBytes.removeAll()
            self.rawSPS = nil
            self.rawPPS = nil
            self.rawFormatSent = false
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
            guard let self, Settings.transport == .webSocket else { return }
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
            let lower = info.codec.lowercased()
            if lower.hasPrefix("hvc1") || lower.hasPrefix("hev1") || lower.contains("265") || lower.contains("hevc") {
                log("主端在用 H.265 出图，A9 没有 HEVC 硬解，必须把主手机的视频编码改成 H.264")
            }
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
        if receivedBytes == data.count {
            log("收到第一个二进制包：类型 \(kind)，\(data.count) 字节")
        }
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
        guard Settings.reportsDisplaySize else {
            log("已发送握手：webcodecs；不上报尺寸，沿用主端当前出图")
            scheduleFirstFrameCheck()
            return
        }
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
        scheduleFirstFrameCheck()
    }

    /// 主端只有在关键帧到来时才会下发 format 与视频帧。
    /// 迟迟没有首帧就主动催一次，避免一直卡在「等待关键帧」。
    private func scheduleFirstFrameCheck() {
        for (delay, round) in [(4.0, 1), (9.0, 2)] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.stopped, self.receivedFrames == 0 else { return }
                if self.receivedBytes == 0 {
                    self.log("已连接 \(Int(delay)) 秒没有收到任何数据：主手机可能没在推流，或端口不对")
                } else {
                    self.log("已连接 \(Int(delay)) 秒仍无画面，第 \(round) 次请求关键帧")
                }
                self.sendJSON(["type": "keyframe", "reason": "接收端等待首帧"])
            }
        }
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
            guard Settings.transport == .webSocket else {
                if !self.rawTouchNoticed {
                    self.rawTouchNoticed = true
                    self.log("原始流是单向的，触控回传不可用；需要触控请改回 WebSocket")
                }
                return
            }
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
        rawTask?.cancel(); rawTask = nil
        rawSession?.invalidateAndCancel(); rawSession = nil
        rawDelegate = nil
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

    // MARK: HTTP 原始流（Annex-B）

    private final class RawDelegate: NSObject, URLSessionDataDelegate {
        var onData: ((Data) -> Void)?
        var onEnd: ((String) -> Void)?

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            onData?(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { onEnd?("原始流中断：\(error.localizedDescription)") }
            else { onEnd?("主手机结束了原始流") }
        }
    }

    private func startRaw(host: String, port: Int) {
        rawBytes.removeAll()
        rawSPS = nil
        rawPPS = nil
        rawFormatSent = false
        guard let url = URL(string: "http://\(host):\(port)/video.h264") else {
            fail("地址无效"); return
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60 * 60 * 12
        config.httpAdditionalHeaders = ["User-Agent": "DashCast/1.0"]
        let delegate = RawDelegate()
        delegate.onData = { [weak self] data in self?.queue.async { self?.consumeRaw(data) } }
        delegate.onEnd = { [weak self] reason in
            self?.queue.async {
                guard let self, !self.stopped else { return }
                self.fail(reason)
            }
        }
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: url)
        rawDelegate = delegate
        rawSession = session
        rawTask = task
        task.resume()
        setState(.handshaking, detail: "已请求原始流 /video.h264")
        log("传输方式：HTTP 原始流 \(url.absoluteString)（不支持触控回传）")
        scheduleFirstFrameCheck()
    }

    private func consumeRaw(_ data: Data) {
        guard !stopped else { return }
        receivedBytes += data.count
        if receivedBytes == data.count {
            log("收到第一批数据：\(data.count) 字节")
        }
        rawBytes.append(contentsOf: data)
        parseRawNALUnits()
    }

    /// 按起始码切 NALU；末尾不完整的片段留到下一批数据。
    private func parseRawNALUnits() {
        while true {
            guard let first = Self.startCode(in: rawBytes, from: 0) else {
                if rawBytes.count > 4 { rawBytes.removeFirst(rawBytes.count - 4) }
                return
            }
            let payloadStart = first.offset + first.length
            guard payloadStart <= rawBytes.count,
                  let next = Self.startCode(in: rawBytes, from: payloadStart) else {
                if first.offset > 0 { rawBytes.removeFirst(first.offset) }
                return
            }
            let nal = Array(rawBytes[payloadStart..<next.offset])
            rawBytes.removeFirst(next.offset)
            if !nal.isEmpty { handleNAL(nal) }
        }
    }

    private static func startCode(in bytes: [UInt8], from index: Int) -> (offset: Int, length: Int)? {
        guard bytes.count >= index + 3 else { return nil }
        var i = index
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { return (i, 3) }
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 { return (i, 4) }
            }
            i += 1
        }
        return nil
    }

    private func handleNAL(_ nal: [UInt8]) {
        guard let header = nal.first else { return }
        switch header & 0x1F {
        case 7:
            rawSPS = Data(nal)
            log("原始流 SPS：\(nal.count) 字节")
            emitRawFormatIfNeeded()
        case 8:
            rawPPS = Data(nal)
            log("原始流 PPS：\(nal.count) 字节")
            emitRawFormatIfNeeded()
        case 1, 5:
            guard rawFormatSent else { return }
            var packet = Data()
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
            packet.append(contentsOf: nal)
            receivedFrames += 1
            let keyframe = (header & 0x1F) == 5
            if receivedFrames == 1 {
                setState(.streaming, detail: "开始接收画面")
                log("原始流首帧已到达（\(keyframe ? "关键帧" : "差帧")）")
            }
            statsIfNeeded()
            let timestamp = UInt64(receivedFrames) * 16_667
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.streamClient(self, didReceiveVideo: packet, keyframe: keyframe, timestampUs: timestamp)
            }
        default:
            break
        }
    }

    private func emitRawFormatIfNeeded() {
        guard !rawFormatSent, let sps = rawSPS, let pps = rawPPS, sps.count > 3 else { return }
        var avcC = Data([1, sps[1], sps[2], sps[3], 0xFF, 0xE1])
        avcC.append(contentsOf: [UInt8(sps.count >> 8 & 0xFF), UInt8(sps.count & 0xFF)])
        avcC.append(sps)
        avcC.append(1)
        avcC.append(contentsOf: [UInt8(pps.count >> 8 & 0xFF), UInt8(pps.count & 0xFF)])
        avcC.append(pps)
        rawFormatSent = true
        let info = VideoFormatInfo(width: 0, height: 0, codec: "avc1", avcC: avcC)
        lastFormat = info
        log("原始流参数集就绪：合成 avcC \(avcC.count) 字节")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.streamClient(self, didReceive: info)
        }
    }

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
