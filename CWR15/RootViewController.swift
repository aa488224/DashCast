import UIKit

/// 主页：填地址 / 扫描 / 连接，成功后进入全屏画面。
final class RootViewController: UIViewController, StreamClientDelegate {

    private let scrollView = UIScrollView()
    private let content = UIStackView()

    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let connectButton = UIButton(type: .system)

    private let hostField = UITextField()
    private let portField = UITextField()
    private let findButton = UIButton(type: .system)
    private let recentStack = UIStackView()
    private let foundStack = UIStackView()
    private let foundTitle = UILabel()

    private let client = StreamClient()
    private let finder = HostFinder()
    private var player: PlayerViewController?
    private var pendingFormat: VideoFormatInfo?
    private var lastState: StreamClient.State = .idle
    private var scanning = false
    private var autoConnectAttempted = false

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "DashCast"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true

        setupNavigation()
        setupLayout()
        setupActions()

        client.delegate = self
        finder.onUpdate = { [weak self] hosts in self?.showFound(hosts) }
        finder.onLog = { _ in }

        updateStatus(.idle, detail: "尚未连接")
        refreshRecent()
        Log.shared.info("[界面] 主页已加载，本机地址 \(HostFinder.localIPv4() ?? "未知")")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if Settings.autoConnect, !autoConnectAttempted, !Settings.host.isEmpty {
            autoConnectAttempted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.connect()
            }
        }
    }

    // MARK: UI

    private func setupNavigation() {
        let logItem = UIBarButtonItem(image: UIImage(systemName: "doc.text.magnifyingglass"),
                                      style: .plain, target: self, action: #selector(openLog))
        let settingsItem = UIBarButtonItem(image: UIImage(systemName: "gearshape.fill"),
                                           style: .plain, target: self, action: #selector(openSettings))
        navigationItem.rightBarButtonItems = [settingsItem, logItem]
    }

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        content.axis = .vertical
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            content.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -28),
            content.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -32)
        ])

        content.addArrangedSubview(makeHeroCard())
        content.addArrangedSubview(makeAddressCard())
        content.addArrangedSubview(makeGuideCard())
    }

    private func makeHeroCard() -> UIView {
        let card = makeCard()

        let icon = UIImageView(image: UIImage(systemName: "rectangle.on.rectangle.angled"))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let title = UILabel()
        title.text = "把 CarPlay 接到这块屏幕"
        title.font = .systemFont(ofSize: 21, weight: .bold)
        title.numberOfLines = 0

        let subtitle = UILabel()
        subtitle.text = "iOS 15 专用 · 主手机需运行 CarWithin 并开启局域网接收页"
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0

        let titles = UIStackView(arrangedSubviews: [title, subtitle])
        titles.axis = .vertical
        titles.spacing = 3

        let header = UIStackView(arrangedSubviews: [icon, titles])
        header.axis = .horizontal
        header.spacing = 12
        header.alignment = .center

        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statusLabel.textColor = .label
        statusLabel.numberOfLines = 0

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        let statusBox = UIStackView(arrangedSubviews: [statusLabel, detailLabel])
        statusBox.axis = .vertical
        statusBox.spacing = 4
        statusBox.isLayoutMarginsRelativeArrangement = true
        statusBox.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        statusBox.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
        statusBox.layer.cornerRadius = 12

        connectButton.setTitle("连接主手机", for: .normal)
        connectButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        connectButton.backgroundColor = .systemBlue
        connectButton.setTitleColor(.white, for: .normal)
        connectButton.layer.cornerRadius = 14
        connectButton.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let stack = UIStackView(arrangedSubviews: [header, statusBox, connectButton])
        stack.axis = .vertical
        stack.spacing = 14
        card.addArrangedSubview(stack)
        return card
    }

    private func makeAddressCard() -> UIView {
        let card = makeCard()

        let title = UILabel()
        title.text = "主手机地址"
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        hostField.placeholder = "例如 192.168.1.23"
        styleField(hostField)
        hostField.keyboardType = .numbersAndPunctuation
        hostField.text = Settings.host
        hostField.autocapitalizationType = .none
        hostField.autocorrectionType = .no
        hostField.returnKeyType = .done
        hostField.clearButtonMode = .whileEditing

        portField.placeholder = "9888"
        styleField(portField)
        portField.keyboardType = .numberPad
        portField.text = "\(Settings.port)"
        portField.textAlignment = .center
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.widthAnchor.constraint(equalToConstant: 78).isActive = true

        let row = UIStackView(arrangedSubviews: [hostField, portField])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .fill
        row.heightAnchor.constraint(equalToConstant: 46).isActive = true

        findButton.setTitle("查找局域网设备", for: .normal)
        findButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        findButton.setTitleColor(.systemBlue, for: .normal)
        findButton.contentHorizontalAlignment = .leading

        recentStack.axis = .vertical
        recentStack.spacing = 6

        foundTitle.text = "发现的主机"
        foundTitle.font = .systemFont(ofSize: 13, weight: .medium)
        foundTitle.textColor = .secondaryLabel
        foundTitle.isHidden = true
        foundStack.axis = .vertical
        foundStack.spacing = 6

        let hint = UILabel()
        hint.text = "端口默认 9888；主手机需先启动 CarPlay 并打开局域网接收页。"
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabel
        hint.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, row, findButton, foundTitle, foundStack, recentStack, hint])
        stack.axis = .vertical
        stack.spacing = 10
        card.addArrangedSubview(stack)
        return card
    }

    private func makeGuideCard() -> UIView {
        let card = makeCard()
        let title = UILabel()
        title.text = "使用步骤"
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let steps = UILabel()
        steps.numberOfLines = 0
        steps.font = .systemFont(ofSize: 14)
        steps.textColor = .secondaryLabel
        steps.text = """
        1. 主手机和这台设备连同一个 Wi-Fi
        2. 主手机打开 CarWithin，启动 CarPlay
        3. 主手机把输出设为「浏览器」，打开局域网接收页
        4. 这里填主手机地址，点「连接主手机」
        5. 出画面后点屏幕可显示工具条，双击切换拉伸/比例
        """

        let logButton = UIButton(type: .system)
        logButton.setTitle("查看运行日志", for: .normal)
        logButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        logButton.contentHorizontalAlignment = .leading
        logButton.addTarget(self, action: #selector(openLog), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, steps, logButton])
        stack.axis = .vertical
        stack.spacing = 10
        card.addArrangedSubview(stack)
        return card
    }

    private func makeCard() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.backgroundColor = .secondarySystemGroupedBackground
        stack.layer.cornerRadius = 18
        return stack
    }

    private func styleField(_ field: UITextField) {
        field.font = .systemFont(ofSize: 16)
        field.backgroundColor = .tertiarySystemFill
        field.layer.cornerRadius = 10
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.rightViewMode = .always
    }

    private func setupActions() {
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        findButton.addTarget(self, action: #selector(findTapped), for: .touchUpInside)
    }

    // MARK: 动作

    @objc private func connectTapped() {
        switch lastState {
        case .connecting, .handshaking, .streaming:
            disconnect()
        default:
            connect()
        }
    }

    private func connect() {
        view.endEditing(true)
        Settings.host = hostField.text ?? ""
        Settings.port = Int(portField.text ?? "") ?? 9888
        guard !Settings.host.isEmpty else {
            updateStatus(.failed("请填写主手机地址"), detail: "地址形如 192.168.1.23")
            return
        }
        Settings.rememberHost(Settings.host, port: Settings.port)
        refreshRecent()
        Log.shared.info("[界面] 开始连接 \(Settings.host):\(Settings.port)")
        client.start(host: Settings.host, port: Settings.port)
    }

    private func disconnect() {
        client.stop()
        player?.dismiss(animated: true)
        player = nil
    }

    @objc private func findTapped() {
        if scanning {
            finder.stop()
            scanning = false
            findButton.setTitle("查找局域网设备", for: .normal)
            return
        }
        scanning = true
        findButton.setTitle("正在扫描…（点此停止）", for: .normal)
        foundStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        foundTitle.isHidden = true
        finder.start(port: Int(portField.text ?? "") ?? 9888)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.scanning else { return }
            self.scanning = false
            self.findButton.setTitle("查找局域网设备", for: .normal)
        }
    }

    private func showFound(_ hosts: [HostFinder.Host]) {
        foundStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        foundTitle.isHidden = hosts.isEmpty
        for host in hosts {
            let button = UIButton(type: .system)
            button.setTitle("  \(host.display)", for: .normal)
            button.setImage(UIImage(systemName: "wifi.router"), for: .normal)
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.font = .systemFont(ofSize: 15)
            button.backgroundColor = .tertiarySystemFill
            button.layer.cornerRadius = 10
            button.heightAnchor.constraint(equalToConstant: 42).isActive = true
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.hostField.text = host.address
                self.portField.text = "\(host.port)"
                self.scanning = false
                self.findButton.setTitle("查找局域网设备", for: .normal)
                self.connect()
            }, for: .touchUpInside)
            foundStack.addArrangedSubview(button)
        }
        if hosts.isEmpty && !scanning {
            foundTitle.isHidden = true
        }
    }

    private func refreshRecent() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let history = Settings.hostHistory
        guard !history.isEmpty else { return }
        let label = UILabel()
        label.text = "最近使用"
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .tertiaryLabel
        recentStack.addArrangedSubview(label)
        for item in history.prefix(4) {
            let button = UIButton(type: .system)
            button.setTitle(item, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13)
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                let parts = item.split(separator: ":")
                if let host = parts.first {
                    self.hostField.text = String(host)
                }
                if parts.count > 1, let port = Int(parts[1]) {
                    self.portField.text = "\(port)"
                }
            }, for: .touchUpInside)
            recentStack.addArrangedSubview(button)
        }
    }

    @objc private func openSettings() {
        let controller = UINavigationController(rootViewController: SettingsViewController())
        present(controller, animated: true)
    }

    @objc private func openLog() {
        let controller = UINavigationController(rootViewController: LogViewController())
        present(controller, animated: true)
    }

    // MARK: 状态

    private func updateStatus(_ state: StreamClient.State, detail: String) {
        lastState = state
        switch state {
        case .idle:
            statusLabel.text = "未连接"
            statusLabel.textColor = .secondaryLabel
            detailLabel.text = detail.isEmpty ? "点下方按钮开始" : detail
            connectButton.setTitle("连接主手机", for: .normal)
            connectButton.backgroundColor = .systemBlue
        case .connecting:
            statusLabel.text = "正在连接…"
            statusLabel.textColor = .systemOrange
            detailLabel.text = detail
            connectButton.setTitle("取消", for: .normal)
            connectButton.backgroundColor = .systemGray
        case .handshaking:
            statusLabel.text = "正在握手…"
            statusLabel.textColor = .systemOrange
            detailLabel.text = detail
            connectButton.setTitle("断开", for: .normal)
            connectButton.backgroundColor = .systemGray
        case .streaming:
            statusLabel.text = "已连接"
            statusLabel.textColor = .systemGreen
            detailLabel.text = detail.isEmpty ? "正在接收画面" : detail
            connectButton.setTitle("断开连接", for: .normal)
            connectButton.backgroundColor = .systemRed
        case .failed(let reason):
            statusLabel.text = "连接失败"
            statusLabel.textColor = .systemRed
            detailLabel.text = reason
            connectButton.setTitle("重试", for: .normal)
            connectButton.backgroundColor = .systemBlue
        }
    }

    // MARK: StreamClientDelegate

    func streamClient(_ client: StreamClient, didChange state: StreamClient.State, detail: String) {
        updateStatus(state, detail: detail)
        player?.update(state: state, detail: detail)
        if case .streaming = state {} else if case .failed = state {
            // 保留播放页，让用户看到失败原因并可重试。
        }
    }

    func streamClient(_ client: StreamClient, didReceive format: VideoFormatInfo) {
        pendingFormat = format
        player?.show(format: format)
    }

    func streamClient(_ client: StreamClient, didReceiveVideo payload: Data, keyframe: Bool, timestampUs: UInt64) {
        if player == nil {
            presentPlayer()
        }
        player?.show(video: payload, keyframe: keyframe, timestampUs: timestampUs)
    }

    func streamClientDidRequestKeyframe(_ client: StreamClient) {
        client.requestKeyframe()
    }

    private func presentPlayer() {
        let controller = PlayerViewController()
        controller.modalPresentationStyle = .fullScreen
        controller.streamClient = client
        controller.onClose = { [weak self] in
            self?.client.stop()
            self?.player = nil
        }
        controller.onRequestKeyframe = { [weak self] in
            self?.client.requestKeyframe()
        }
        controller.onReconnect = { [weak self] in
            guard let self else { return }
            self.player?.dismiss(animated: true)
            self.player = nil
            self.connect()
        }
        player = controller
        present(controller, animated: false) { [weak self] in
            guard let self else { return }
            if let format = self.pendingFormat {
                self.player?.show(format: format)
            }
        }
    }
}
