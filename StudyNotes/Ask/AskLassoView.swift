import UIKit

/// The "circle to ask" layer. While it's on, it covers the page and takes
/// every touch (Pencil or finger): draw a loop around something, lift, and
/// `onSelection` gets the loop's bounds in this view's coordinates. Nothing
/// is drawn on the page itself.
final class AskLassoView: UIView {
    var onSelection: ((CGRect) -> Void)?

    private let loop = CAShapeLayer()
    private let path = UIBezierPath()

    var isActive = false {
        didSet {
            isHidden = !isActive
            if !isActive { clearLoop() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        backgroundColor = .clear
        isMultipleTouchEnabled = false

        // Just an outline, no fill.
        loop.fillColor = nil
        loop.strokeColor = UIColor.systemIndigo.cgColor
        loop.lineWidth = 3
        loop.lineCap = .round
        loop.lineJoin = .round
        loop.shadowColor = UIColor.systemIndigo.cgColor
        loop.shadowOpacity = 0.5
        loop.shadowRadius = 6
        loop.shadowOffset = .zero
        layer.addSublayer(loop)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Drawing the loop

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        path.removeAllPoints()
        path.move(to: touch.location(in: self))
        updateLoop()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            path.addLine(to: sample.location(in: self))
        }
        updateLoop()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        path.close()
        updateLoop()
        let bounds = path.bounds
        guard bounds.width >= 24, bounds.height >= 24 else {
            clearLoop()
            return
        }
        onSelection?(bounds)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        clearLoop()
    }

    private func updateLoop() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loop.path = path.cgPath
        CATransaction.commit()
    }

    private func clearLoop() {
        path.removeAllPoints()
        loop.path = nil
    }

    // MARK: Snapshot

    /// What's on screen inside `rect` of `host` (which contains this view),
    /// without the loop or tint. At most 1568 pixels on the longest side,
    /// the size Claude reads images at.
    func snapshot(of host: UIView, rect: CGRect) -> UIImage? {
        let crop = rect.insetBy(dx: -12, dy: -12).intersection(host.bounds)
        guard !crop.isNull, crop.width > 1, crop.height > 1 else { return nil }
        let scale = min(traitCollection.displayScale, 1568 / max(crop.width, crop.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        let wasHidden = isHidden
        isHidden = true
        defer { isHidden = wasHidden }
        return UIGraphicsImageRenderer(size: crop.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: crop.size))
            host.drawHierarchy(
                in: CGRect(origin: CGPoint(x: -crop.minX, y: -crop.minY), size: host.bounds.size),
                afterScreenUpdates: true
            )
        }
    }
}
