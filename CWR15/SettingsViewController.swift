import UIKit

/// 设置：连接偏好、画面、诊断日志入口。
final class SettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let table = UITableView(frame: .zero, style: .insetGrouped)

    private struct Row {
        let title: String
        var detail: String?
        var accessory: UITableViewCell.AccessoryType
        var action: (() -> Void)?
        var switchValue: Bool?
        var onToggle: ((Bool) -> Void)?

        init(title: String,
             detail: String? = nil,
             accessory: UITableViewCell.AccessoryType = .none,
             action: (() -> Void)? = nil,
             switchValue: Bool? = nil,
             onToggle: ((Bool) -> Void)? = nil) {
            self.title = title
            self.detail = detail
            self.accessory = accessory
            self.action = action
            self.switchValue = switchValue
            self.onToggle = onToggle
        }
    }

    private var sections: [(String, [Row])] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done,
                                                            target: self, action: #selector(close))

        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        rebuild()
    }

    private func rebuild() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let size = Settings.reportSize

        sections = [
            ("连接", [
                Row(title: "自动连接上次地址", switchValue: Settings.autoConnect, onToggle: { value in
                    Settings.autoConnect = value
                    Log.shared.info("[设置] 自动连接：\(value ? "开" : "关")")
                }),
                Row(title: "主手机地址", detail: Settings.host.isEmpty ? "未设置" : "\(Settings.host):\(Settings.port)"),
                Row(title: "接收方式", detail: Settings.transport.title, accessory: .disclosureIndicator, action: { [weak self] in
                    self?.chooseTransport()
                }),
                Row(title: "让主端按此尺寸出图", detail: nil, switchValue: Settings.reportsDisplaySize, onToggle: { value in
                    Settings.reportsDisplaySize = value
                    Log.shared.info("[设置] 上报出图尺寸：\(value ? "开" : "关")，重新连接生效")
                }),
                Row(title: "出图尺寸", detail: "\(size.width) × \(size.height)", accessory: .disclosureIndicator, action: { [weak self] in
                    self?.chooseResolution()
                })
            ]),
            ("画面", [
                Row(title: "拉伸铺满（不保持比例）", switchValue: Settings.fillScreen, onToggle: { value in
                    Settings.fillScreen = value
                    Log.shared.info("[设置] 拉伸铺满：\(value ? "开" : "关")")
                }),
                Row(title: "显示触控圆点", switchValue: Settings.showTouchIndicator, onToggle: { value in
                    Settings.showTouchIndicator = value
                })
            ]),
            ("诊断", [
                Row(title: "运行日志", detail: "\(Log.shared.snapshot().count) 条", accessory: .disclosureIndicator, action: { [weak self] in
                    self?.openLog()
                }),
                Row(title: "复制诊断信息", accessory: .none, action: { [weak self] in
                    self?.copyDiagnostics()
                }),
                Row(title: "清空日志", accessory: .none, action: { [weak self] in
                    self?.confirmClear()
                })
            ]),
            ("关于", [
                Row(title: "版本", detail: "\(version) (\(build))"),
                Row(title: "开源许可", detail: "GPL-3.0", accessory: .disclosureIndicator, action: { [weak self] in
                    self?.showLicense()
                }),
                Row(title: "说明", detail: "iOS 15 第二屏接收端", accessory: .none, action: { [weak self] in
                    self?.showAbout()
                })
            ])
        ]
        table.reloadData()
    }

    // MARK: 动作

    @objc private func close() { dismiss(animated: true) }

    private func chooseTransport() {
        let sheet = UIAlertController(title: "接收方式", message: "WebSocket 能回传触控；HTTP 原始流绕开 WebSocket 升级，只能看画面。改动后重新连接生效。", preferredStyle: .actionSheet)
        for option in [Settings.Transport.webSocket, .raw] {
            let mark = option == Settings.transport ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: "\(mark)\(option.title)", style: .default) { [weak self] _ in
                Settings.transport = option
                Log.shared.info("[设置] 接收方式：\(option.title)（\(option.detail)）")
                self?.rebuild()
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = table
            popover.sourceRect = CGRect(x: table.bounds.midX, y: table.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func chooseResolution() {
        let sheet = UIAlertController(title: "出图尺寸", message: "只在打开「让主端按此尺寸出图」后生效。改动会让主手机按新尺寸重启 CarPlay 会话，接收端会短暂断流。", preferredStyle: .actionSheet)
        for (index, option) in Settings.resolutionOptions.enumerated() {
            let title = index == Settings.resolutionIndex ? "✓ \(option.0)" : option.0
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                Settings.resolutionIndex = index
                Log.shared.info("[设置] 出图尺寸改为 \(option.1)×\(option.2)")
                self?.rebuild()
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = table
            popover.sourceRect = CGRect(x: table.bounds.midX, y: table.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func openLog() {
        navigationController?.pushViewController(LogViewController(), animated: true)
    }

    private func copyDiagnostics() {
        let text = """
        DashCast 诊断
        版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        系统：iOS \(UIDevice.current.systemVersion)
        设备：\(UIDevice.current.model)
        本机地址：\(HostFinder.localIPv4() ?? "未知")
        目标：\(Settings.host):\(Settings.port)
        出图：\(Settings.reportSize.width)×\(Settings.reportSize.height)

        \(Log.shared.text())
        """
        UIPasteboard.general.string = text
        toast("已复制，可粘贴发给我")
    }

    private func confirmClear() {
        let alert = UIAlertController(title: "清空日志？", message: "清空后无法恢复", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            Log.shared.clear()
            self?.rebuild()
        })
        present(alert, animated: true)
    }

    private func showLicense() {
        let alert = UIAlertController(title: "GPL-3.0", message: "本项目以 GPL-3.0 开源。CarPlay 协议实现部分派生自 CarWithin（xmz28/CarWithin），同样遵循 GPL-3.0。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func showAbout() {
        let alert = UIAlertController(title: "DashCast", message: "把 iPhone 上的 CarPlay 画面接到旧设备当第二屏。仅供个人在自有设备上使用。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func toast(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { alert.dismiss(animated: true) }
    }

    // MARK: 表格

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].0 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].1.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].1[indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = row.detail
        cell.contentConfiguration = content
        cell.accessoryType = row.accessory
        cell.selectionStyle = row.action == nil && row.switchValue == nil ? .none : .default
        if let value = row.switchValue {
            let toggle = UISwitch()
            toggle.isOn = value
            let handler = row.onToggle
            toggle.addAction(UIAction { action in
                guard let sender = action.sender as? UISwitch else { return }
                handler?(sender.isOn)
            }, for: .valueChanged)
            cell.accessoryView = toggle
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].1[indexPath.row]
        row.action?()
        if row.action != nil { rebuild() }
    }
}
