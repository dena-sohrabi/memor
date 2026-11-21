import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Reports Pencil touches on the canvas without ever taking them over, so
/// PencilKit keeps drawing as usual.
final class StrokeWatcher: UIGestureRecognizer {
    weak var coordinateView: UIView?
    var onBegan: ((CGPoint) -> Void)?
    var onMoved: ((CGPoint) -> Void)?
    /// `true` when the stroke finished, `false` when it was cancelled.
    var onEnded: ((Bool) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        onBegan?(touch.location(in: coordinateView))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else { return }
        onMoved?(touch.location(in: coordinateView))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        onEnded?(true)
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        onEnded?(false)
        state = .failed
    }
}

/// Procreate's QuickLine: draw a stroke, hold the Pencil still at the end,
/// and it becomes a straight line. While you hold, a dashed preview shows
/// the line and follows the Pencil; when you lift, the stroke is swapped for
/// a straight one with the same pen. Undo brings the hand-drawn stroke back.
@MainActor
final class QuickLine: NSObject {
    private static let holdDelay: Duration = .milliseconds(450)
    /// How far the Pencil may wobble (screen points) and still count as holding.
    private static let stillTolerance: CGFloat = 5
    /// Strokes shorter than this (screen points) are left alone.
    private static let minimumLength: CGFloat = 24

    private weak var canvasView: PKCanvasView?
    private weak var previewHost: UIView?
    private let watcher = StrokeWatcher()
    private let preview = CAShapeLayer()

    private var isTracking = false
    private var isHeld = false
    private var startPoint = CGPoint.zero
    private var anchorPoint = CGPoint.zero
    private var currentPoint = CGPoint.zero
    private var strokeCountAtStart = 0
    private var holdTask: Task<Void, Never>?
    /// Set when a held stroke ends: straighten it once it lands in the drawing.
    private var pendingStrokeCount: Int?

    init(canvasView: PKCanvasView, previewHost: UIView) {
        self.canvasView = canvasView
        self.previewHost = previewHost
        super.init()

        watcher.coordinateView = previewHost
        watcher.cancelsTouchesInView = false
        watcher.delaysTouchesBegan = false
        watcher.delaysTouchesEnded = false
        watcher.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        watcher.delegate = self
        watcher.onBegan = { [weak self] point in self?.began(at: point) }
        watcher.onMoved = { [weak self] point in self?.moved(to: point) }
        watcher.onEnded = { [weak self] finished in self?.ended(finished: finished) }
        canvasView.addGestureRecognizer(watcher)

        preview.strokeColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
        preview.fillColor = nil
        preview.lineWidth = 2
        preview.lineCap = .round
        preview.lineDashPattern = [6, 5]
        preview.zPosition = 10
        previewHost.layer.addSublayer(preview)
    }

    /// Call from `canvasViewDrawingDidChange(_:)`.
    func drawingDidChange() {
        straightenIfReady()
    }

    // MARK: Watching the stroke

    private func began(at point: CGPoint) {
        // Only for inking tools, not the eraser or lasso.
        isTracking = canvasView?.tool is PKInkingTool
        guard isTracking, let canvasView else { return }
        isHeld = false
        startPoint = point
        anchorPoint = point
        currentPoint = point
        strokeCountAtStart = canvasView.drawing.strokes.count
        scheduleHold()
    }

    private func moved(to point: CGPoint) {
        guard isTracking else { return }
        currentPoint = point
        if isHeld {
            showPreview()
        } else if distance(point, anchorPoint) > Self.stillTolerance {
            anchorPoint = point
            scheduleHold()
        }
    }

    private func ended(finished: Bool) {
        holdTask?.cancel()
        holdTask = nil
        preview.path = nil
        let straighten = isTracking && isHeld && finished
        isTracking = false
        isHeld = false
        guard straighten else { return }
        pendingStrokeCount = strokeCountAtStart
        // The stroke may already be in the drawing, or land a moment later.
        straightenIfReady()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.pendingStrokeCount = nil
        }
    }

    private func scheduleHold() {
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled else { return }
            self?.holdFired()
        }
    }

    private func holdFired() {
        guard isTracking, distance(startPoint, anchorPoint) >= Self.minimumLength else { return }
        isHeld = true
        showPreview()
    }

    private func showPreview() {
        let path = UIBezierPath()
        path.move(to: startPoint)
        path.addLine(to: currentPoint)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.path = path.cgPath
        CATransaction.commit()
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: Straightening

    private func straightenIfReady() {
        guard let expected = pendingStrokeCount, let canvasView,
              canvasView.drawing.strokes.count == expected + 1 else { return }
        pendingStrokeCount = nil
        straightenLastStroke(in: canvasView)
    }

    private func straightenLastStroke(in canvasView: PKCanvasView) {
        var drawing = canvasView.drawing
        guard let stroke = drawing.strokes.last else { return }
        let points = Array(stroke.path)
        guard points.count >= 2, let first = points.first, let last = points.last else { return }
        let start = first.location
        let end = last.location
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 1 else { return }

        // A steady line: evenly spaced points, all with the stroke's typical width.
        let typical = points.sorted { $0.size.width < $1.size.width }[points.count / 2]
        let count = max(2, Int(length / 6) + 1)
        let straightPoints = (0..<count).map { index in
            let t = CGFloat(index) / CGFloat(count - 1)
            return PKStrokePoint(
                location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                timeOffset: last.timeOffset * TimeInterval(t),
                size: typical.size,
                opacity: typical.opacity,
                force: typical.force,
                azimuth: typical.azimuth,
                altitude: typical.altitude
            )
        }
        let path = PKStrokePath(controlPoints: straightPoints, creationDate: stroke.path.creationDate)
        let straight = PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: nil)

        let before = drawing.dataRepresentation()
        drawing.strokes[drawing.strokes.count - 1] = straight
        canvasView.drawing = drawing
        canvasView.undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setDrawing(before) }
        }
    }

    private func setDrawing(_ data: Data) {
        guard let canvasView, let drawing = try? PKDrawing(data: data) else { return }
        let current = canvasView.drawing.dataRepresentation()
        canvasView.drawing = drawing
        canvasView.undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setDrawing(current) }
        }
    }
}

extension QuickLine: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Never get in the way of PencilKit's drawing.
        true
    }
}
