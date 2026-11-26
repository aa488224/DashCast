import UIKit

/// 运行日志：滚动查看、复制、分享文件、清空。
final class LogViewController: UIViewController {

    private let textView = UITextView()
    private let filter = UISegmentedControl(items: ["全部", "仅错误"])
    private let autoScrollSwitch = UISwitch()
    private var timer: Timer?
    private var lastCount = 0
    private var onlyErrors = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "运行日志"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain,
                            target: self, action: #selector(share)),
            UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain,
                            target: self, action: #selector(copyAll))
        ]

        setupUI()
        render(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.render(force: false)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate(); timer = nil
    }

    private func setupUI() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .label
        textView.backgroundColor = .secondarySystemBackground
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        filter.selectedSegmentIndex = 0
        filter.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onlyErrors = self.filter.selectedSegmentIndex == 1
            self.lastCount = 0
            self.render(force: true)
        }, for: .valueChanged)

        let autoLabel = UILabel()
        autoLabel.text = "自动滚动"
        autoLabel.font = .systemFont(ofSize: 13)
        autoLabel.textColor = .secondaryLabel

        autoScrollSwitch.isOn = true
        autoScrollSwitch.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)

        let bar = UIStackView(arrangedSubviews: [filter, UIView(), autoLabel, autoScrollSwitch])
        bar.axis = .horizontal
        bar.spacing = 10
        bar.alignment = .center
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = .systemBackground
        view.addSubview(bar)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    private func render(force: Bool) {
        let all = Log.shared.snapshot()
        let lines = onlyErrors ? all.filter { $0.contains("[ERR ") || $0.contains("[WARN]") } : all

        if force || lines.count < lastCount {
            textView.text = lines.joined(separator: "\n")
            lastCount = lines.count
        } else if lines.count > lastCount {
            let addition = lines[lastCount...].joined(separator: "\n") + "\n"
            textView.textStorage.append(NSAttributedString(string: addition, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: UIColor.label
            ]))
            lastCount = lines.count
        }

        guard autoScrollSwitch.isOn, textView.textStorage.length > 0 else { return }
        textView.scrollRangeToVisible(NSRange(location: textView.textStorage.length - 1, length: 0))
    }

    @objc private func copyAll() {
        UIPasteboard.general.string = Log.shared.text()
        flash("已复制全部日志")
    }

    @objc private func share() {
        guard let url = Log.shared.exportURL() else {
            flash("没有日志文件")
            return
        }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(controller, animated: true)
    }

    private func flash(_ message: String) {
        let label = UILabel()
        label.text = message
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        label.textAlignment = .center
        label.layer.cornerRadius = 16
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -72),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            label.heightAnchor.constraint(equalToConstant: 34)
        ])
        UIView.animate(withDuration: 0.2) { label.alpha = 1 } completion: { _ in
            UIView.animate(withDuration: 0.2, delay: 1.2) {
                label.alpha = 0
            } completion: { _ in
                label.removeFromSuperview()
            }
        }
    }
}
