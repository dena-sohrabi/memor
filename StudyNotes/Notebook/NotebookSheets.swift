import UIKit

/// How notebook pages are laid out, picked in Settings:
/// - Infinite canvas: one endless sheet of dotted paper on every page.
/// - Pages: sheets of paper of a fixed size, stacked top to bottom like a
///   real notebook. You scroll down through them, and ink stays on them.
///
/// Either way a page keeps one drawing, and everything on it keeps its
/// place, so switching back and forth loses nothing.
enum NotebookLayout: String, CaseIterable, Identifiable, Sendable {
    case infinite
    case pages

    nonisolated static let settingKey = "notebook.layout"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .infinite: "Infinite Canvas"
        case .pages: "Pages"
        }
    }

    /// The layout picked in Settings. Fine to read off the main thread.
    nonisolated static var current: NotebookLayout {
        UserDefaults.standard.string(forKey: settingKey).flatMap(NotebookLayout.init(rawValue:)) ?? .infinite
    }
}

/// The sheets of paper on a notebook page in Pages mode, in canvas points.
///
/// They're a column that starts at the middle of the canvas, where a new
/// page starts on the infinite canvas too, so ink, text and images stay
/// put when you switch. There are always enough sheets for what's on the
/// page, plus an empty one at the end to keep writing on.
struct NotebookSheets: Equatable {
    /// A portrait sheet with US Letter's shape (8.5 × 11), about as wide as
    /// an iPad's screen at 100%. Both sides are whole dot spacings, so the
    /// dots sit evenly on every sheet.
    static let sheetSize = CGSize(width: 960, height: 1248)
    /// The desk between two sheets: one dot spacing, so the dots carry on
    /// in step from sheet to sheet.
    static let gap: CGFloat = 24
    /// The desk showing around the column of sheets.
    static let margin: CGFloat = 24
    /// The first sheet's top-left corner: half a dot spacing off the dot
    /// grid, so the dots sit 12 points in from every edge.
    static let origin = CGPoint(x: 49_980, y: 49_980)
    /// The desk under the sheets: a quiet light gray. It stays light in dark
    /// mode, like the paper.
    static let deskColor = UIColor(red: 0.855, green: 0.85, blue: 0.835, alpha: 1)

    private static var pitch: CGFloat { sheetSize.height + gap }

    /// How many sheets there are, at least one.
    var count: Int

    /// Enough sheets for a page whose content reaches down to
    /// `contentBottom` (nil when it's empty), plus an empty one.
    init(contentBottom: CGFloat?) {
        count = Self.count(forContentBottom: contentBottom)
    }

    static func count(forContentBottom bottom: CGFloat?) -> Int {
        guard let bottom, bottom.isFinite else { return 1 }
        let last = ((bottom - origin.y) / pitch).rounded(.down)
        // An empty page has one sheet; otherwise one more than the last
        // sheet anything is on.
        return Int(min(max(last, -1), 2_000)) + 2
    }

    static func rect(at index: Int) -> CGRect {
        CGRect(x: origin.x, y: origin.y + CGFloat(index) * pitch, width: sheetSize.width, height: sheetSize.height)
    }

    /// All the sheets, top to bottom.
    var rects: [CGRect] { (0..<count).map(Self.rect(at:)) }

    /// The column of sheets, from the top of the first to the bottom of the last.
    var column: CGRect { Self.rect(at: 0).union(Self.rect(at: count - 1)) }

    /// The sheets that show in `area`.
    func rects(in area: CGRect) -> [CGRect] {
        guard !area.isNull, area.minY.isFinite, area.maxY.isFinite else { return [] }
        let first = max(index(atY: area.minY), 0)
        let last = min(index(atY: area.maxY), count - 1)
        guard first <= last else { return [] }
        return (first...last).map(Self.rect(at:)).filter { $0.intersects(area) }
    }

    /// The sheet nearest to `y` (top to bottom), among the sheets there are.
    func nearestIndex(toY y: CGFloat) -> Int {
        // Halfway across the gap between two sheets is where one ends and
        // the next begins.
        min(max(index(atY: y + Self.gap / 2), 0), count - 1)
    }

    /// The sheet `point` is on, or nil when it's on the desk.
    func sheet(containing point: CGPoint) -> CGRect? {
        let sheet = Self.rect(at: nearestIndex(toY: point.y))
        return sheet.contains(point) ? sheet : nil
    }

    /// Whether all of `rect` is on one sheet, at least `inset` in from its edges.
    func isOnOneSheet(_ rect: CGRect, inset: CGFloat = 0) -> Bool {
        Self.rect(at: nearestIndex(toY: rect.midY)).insetBy(dx: inset, dy: inset).contains(rect)
    }

