import Foundation
import UIKit

/// 环形日志：内存保留最近若干条，同时落盘到 Documents，设置页里可以查看、复制、导出。
final class Log: NSObject {

    enum Level: String {
        case info  = "INFO"
        case warn  = "WARN"
        case error = "ERR "
    }

    static let shared = Log()

    private let queue = DispatchQueue(label: "cwr15.log")
    private var buffer: [String] = []
    private let capacity = 4000
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var fileBytes: UInt64 = 0
    private let fileLimit: UInt64 = 1_500_000

    private var pendingNotify = false

    /// 日志变化回调（主线程，已节流）。
    var onChange: (() -> Void)?

    private let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private override init() {
        super.init()
        openFile()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        append(.info, "===== CarWithin 第二屏启动 v\(version) (\(build)) · iOS \(UIDevice.current.systemVersion) =====")
    }

    // MARK: 写入

    func info(_ message: String)  { append(.info, message) }
    func warn(_ message: String)  { append(.warn, message) }
    func error(_ message: String) { append(.error, message) }

    private func append(_ level: Level, _ message: String) {
        let line = "\(timeFormat.string(from: Date())) [\(level.rawValue)] \(message)"
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(line)
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
            self.writeToFile(line)
            self.scheduleNotify()
        }
    }

    private func scheduleNotify() {
        guard !pendingNotify else { return }
        pendingNotify = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.pendingNotify = false
            self.onChange?()
        }
    }

    // MARK: 读取

    /// 同步取快照，供日志页展示。
    func snapshot() -> [String] {
        queue.sync { buffer }
    }

    func clear() {
        queue.sync {
            buffer.removeAll()
            fileHandle?.closeFile()
            fileHandle = nil
            if let url = fileURL {
                try? FileManager.default.removeItem(at: url)
            }
            openFile()
        }
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    /// 导出文件地址，供 UIActivityViewController 分享。
    func exportURL() -> URL? {
        queue.sync {
            fileHandle?.synchronizeFile()
            return fileURL
        }
    }

    func text() -> String {
        snapshot().joined(separator: "\n")
    }

    // MARK: 落盘

    private func openFile() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("cwr15-receiver.log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileURL = url
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            fileBytes = size.uint64Value
        } else {
            fileBytes = 0
        }
    }

    private func writeToFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if fileHandle == nil { openFile() }
        guard let handle = fileHandle else { return }
        handle.write(data)
        fileBytes += UInt64(data.count)
        if fileBytes > fileLimit {
            // 超限就换一份，旧的删掉，避免无限增长。
            handle.closeFile()
            fileHandle = nil
            if let url = fileURL { try? FileManager.default.removeItem(at: url) }
            openFile()
            writeToFile("---- 日志已滚动 ----")
        }
    }
}
