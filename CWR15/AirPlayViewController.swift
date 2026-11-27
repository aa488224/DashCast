import AVFoundation
import UIKit

/// AirPlay 接收屏：本机被系统识别为一台接收器，iPhone 从控制中心直接镜像过来。
/// 不需要主手机安装任何 App，也不经过浏览器。
final class AirPlayViewController: UIViewController, AirPlayServerDelegate {

    private let videoView = VideoView()
    private var decoder: VideoDecoder?
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let topBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let backButton = UIButton(type: .system)
    private var framesThisSecond = 0
    private var fps = 0
    private var fpsTimer: Timer?
    private var didEnterLandscape = false
    private var sizeText: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideo()
        setupTopBar()
        setupHint()
        AirPlayServer.shared.delegate = self
        AirPlayServer.shared.start(name: Settings.airPlayName)
        Log.shared.info("[AirPlay] 接收页已打开")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        startFPSTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        fpsTimer?.invalidate(); fpsTimer = nil
        AirPlayServer.shared.stop()
        AirPlayServer.shared.delegate = nil
        AppDelegate.orientationLock = .portrait
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { didEnterLandscape ? .landscape : .allButUpsideDown }

    // MARK: UI

    private func setupVideo() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.fillScreen = Settings.fillScreen
        videoView.showTouchDot = false
        view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        guard let layer = videoView.displayLayer else {
            Log.shared.error("[AirPlay] 无法创建显示层")
            return
        }
        let decoder = VideoDecoder(layer: layer)
        decoder.onSize = { [weak self] size in
            guard let self else { return }
            self.videoView.videoSize = size
            self.sizeText = "\(Int(size.width))×\(Int(size.height))"
            self.enterFullscreenIfNeeded()
        }
        self.decoder = decoder
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

        statusLabel.text = "等待投屏…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let logButton = UIButton(type: .system)
        logButton.setImage(UIImage(systemName: "doc.text"), for: .normal)
        logButton.tintColor = .white
        logButton.addTarget(self, action: #selector(openLog), for: .touchUpInside)
        logButton.translatesAutoresizingMaskIntoConstraints = false

        topBar.contentView.addSubview(backButton)
        topBar.contentView.addSubview(statusLabel)
        topBar.contentView.addSubview(logButton)

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
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: logButton.leadingAnchor, constant: -8),

            logButton.trailingAnchor.constraint(equalTo: topBar.contentView.trailingAnchor, constant: -10),
            logButton.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor),
            logButton.widthAnchor.constraint(equalToConstant: 34),
            logButton.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    private func setupHint() {
        hintLabel.text = "在另一台 iPhone 上：控制中心 › 屏幕镜像 › 选择「\(Settings.airPlayName)」"
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        hintLabel.font = .systemFont(ofSize: 15)
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fps = self.framesThisSecond
            self.framesThisSecond = 0
            if self.fps > 0 || self.sizeText != nil {
                self.statusLabel.text = "\(self.sizeText ?? "接收中") · \(self.fps) fps"
            }
        }
    }

    private func enterFullscreenIfNeeded() {
        guard !didEnterLandscape else { return }
        didEnterLandscape = true
        hintLabel.isHidden = true
        AppDelegate.orientationLock = .landscape
        if #available(iOS 16.0, *) {
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        } else {
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: AirPlayServerDelegate

    func airPlayServer(_ server: AirPlayServer, didConfigure avcC: Data) {
        decoder?.configure(VideoFormatInfo(width: 0, height: 0, codec: "h264", avcC: avcC))
    }

    func airPlayServer(_ server: AirPlayServer, didReceive frame: Data, keyframe: Bool) {
        hintLabel.isHidden = true
        framesThisSecond += 1
        decoder?.enqueue(frame, keyframe: keyframe, timestampUs: UInt64(CACurrentMediaTime() * 1_000_000))
    }

    func airPlayServer(_ server: AirPlayServer, didUpdate status: String) {
        statusLabel.text = status
    }

    // MARK: 交互

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func openLog() {
        let controller = UINavigationController(rootViewController: LogViewController())
        present(controller, animated: true)
    }
}
