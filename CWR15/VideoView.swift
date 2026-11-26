import AVFoundation
import UIKit

/// 显示层 + 触控采集。视频按比例适应屏幕，触控坐标换算成 0...1 回传给主手机。
final class VideoView: UIView {

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }

    var videoSize: CGSize = .zero {
        didSet { setNeedsLayout() }
    }

    var fillScreen: Bool = false {
        didSet { updateGravity() }
    }

    var showTouchDot: Bool = true

    /// 当前所有手指（归一化坐标），空数组表示全部抬起。
    var onTouches: (([(id: Int, x: Double, y: Double)]) -> Void)?

    private var active: [ObjectIdentifier: CGPoint] = [:]
    private let dot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        displayLayer?.videoGravity = .resizeAspect
        displayLayer?.backgroundColor = UIColor.black.cgColor

        dot.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
        dot.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        dot.layer.cornerRadius = 13
        dot.layer.borderWidth = 1.5
        dot.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        dot.isUserInteractionEnabled = false
        dot.alpha = 0
        addSubview(dot)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 显示层就是 view 的 backing layer，铺满即可，比例交给 videoGravity。
        displayLayer?.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect
    }

    private func updateGravity() {
        setNeedsLayout()
    }

    // MARK: 视频显示区域

    static func aspectRect(content: CGSize, in bounds: CGRect, fill: Bool) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = fill
            ? max(bounds.width / content.width, bounds.height / content.height)
            : min(bounds.width / content.width, bounds.height / content.height)
        let width = content.width * scale
        let height = content.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    private func normalized(_ point: CGPoint) -> CGPoint? {
        let rect = Self.aspectRect(content: videoSize.width > 0 ? videoSize : bounds.size, in: bounds, fill: fillScreen)
        guard rect.width > 1, rect.height > 1, rect.contains(point) else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    // MARK: 触控

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { active[ObjectIdentifier(touch)] = touch.location(in: self) }
        publish()
        showDot(at: touches.first?.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { active[ObjectIdentifier(touch)] = touch.location(in: self) }
        publish()
        showDot(at: touches.first?.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { active.removeValue(forKey: ObjectIdentifier(touch)) }
        publish()
        hideDot()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { active.removeValue(forKey: ObjectIdentifier(touch)) }
        publish()
        hideDot()
    }

    private func publish() {
        var points: [(id: Int, x: Double, y: Double)] = []
        for (index, value) in active.values.enumerated() {
            guard let point = normalized(value) else { continue }
            points.append((index, Double(point.x), Double(point.y)))
        }
        onTouches?(points)
    }

    private func showDot(at point: CGPoint?) {
        guard showTouchDot, let point else { return }
        dot.center = point
        dot.alpha = 1
        UIView.animate(withDuration: 0.25, delay: 0.15, options: [.allowUserInteraction]) {
            self.dot.alpha = 0
        }
    }

    private func hideDot() {
        UIView.animate(withDuration: 0.15) { self.dot.alpha = 0 }
    }
}
