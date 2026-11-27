import Foundation
import Darwin

/// 接收 iOS 发来的 AirPlay 镜像流：UDP 包 → AES-CTR 解密 → AVCC 帧交给硬解。
/// 包格式与 RPiPlay 的 raop_rtp_mirror 一致：128 字节头 + payload，
/// 头里 offset 0 是 payload 长度，offset 4 是类型（0=视频帧，1=SPS/PPS）。
final class AirPlayMirror {

    var onFormat: ((Data) -> Void)?
    var onFrame: ((Data, Bool) -> Void)?
    var onStateChange: ((String) -> Void)?

    private var dataFD: Int32 = -1
    private var timingFD: Int32 = -1
    private var stream: AirPlayCTRStream?
    private let queue = DispatchQueue(label: "dashcast.airplay.mirror")
    private var frames = 0
    private var packets = 0
    private var lastLog = Date()
    private var configuredSize: String?

    // MARK: 启动 / 停止

    /// 返回 (视频端口, 时间同步端口)。
    func start(aesKey: Data, aesIV: Data, ecdhSecret: Data, streamID: UInt64) -> (data: UInt16, timing: UInt16)? {
        stop()

        var material = Data(aesKey.prefix(16))
        material.append(ecdhSecret.prefix(32))
        let eaes = Data(AirPlayCrypto.sha1(material).prefix(16))

        var keySeed = Data("AirPlayStreamKey\(streamID)".utf8)
        keySeed.append(eaes)
        var ivSeed = Data("AirPlayStreamIV\(streamID)".utf8)
        ivSeed.append(eaes)

        let key = Data(AirPlayCrypto.sha1(keySeed).prefix(16))
        let iv = Data(AirPlayCrypto.sha1(ivSeed).prefix(16))
        _ = aesIV // eiv 只在音频流用到，镜像流的 IV 由上面推导

        guard let ctr = AirPlayCTRStream(key: key, iv: iv) else { return nil }
        stream = ctr
        configuredSize = nil
        frames = 0
        packets = 0

        guard let (dfd, dport) = Self.bindUDP(), let (tfd, tport) = Self.bindUDP() else {
            Log.shared.error("[AirPlay] 无法绑定 UDP 端口")
            stop()
            return nil
        }
        dataFD = dfd
        timingFD = tfd
        Log.shared.info("[AirPlay] 镜像通道已就绪，视频端口 \(dport)，时间同步端口 \(tport)")

        queue.async { [weak self] in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async { self.receiveLoop(dfd) }
            DispatchQueue.global(qos: .utility).async { self.timingLoop(tfd) }
        }
        return (dport, tport)
    }

    func stop() {
        if dataFD >= 0 { close(dataFD); dataFD = -1 }
        if timingFD >= 0 { close(timingFD); timingFD = -1 }
        stream = nil
        configuredSize = nil
    }

    // MARK: 收包

    private func receiveLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 70_000)
        while fd >= 0 {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 {
                if errno == EINTR { continue }
                break
            }
            handle(Data(buffer[0..<count]))
        }
    }

    private func handle(_ packet: Data) {
        guard packet.count > 128 else { return }
        let base = packet.startIndex
        let payloadSize = Int(packet[base]) << 24 | Int(packet[base + 1]) << 16 | Int(packet[base + 2]) << 8 | Int(packet[base + 3])
        guard payloadSize > 0, 128 + payloadSize <= packet.count else { return }
        let type = packet[base + 4]
        packets += 1
        let payload = packet.subdata(in: (base + 128)..<(base + 128 + payloadSize))

        switch type {
        case 0: video(payload)
        case 1: format(payload)
        default: break
        }

        if Date().timeIntervalSince(lastLog) >= 10 {
            lastLog = Date()
            Log.shared.info("[AirPlay] 已收 \(packets) 个包 / \(frames) 帧\(configuredSize.map { "，\($0)" } ?? "")")
        }
    }

    private func video(_ payload: Data) {
        guard let stream, payload.count > 5 else { return }
        let clear = stream.decrypt(payload)
        guard clear.count > 5 else { return }
        let nalType = clear[clear.startIndex + 4] & 0x1F
        frames += 1
        onFrame?(clear, nalType == 5)
    }

    private func format(_ payload: Data) {
        guard payload.count > 11 else { return }
        let base = payload.startIndex
        let spsLength = Int(payload[base + 6]) << 8 | Int(payload[base + 7])
        guard spsLength > 0, payload.count > 8 + spsLength + 3 else { return }
        let sps = payload.subdata(in: (base + 8)..<(base + 8 + spsLength))
        let ppsField = payload[base + 9 + spsLength]
        let ppsLength = (Int(ppsField & 0xF8) + Int(payload[base + 10 + spsLength])) & 0xFF
        guard ppsLength > 0, payload.count >= 11 + spsLength + ppsLength else { return }
        let pps = payload.subdata(in: (base + 11 + spsLength)..<(base + 11 + spsLength + ppsLength))
        guard sps.count >= 4 else { return }

        var avcC = Data([0x01, sps[sps.startIndex + 1], sps[sps.startIndex + 2], sps[sps.startIndex + 3], 0xFF, 0xE1])
        avcC.append(UInt8((sps.count >> 8) & 0xFF))
        avcC.append(UInt8(sps.count & 0xFF))
        avcC.append(sps)
        avcC.append(0x01)
        avcC.append(UInt8((pps.count >> 8) & 0xFF))
        avcC.append(UInt8(pps.count & 0xFF))
        avcC.append(pps)

        let signature = "\(sps.count)/\(pps.count)"
        guard configuredSize != signature else { return }
        configuredSize = signature
        Log.shared.info("[AirPlay] 收到参数集，SPS \(sps.count) 字节 / PPS \(pps.count) 字节")
        onFormat?(avcC)
    }

    // MARK: 时间同步

    private func timingLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64)
        var from = sockaddr_in()
        var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        while fd >= 0 {
            let count = withUnsafeMutablePointer(to: &from) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(fd, &buffer, buffer.count, 0, address, &fromLength)
                }
            }
            if count <= 0 {
                if errno == EINTR { continue }
                break
            }
            guard count >= 32 else { continue }
            var reply = [UInt8](buffer[0..<count])
            reply[0] = 0x80
            reply[1] = 0xd3
            let sent = Array(reply[24..<32])
            reply[8] = sent[0]; reply[9] = sent[1]; reply[10] = sent[2]; reply[11] = sent[3]
            reply[12] = sent[4]; reply[13] = sent[5]; reply[14] = sent[6]; reply[15] = sent[7]
            let stamp = Self.ntpNow()
            for index in 0..<8 {
                reply[16 + index] = stamp[index]
                reply[24 + index] = stamp[index]
            }
            fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafePointer(to: &from) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(fd, reply, reply.count, 0, address, fromLength)
                }
            }
        }
    }

    private static func ntpNow() -> [UInt8] {
        let now = Date().timeIntervalSince1970 + 2_208_988_800
        let seconds = UInt32(now)
        let fraction = UInt32((now - Double(seconds)) * 4_294_967_296)
        var bytes = [UInt8](repeating: 0, count: 8)
        for index in 0..<4 {
            bytes[index] = UInt8((seconds >> (24 - index * 8)) & 0xFF)
            bytes[4 + index] = UInt8((fraction >> (24 - index * 8)) & 0xFF)
        }
        return bytes
    }

    // MARK: 端口

    private static func bindUDP() -> (Int32, UInt16)? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var size: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); return nil }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { close(fd); return nil }
        return (fd, UInt16(bigEndian: actual.sin_port))
    }
}
