import AVFoundation
import UIKit

/// 全屏播放页：视频层 + 可隐藏的工具条 + 触控回传。
final class PlayerViewController: UIViewController {

    private let videoView = VideoView()
    private var decoder: VideoDecoder?

    private let topBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let statusLabel = UILabel()
    private let backButton = UIButton(type: .system)
    private let overlay = UIView()
    private let overlayTitle = UILabel()
    private let overlayDetail = UILabel()
    private let retryButton = UIButton(type: .system)

    private var hideTask: DispatchWorkItem?
    private var framesThisSecond = 0
    private var fpsTimer: Timer?
    private var pendingFormat: VideoFormatInfo?
    private var barsHidden = false

    var onClose: (() -> Void)?
    var onRequestKeyframe: (() -> Void)?
    var onReconnect: (() -> Void)?

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideo()
        setupTopBar()
        setupOverlay()
        startFPSTimer()

        if let format = pendingFormat {
            apply(format)
            pendingFormat = nil
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        AppDelegate.orientationLock = .landscape
        rotate(to: .landscapeRight)
        scheduleHide()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        AppDelegate.orientationLock = .portrait
        fpsTimer?.invalidate(); fpsTimer = nil
        hideTask?.cancel()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    // MARK: UI

    private func setupVideo() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.fillScreen = Settings.fillScreen
        videoView.showTouchDot = Settings.showTouchIndicator
        view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        if let layer = videoView.displayLayer {
            let decoder = VideoDecoder(layer: layer)
            decoder.onSize = { [weak self] size in
                guard let self else { return }
                self.videoView.videoSize = size
                self.statusLabel.text = "\(Int(size.width))×\(Int(size.height)) · \(self.fps) fps"
                Log.shared.info("[画面] 视频尺寸 \(Int(size.width))×\(Int(size.height))")
            }
            decoder.onNeedKeyframe = { [weak self] in
                self?.onRequestKeyframe?()
            }
            self.decoder = decoder
        } else {
            Log.shared.error("[画面] 无法创建显示层")
        }

        videoView.onTouches = { [weak self] points in
            self?.sendTouches(points)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.numberOfTapsRequired = 1
        videoView.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        videoView.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)
    }

    private func setupTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.layer.cornerRadius = 16
        topBar.clipsToBounds = true
        view.addSubview(topBar)

        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = .white
        backButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.text = "正在连接…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let settingsButton = UIButton(type: .system)
        settingsButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        settingsButton.tintColor = .white
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        topBar.contentView.addSubview(backButton)
        topBar.contentView.addSubview(statusLabel)
        topBar.contentView.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            topBar.heightAnchor.constraint(equalToConstant: 44),

            backButton.leadingAnchor.constraint(equalTo: topBar.contentView.leadingAnchor, constant: 10),
            backButton.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 34),
            backButton.heightAnchor.constraint(equalToConstant: 34),

            statusLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -8),

            settingsButton.trailingAnchor.constraint(equalTo: topBar.contentView.trailingAnchor, constant: -10),
            settingsButton.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 34),
            settingsButton.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    private func setupOverlay() {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        overlay.layer.cornerRadius = 18
        overlay.isHidden = true
        view.addSubview(overlay)

        overlayTitle.textColor = .white
        overlayTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        overlayTitle.textAlignment = .center
        overlayTitle.numberOfLines = 0

        overlayDetail.textColor = UIColor.white.withAlphaComponent(0.7)
        overlayDetail.font = .systemFont(ofSize: 13)
        overlayDetail.textAlignment = .center
        overlayDetail.numberOfLines = 0

        retryButton.setTitle("重新连接", for: .normal)
        retryButton.setTitleColor(.black, for: .normal)
        retryButton.backgroundColor = .white
        retryButton.layer.cornerRadius = 20
        retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 24, bottom: 10, right: 24)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [overlayTitle, overlayDetail, retryButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)

        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
            stack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -22)
        ])
    }

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fps = self.framesThisSecond
            self.framesThisSecond = 0
            if case .streaming = self.currentState {
                if let size = self.decoderSizeText {
                    self.statusLabel.text = "\(size) · \(self.fps) fps"
                } else {
                    self.statusLabel.text = "已连接 · \(self.fps) fps"
                }
            }
        }
    }

    private var fps = 0
    private var currentState: StreamClient.State = .idle
    private var decoderSizeText: String?

    // MARK: 数据入口（由 Root 转发）

    func update(state: StreamClient.State, detail: String) {
        currentState = state
        switch state {
        case .idle:
            statusLabel.text = "未连接"
            showOverlay(title: "已断开", detail: detail, retry: true)
        case .connecting:
            statusLabel.text = "正在连接…"
            showOverlay(title: "正在连接", detail: detail, retry: false)
        case .handshaking:
            statusLabel.text = "握手…"
            showOverlay(title: "正在握手", detail: detail, retry: false)
        case .streaming:
            statusLabel.text = "已连接 · 等待画面"
        case .failed(let reason):
            statusLabel.text = "失败"
            showOverlay(title: "连接失败", detail: reason, retry: true)
        }
    }

    func show(format: VideoFormatInfo) {
        if isViewLoaded, decoder != nil {
            apply(format)
        } else {
            pendingFormat = format
        }
    }

    func show(video payload: Data, keyframe: Bool, timestampUs: UInt64) {
        guard let decoder else { return }
        decoder.enqueue(payload, keyframe: keyframe, timestampUs: timestampUs)
        framesThisSecond += 1
        hideOverlayIfStreaming()
    }

    private func apply(_ format: VideoFormatInfo) {
        decoderSizeText = "\(format.width)×\(format.height)"
        decoder?.configure(format)
    }

    private func showOverlay(title: String, detail: String, retry: Bool) {
        overlayTitle.text = title
        overlayDetail.text = detail
        retryButton.isHidden = !retry
        overlay.isHidden = false
        overlay.alpha = 1
    }

    private func hideOverlayIfStreaming() {
        guard !overlay.isHidden else { return }
        overlay.isHidden = true
    }

    // MARK: 交互

    @objc private func handleTap() {
        barsHidden.toggle()
        UIView.animate(withDuration: 0.2) {
            self.topBar.alpha = self.barsHidden ? 0 : 1
        }
        if !barsHidden { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.barsHidden = true
            UIView.animate(withDuration: 0.25) { self.topBar.alpha = 0 }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: task)
    }

    @objc private func handleDoubleTap() {
        Settings.fillScreen.toggle()
        videoView.fillScreen = Settings.fillScreen
        Log.shared.info("[画面] 显示模式：\(Settings.fillScreen ? "拉伸铺满" : "保持比例")")
    }

    @objc private func closeTapped() {
        onClose?()
        dismiss(animated: true)
    }

    @objc private func settingsTapped() {
        let controller = UINavigationController(rootViewController: SettingsViewController())
        present(controller, animated: true)
    }

    @objc private func retryTapped() {
        onReconnect?()
    }

    private func sendTouches(_ points: [(id: Int, x: Double, y: Double)]) {
        guard let client = streamClient else { return }
        client.sendTouch(points: points)
    }

    weak var streamClient: StreamClient?

    // MARK: 旋转

    private func rotate(to orientation: UIInterfaceOrientation) {
        if #available(iOS 16.0, *) {
            guard let scene = view.window?.windowScene else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        } else {
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}
