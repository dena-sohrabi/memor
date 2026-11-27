import UIKit

/// The color of notebook paper: a soft, slightly yellow cream, like old paper.
enum Paper {
    static let color = UIColor(red: 0.980, green: 0.957, blue: 0.890, alpha: 1)
}

/// The dotted paper of notebook pages. Dots sit on a square grid in canvas
/// points, so they stay under your ink as you scroll and zoom.
enum DotGrid {
    /// Distance between dots, in canvas points.
    static let spacing: CGFloat = 24
    /// Dot radius at 100% zoom, in canvas points.
    static let radius: CGFloat = 1.1
    /// A warm gray that sits quietly on the cream paper.
    static let color = UIColor(red: 0.79, green: 0.75, blue: 0.66, alpha: 1)

    /// Distance between the dots that get drawn at `zoom`, in screen points.
    /// Zoomed far out, only every 2nd (or 4th…) dot is drawn, so the paper
    /// doesn't turn gray.
    static func cellSize(forZoom zoom: CGFloat, minimum: CGFloat) -> CGFloat {
        var cell = spacing * max(zoom, 0.01)
        while cell < minimum { cell *= 2 }
        return cell
    }

    /// Fills dots `cell` apart, one of them at `origin`, everywhere in `rect`.
    static func fill(in context: CGContext, rect: CGRect, origin: CGPoint, cell: CGFloat, radius: CGFloat) {
        guard cell > 0, radius > 0, !rect.isEmpty else { return }
        let firstColumn = ((rect.minX - radius - origin.x) / cell).rounded(.down)
        let firstRow = ((rect.minY - radius - origin.y) / cell).rounded(.down)
        let diameter = radius * 2
        var y = origin.y + firstRow * cell
        while y <= rect.maxY + radius {
            var x = origin.x + firstColumn * cell
            while x <= rect.maxX + radius {
                context.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: diameter, height: diameter))
                x += cell
            }
            y += cell
        }
        context.setFillColor(color.cgColor)
        context.fillPath()
    }
}

/// Draws the dots for the visible part of a notebook page. It sits behind
/// the transparent canvas and doesn't scroll with it: `update` shifts it by
/// less than one dot as the canvas scrolls, and it redraws only when the
/// zoom changes. That keeps scrolling cheap on a 100,000-point canvas.
final class DotGridView: UIView {
    private var cell: CGFloat = 0
    private var dotRadius: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lines the dots up with a canvas of `viewportSize` scrolled to
    /// `contentOffset` at `zoom`.
    func update(contentOffset: CGPoint, zoom: CGFloat, viewportSize: CGSize) {
        let newCell = DotGrid.cellSize(forZoom: zoom, minimum: 16)
        let newRadius = min(max(DotGrid.radius * zoom, 0.6), 2.5)
        if abs(newCell - cell) > 0.001 || abs(newRadius - dotRadius) > 0.001 {
            cell = newCell
            dotRadius = newRadius
            setNeedsDisplay()
        }
        // A dot at canvas point k × spacing is on screen at
        // k × spacing × zoom − contentOffset, so the grid's phase on screen
        // is −contentOffset, modulo one cell.
        func phase(_ offset: CGFloat) -> CGFloat {
            let remainder = offset.truncatingRemainder(dividingBy: cell)
            return remainder < 0 ? remainder + cell : remainder
        }
        frame = CGRect(
            x: -phase(contentOffset.x),
            y: -phase(contentOffset.y),
            width: viewportSize.width + cell,
            height: viewportSize.height + cell
        )
    }

    /// Shows the dots only inside `rects` (in the superview's points), as on
    /// the paper sheets in Pages mode. Call after `update`, since it moves
    /// this view. Nil shows dots everywhere.
    func clip(to rects: [CGRect]?) {
        guard let rects else {
            layer.mask = nil
            return
        }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let path = CGMutablePath()
        for rect in rects {
            path.addRect(rect.offsetBy(dx: -frame.minX, dy: -frame.minY))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.path = path
        CATransaction.commit()
        if layer.mask !== mask { layer.mask = mask }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        DotGrid.fill(in: context, rect: rect, origin: .zero, cell: cell, radius: dotRadius)
    }
}
