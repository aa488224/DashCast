import Foundation

/// 局域网里找主手机：扫同网段 9888 端口，避开 Bonjour 依赖（主端不广播也能找到）。
final class HostFinder {

    struct Host: Equatable {
        let address: String
        let port: Int
        var display: String { "\(address):\(port)" }
    }

    var onUpdate: (([Host]) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "dashcast.finder", attributes: .concurrent)
    private var running = false
    private var results: [Host] = []
    private let lock = NSLock()

    func start(port: Int) {
        stop()
        guard let local = Self.localIPv4() else {
            report("找不到本机 Wi-Fi 地址，请确认已连接 Wi-Fi")
            onUpdate?([])
            return
        }
        let prefix = local.split(separator: ".").dropLast().joined(separator: ".")
        guard !prefix.isEmpty else {
            report("本机地址异常：\(local)")
            onUpdate?([])
            return
        }
        running = true
        lock.lock(); results = []; lock.unlock()
        report("开始扫描 \(prefix).1–254，端口 \(port)")
        let started = Date()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let group = DispatchGroup()
            let semaphore = DispatchSemaphore(value: 24)
            for index in 1...254 {
                let address = "\(prefix).\(index)"
                if address == local { continue }
                semaphore.wait()
                group.enter()
                self.queue.async {
                    defer { semaphore.signal(); group.leave() }
                    guard self.isRunning else { return }
                    if Self.probe(address, port: port, timeout: 0.45) {
                        self.add(Host(address: address, port: port))
                    }
                }
            }
            group.wait()
            let cost = String(format: "%.1f", Date().timeIntervalSince(started))
            self.report("扫描完成，用时 \(cost)s")
            self.finish()
        }
    }

    func stop() {
        running = false
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func add(_ host: Host) {
        lock.lock()
        guard running, !results.contains(where: { $0.address == host.address }) else {
            lock.unlock(); return
        }
        results.append(host)
        let list = results.sorted { $0.address < $1.address }
        lock.unlock()
        report("发现 \(host.display)")
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(list) }
    }

    private func finish() {
        lock.lock()
        let list = results.sorted { $0.address < $1.address }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(list) }
    }

    private func report(_ message: String) {
        Log.shared.info("[查找] \(message)")
        DispatchQueue.main.async { [weak self] in self?.onLog?(message) }
    }

    // MARK: 探测

    private static func probe(_ address: String, port: Int, timeout: TimeInterval) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var target = addr
        let result = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        guard ready > 0 else { return false }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }

    // MARK: 本机地址

    static func localIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            let family = current.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET), (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                let name = String(cString: current.pointee.ifa_name)
                if name == "en0" || name == "en1" {
                    var addr = current.pointee.ifa_addr.pointee
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let status = withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            getnameinfo($0, socklen_t($0.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                        }
                    }
                    if status == 0 {
                        let value = String(cString: buffer)
                        if !value.isEmpty, !value.hasPrefix("127.") { return value }
                    }
                }
            }
            pointer = current.pointee.ifa_next
        }
        return nil
    }
}