    /// `rect` moved onto the sheet nearest its middle, as little as it
    /// takes, at least `inset` in from the edges. With `shrinking`, something
    /// bigger than the sheet gets smaller to fit, keeping its shape;
    /// otherwise it's lined up with the sheet's top-left corner.
    func fit(_ rect: CGRect, inset: CGFloat = 0, shrinking: Bool = false) -> CGRect {
        guard !rect.isNull, rect.minX.isFinite, rect.minY.isFinite else { return rect }
        let sheet = Self.rect(at: nearestIndex(toY: rect.midY)).insetBy(dx: inset, dy: inset)
        var size = rect.size
        if shrinking, size.width > 0, size.height > 0, size.width > sheet.width || size.height > sheet.height {
            let scale = min(sheet.width / size.width, sheet.height / size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        let x = max(sheet.minX, min(rect.minX, sheet.maxX - size.width))
        let y = max(sheet.minY, min(rect.minY, sheet.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// How far the page scrolls: the sheets, and anything left off them
    /// from the infinite canvas, with some desk around.
    func scrollArea(content: CGRect?) -> CGRect {
        var area = column
        if let content, !content.isNull { area = area.union(content) }
        return area.insetBy(dx: -Self.margin, dy: -Self.margin)
    }

    /// The zoom at which a sheet, with a little desk at its sides, fills
    /// `width`.
    static func fitWidthZoom(for width: CGFloat) -> CGFloat {
        width / (sheetSize.width + 2 * margin)
    }

    /// As far out as a page zooms: about two sheets top to bottom, and
    /// always at least a whole sheet's width.
    static func minimumZoom(for size: CGSize) -> CGFloat {
        let twoSheets = size.height / (2 * sheetSize.height + 3 * gap)
        return max(min(twoSheets, fitWidthZoom(for: size.width)), 0.05)
    }

    /// The sheet number `y` falls in, counting from the top of each sheet
    /// to the top of the next (unbounded).
    private func index(atY y: CGFloat) -> Int {
        let index = ((y - Self.origin.y) / Self.pitch).rounded(.down)
        return Int(min(max(index, -1), CGFloat(count)))
    }
}

/// The desk and the sheets of paper of a notebook page in Pages mode, with
/// soft shadows. It sits behind the dots and the transparent canvas and
/// doesn't scroll with it: `update` moves each sheet to where the canvas
/// shows it, and only the sheets on screen get a view.
final class NotebookSheetsView: UIView {
    private var sheetViews: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = NotebookSheets.deskColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lines the sheets up with a canvas scrolled to `contentOffset` at
    /// `zoom`. Returns where the sheets are, in this view's points.
    @discardableResult
    func update(sheets: NotebookSheets, contentOffset: CGPoint, zoom: CGFloat) -> [CGRect] {
        let zoom = max(zoom, 0.001)
        let visible = CGRect(
            x: contentOffset.x / zoom,
            y: contentOffset.y / zoom,
            width: bounds.width / zoom,
            height: bounds.height / zoom
        )
        // A bit past the screen's edges, so shadows don't pop in.
        let frames = sheets.rects(in: visible.insetBy(dx: -20 / zoom, dy: -20 / zoom)).map { rect in
            CGRect(
                x: rect.minX * zoom - contentOffset.x,
                y: rect.minY * zoom - contentOffset.y,
                width: rect.width * zoom,
                height: rect.height * zoom
            )
        }
        UIView.performWithoutAnimation {
            while sheetViews.count < frames.count {
                let sheet = Self.makeSheet()
                addSubview(sheet)
                sheetViews.append(sheet)
            }
            for (index, sheet) in sheetViews.enumerated() {
                guard index < frames.count else {
                    sheet.isHidden = true
                    continue
                }
                sheet.isHidden = false
                let frame = frames[index]
                guard sheet.frame != frame else { continue }
                let resized = sheet.frame.size != frame.size
                sheet.frame = frame
                if resized { sheet.layer.shadowPath = UIBezierPath(rect: sheet.bounds).cgPath }
            }
        }
        return frames
    }

    private static func makeSheet() -> UIView {
        let sheet = UIView()
        sheet.isUserInteractionEnabled = false
        sheet.backgroundColor = Paper.color
        sheet.layer.shadowColor = UIColor.black.cgColor
        sheet.layer.shadowOpacity = 0.16
        sheet.layer.shadowRadius = 5
        sheet.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        return sheet
    }
}
