import Foundation
import UIKit

/// 简单键值设置，全部走 UserDefaults，重启后保留。
enum Settings {

    private static let store = UserDefaults.standard

    // MARK: 连接

    static var host: String {
        get { store.string(forKey: "host") ?? "" }
        set { store.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "host") }
    }

    static var port: Int {
        get {
            let value = store.integer(forKey: "port")
            return (1...65535).contains(value) ? value : 9888
        }
        set { store.set(newValue, forKey: "port") }
    }

    static var autoConnect: Bool {
        get { store.object(forKey: "autoConnect") as? Bool ?? true }
        set { store.set(newValue, forKey: "autoConnect") }
    }

    static var autoFullscreen: Bool {
        get { store.object(forKey: "autoFullscreen") as? Bool ?? true }
        set { store.set(newValue, forKey: "autoFullscreen") }
    }

    // MARK: 画面

    /// 上报给主手机的出图尺寸，避免主端按 6s Plus 的小窗口出图。
    static let resolutionOptions: [(String, Int, Int)] = [
        ("1280 × 720（推荐）", 1280, 720),
        ("1920 × 720", 1920, 720),
        ("1280 × 800", 1280, 800),
        ("960 × 540（省流量）", 960, 540)
    ]

    static var resolutionIndex: Int {
        get {
            let value = store.integer(forKey: "resolutionIndex")
            return resolutionOptions.indices.contains(value) ? value : 0
        }
        set { store.set(newValue, forKey: "resolutionIndex") }
    }

    static var reportSize: (width: Int, height: Int) {
        let option = resolutionOptions[resolutionIndex]
        return (option.1, option.2)
    }

    /// 是否让主手机按上面的尺寸重新出图。
    /// 默认关：主端收到 display 会让 CarPlay 会话按新尺寸重启，
    /// 重启会重置编码器、丢弃已连接的接收端，表现为「握手成功但一直没有画面」。
    /// 只做第二屏时沿用主端当前出图尺寸、在本地缩放更稳。
    static var reportsDisplaySize: Bool {
        get { store.object(forKey: "reportsDisplaySize") as? Bool ?? false }
        set { store.set(newValue, forKey: "reportsDisplaySize") }
    }

    /// 拉伸铺满（默认关，保持比例，避免 CarPlay 变形）。
    static var fillScreen: Bool {
        get { store.object(forKey: "fillScreen") as? Bool ?? false }
        set { store.set(newValue, forKey: "fillScreen") }
    }

    static var showTouchIndicator: Bool {
        get { store.object(forKey: "showTouchIndicator") as? Bool ?? true }
        set { store.set(newValue, forKey: "showTouchIndicator") }
    }

    // MARK: 声音

    static var playAudio: Bool {
        get { store.object(forKey: "playAudio") as? Bool ?? false }
        set { store.set(newValue, forKey: "playAudio") }
    }

    static var audioVolume: Float {
        get {
            let value = store.float(forKey: "audioVolume")
            return value > 0 ? min(max(value, 0), 1) : 0.8
        }
        set { store.set(min(max(newValue, 0), 1), forKey: "audioVolume") }
    }

    // MARK: 历史

    private static let historyKey = "hostHistory"

    static var hostHistory: [String] {
        get { store.stringArray(forKey: historyKey) ?? [] }
        set { store.set(Array(newValue.prefix(8)), forKey: historyKey) }
    }

    static func rememberHost(_ value: String, port: Int) {
        let item = "\(value):\(port)"
        var list = hostHistory.filter { $0 != item }
        list.insert(item, at: 0)
        hostHistory = Array(list.prefix(8))
    }
}
