import PencilKit
import UIKit

/// Ink the study pal adds to a page: her handwriting and her marks. Undo
/// takes it off again, and Redo puts it back. (Strokes are found again by
/// their creation dates, which are hers alone.)
@MainActor
enum PalInkEditing {
    static func add(_ strokes: [PKStroke], to canvas: PKCanvasView, actionName: String) {
        guard !strokes.isEmpty else { return }
        var drawing = canvas.drawing
        drawing.strokes.append(contentsOf: strokes)
        canvas.drawing = drawing
        let dates = Set(strokes.map { $0.path.creationDate })
        let data = PKDrawing(strokes: strokes).dataRepresentation()
        canvas.undoManager?.registerUndo(withTarget: canvas) { canvas in
            MainActor.assumeIsolated { remove(dates, from: canvas, restoring: data, actionName: actionName) }
        }
        canvas.undoManager?.setActionName(actionName)
    }

    private static func remove(_ dates: Set<Date>, from canvas: PKCanvasView, restoring data: Data, actionName: String) {
        var drawing = canvas.drawing
        drawing.strokes.removeAll { dates.contains($0.path.creationDate) }
        canvas.drawing = drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { canvas in
            MainActor.assumeIsolated {
                guard let strokes = try? PKDrawing(data: data).strokes else { return }
                add(strokes, to: canvas, actionName: actionName)
            }
        }
    }

    /// Changes the student's own ink (erasing or moving some of it). Undo
    /// puts the page's ink back as it was, and Redo makes the change again.
    static func replace(_ canvas: PKCanvasView, with drawing: PKDrawing, actionName: String) {
        let before = canvas.drawing.dataRepresentation()
        canvas.drawing = drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { canvas in
            MainActor.assumeIsolated {
                guard let earlier = try? PKDrawing(data: before) else { return }
                replace(canvas, with: earlier, actionName: actionName)
            }
        }
        canvas.undoManager?.setActionName(actionName)
    }
}

/// One stroke of ink, recognized again later: when it was drawn and where.
struct PalStrokeKey: Hashable {
    let date: Date
    let x: Int, y: Int, width: Int, height: Int

    init(_ stroke: PKStroke) {
        let bounds = stroke.renderBounds
        date = stroke.path.creationDate
        x = Int(bounds.minX.rounded())
        y = Int(bounds.minY.rounded())
        width = Int(bounds.width.rounded())
        height = Int(bounds.height.rounded())
    }
}

/// A handwritten word (or a piece of a drawing): strokes close together on
/// one line, with an id the study pal can point at ("h12").
struct PalInkGroup {
    let id: String
    let rect: CGRect
    /// Which handwritten line it's on, from 1, top to bottom.
    let line: Int
    let strokes: Set<PalStrokeKey>
}

/// The student's handwriting on one page, for the study pal: words she can
/// see with their ids, erase and move. The ids she was last shown are kept,
/// so she can act on them; they're made afresh each time she looks.
@MainActor
final class PalHandwriting {
    private var groups: [String: PalInkGroup] = [:]

    /// The words near `area` (or all of them), in reading order. Words are
    /// numbered across the whole page, so an id means the same word
    /// whichever part of the page she looks at.
    func list(_ drawing: PKDrawing, within area: CGRect?, limit: Int = 250) -> [PalInkGroup] {
        let all = PalInkReading.groups(in: drawing, limit: .max)
        groups = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let near = area.map { area in all.filter { $0.rect.intersects(area) } } ?? all
        return Array(near.prefix(limit))
    }

    /// The strokes of these words, and the ids she named that aren't known.
    private func keys(for ids: [String]) -> (keys: Set<PalStrokeKey>, unknown: [String]) {
        var keys = Set<PalStrokeKey>()
        var unknown: [String] = []
        for id in ids {
            let id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let group = groups[id] { keys.formUnion(group.strokes) } else { unknown.append(id) }
        }
        return (keys, unknown)
    }

    /// Erases words by id, or every stroke that lies mostly inside `region`.
    func erase(ids: [String], region: CGRect?, on canvas: PKCanvasView) -> (result: String, isError: Bool) {
        let (keys, unknown) = keys(for: ids)
        var drawing = canvas.drawing
        let before = drawing.strokes.count
        drawing.strokes.removeAll { stroke in
            if keys.contains(PalStrokeKey(stroke)) { return true }
            guard let region else { return false }
            return Self.isMostlyInside(stroke.renderBounds, region)
        }
        let erased = before - drawing.strokes.count
        guard erased > 0 else {
            return (unknown.isEmpty ? "Nothing to erase there." : "Unknown ids \(unknown.joined(separator: ", ")): look again with look_at (label_handwriting true) for the current ids.", true)
        }
        PalInkEditing.replace(canvas, with: drawing, actionName: "Erase")
        var result = "Erased \(erased) stroke\(erased == 1 ? "" : "s"). They can undo this."
        if !unknown.isEmpty { result += " Unknown ids, not erased: \(unknown.joined(separator: ", "))." }
        return (result, false)
    }

    /// Moves words, together as a block, so the block's top-left corner
    /// ends up at `origin`.
    func move(ids: [String], to origin: CGPoint, on canvas: PKCanvasView) -> (result: String, isError: Bool) {
        let (keys, unknown) = keys(for: ids)
        guard !keys.isEmpty else {
            return ("Unknown ids \(unknown.joined(separator: ", ")): look again with look_at (label_handwriting true) for the current ids.", true)
        }
        var drawing = canvas.drawing
        let chosen = drawing.strokes.indices.filter { keys.contains(PalStrokeKey(drawing.strokes[$0])) }
        guard !chosen.isEmpty else { return ("Those words aren't on the page anymore. Look again for the current ids.", true) }
        let block = chosen.map { drawing.strokes[$0].renderBounds }.reduce(CGRect.null) { $0.union($1) }
        let shift = CGAffineTransform(translationX: origin.x - block.minX, y: origin.y - block.minY)
        for index in chosen {
            drawing.strokes[index].transform = drawing.strokes[index].transform.concatenating(shift)
        }
        PalInkEditing.replace(canvas, with: drawing, actionName: "Move Writing")
        // The moved words keep their ids, at their new place.
        for id in ids.map({ $0.lowercased() }) {
            guard let group = groups[id] else { continue }
            let moved = Set(drawing.strokes.filter { stroke in
                group.strokes.contains { $0.date == stroke.path.creationDate }
            }.map(PalStrokeKey.init))
            groups[id] = PalInkGroup(id: id, rect: group.rect.applying(shift), line: group.line, strokes: moved)
        }
        var result = "Moved it: its top-left corner is now at x \(Int(origin.x)), y \(Int(origin.y)). They can undo this."
        if !unknown.isEmpty { result += " Unknown ids, not moved: \(unknown.joined(separator: ", "))." }
        return (result, false)
    }

    private static func isMostlyInside(_ bounds: CGRect, _ region: CGRect) -> Bool {
        let inside = bounds.intersection(region)
        guard !inside.isNull, bounds.width * bounds.height > 0 else { return region.contains(bounds) }
        return inside.width * inside.height >= bounds.width * bounds.height * 0.7
    }
}

/// What the study pal works out from the ink on a page.
enum PalInkReading {
    /// How the student writes: so her handwriting comes out the same size
    /// and color, with a pen as thick.
    struct Style {
        var letterHeight: CGFloat
        var color: UIColor
        var penWidth: CGFloat
    }

    /// Handwritten lines, as boxes in page points, top to bottom: strokes
    /// side by side at about the same height make one line.
    static func lines(in drawing: PKDrawing, within area: CGRect? = nil, limit: Int = 80) -> [CGRect] {
        var boxes = drawing.strokes
            .filter { $0.ink.inkType != .marker }
            .map(\.renderBounds)
            .filter { !$0.isNull && !$0.isEmpty && $0.width < 2_000 && $0.height < 600 }
        if let area { boxes = boxes.filter { $0.intersects(area) } }
        boxes.sort { $0.midY < $1.midY }

        var lines: [CGRect] = []
        for box in boxes {
            // The line it fits on: overlapping it well in height, and near it across.
            if let index = lines.lastIndex(where: { line in
                let overlap = min(line.maxY, box.maxY) - max(line.minY, box.minY)
                let gap = max(box.minX - line.maxX, line.minX - box.maxX, 0)
                return overlap >= min(line.height, box.height) * 0.4 && gap < max(line.height, box.height) * 2.5
            }) {
                lines[index] = lines[index].union(box)
            } else {
                lines.append(box)
            }
        }
        return Array(lines.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }.prefix(limit))
    }

    /// Handwritten words, in reading order with ids h1, h2…: strokes on
    /// one line with only a small gap between them. A word in any script
    /// (English or Farsi) comes out as its own group, so a definition
    /// beside a word is separate from the word.
    static func groups(in drawing: PKDrawing, within area: CGRect? = nil, limit: Int = 200) -> [PalInkGroup] {
        var strokes = drawing.strokes
            .filter { $0.ink.inkType != .marker }
            .map { (bounds: $0.renderBounds, key: PalStrokeKey($0)) }
            .filter { !$0.bounds.isNull && !$0.bounds.isEmpty && $0.bounds.width < 2_000 && $0.bounds.height < 600 }
        if let area { strokes = strokes.filter { $0.bounds.intersects(area) } }
        strokes.sort { $0.bounds.midY < $1.bounds.midY }

        // Lines first, as above, keeping which strokes are on each.
        var lines: [(rect: CGRect, members: [Int])] = []
        for (index, stroke) in strokes.enumerated() {
            let box = stroke.bounds
            if let line = lines.lastIndex(where: { line in
                let overlap = min(line.rect.maxY, box.maxY) - max(line.rect.minY, box.minY)
                let gap = max(box.minX - line.rect.maxX, line.rect.minX - box.maxX, 0)
                return overlap >= min(line.rect.height, box.height) * 0.4 && gap < max(line.rect.height, box.height) * 2.5
            }) {
                lines[line].rect = lines[line].rect.union(box)
                lines[line].members.append(index)
            } else {
                lines.append((box, [index]))
            }
        }
        lines.sort { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }

        // Then words on each line: a gap wider than about a third of the
        // line's height starts a new one.
        var groups: [PalInkGroup] = []
        for (lineNumber, line) in lines.enumerated() {
            let members = line.members.sorted { strokes[$0].bounds.minX < strokes[$1].bounds.minX }
            let wordGap = max(line.rect.height * 0.35, 4)
            var word: (rect: CGRect, keys: Set<PalStrokeKey>)?
            func finish() {
                guard let done = word else { return }
                groups.append(PalInkGroup(id: "h\(groups.count + 1)", rect: done.rect, line: lineNumber + 1, strokes: done.keys))
                word = nil
            }
            for index in members {
                let box = strokes[index].bounds
                if let current = word, box.minX - current.rect.maxX <= wordGap {
                    word = (current.rect.union(box), current.keys.union([strokes[index].key]))
                } else {
                    finish()
                    word = (box, [strokes[index].key])
                }
            }
            finish()
            if groups.count >= limit { break }
        }
        return Array(groups.prefix(limit))
    }

    /// The size, color and pen of the student's handwriting, from their
    /// recent strokes. `fallbackHeight` when there's no handwriting yet.
    static func style(of drawing: PKDrawing, fallbackHeight: CGFloat) -> Style {
        let recent = drawing.strokes.suffix(200).filter { $0.ink.inkType != .marker }
        var colors: [String: (color: UIColor, count: Int)] = [:]
        var widths: [CGFloat] = []
        for stroke in recent {
            let key = colorKey(stroke.ink.color)
            colors[key] = (stroke.ink.color, (colors[key]?.count ?? 0) + 1)
            if let point = stroke.path.first { widths.append(point.size.width) }
        }
        var color = colors.values.max { $0.count < $1.count }?.color ?? .black
        // A pale pen would be hard to read.
        if lightness(of: color) > 0.8 { color = .black }
        let heights = lines(in: drawing).map(\.height).sorted()
        // A line's box runs from the tallest letter to the lowest tail;
        // a capital letter is about two thirds of it.
        let letterHeight = heights.isEmpty ? fallbackHeight : heights[heights.count / 2] * 0.62
        let penWidth = widths.isEmpty ? 2.4 : widths.sorted()[widths.count / 2]
        return Style(
            letterHeight: min(max(letterHeight, 10), 80),
            color: color,
            penWidth: min(max(penWidth, 1.2), 8)
        )
    }

    private static func colorKey(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%.2f %.2f %.2f", red, green, blue)
    }

    static func lightness(of color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

/// Pictures of a notebook page for the study pal: an area of it with its
/// ink, pictures and typed notes on plain paper.
@MainActor
enum PalRender {
    /// The longest side she gets, in pixels.
    static let maxPixels: CGFloat = 1_568

    /// Draws a numbered box around each handwritten word (`labels`, in page
    /// points), so she can point at words by their ids. The context is in
    /// pixels; `area` and `scale` say how page points map to them.
    static func drawLabels(_ labels: [PalInkGroup], area: CGRect, scale: CGFloat, in context: CGContext) {
        let color = UIColor(red: 0.93, green: 0.18, blue: 0.48, alpha: 1)
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        for group in labels where group.rect.intersects(area) {
            let box = CGRect(
                x: (group.rect.minX - area.minX) * scale,
                y: (group.rect.minY - area.minY) * scale,
                width: group.rect.width * scale,
                height: group.rect.height * scale
            ).insetBy(dx: -2, dy: -2)
            context.setStrokeColor(color.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1.5)
            context.stroke(box)
            let text = NSAttributedString(string: group.id, attributes: [.font: font, .foregroundColor: UIColor.white])
            let size = text.size()
            let tag = CGRect(x: box.minX, y: max(box.minY - size.height - 3, 0), width: size.width + 6, height: size.height + 2)
            context.setFillColor(color.cgColor)
            context.fill(tag)
            text.draw(at: CGPoint(x: tag.minX + 3, y: tag.minY + 1))
        }
    }

    static func notebook(
        area: CGRect,
        drawing: PKDrawing,
        textBoxes: [(frame: CGRect, text: NSAttributedString)],
        images: [(frame: CGRect, image: UIImage)],
        labels: [PalInkGroup] = []
    ) -> (image: Data, size: CGSize)? {
        guard area.width > 0, area.height > 0 else { return nil }
        let scale = min(maxPixels / max(area.width, area.height), 3)
        let size = CGSize(width: (area.width * scale).rounded(), height: (area.height * scale).rounded())
        var inkImage: UIImage?
        if drawing.strokes.contains(where: { $0.renderBounds.intersects(area) }) {
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                inkImage = drawing.image(from: area, scale: scale)
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -area.minX, y: -area.minY)
            for image in images where image.frame.intersects(area) { image.image.draw(in: image.frame) }
            inkImage?.draw(in: area)
            for box in textBoxes where box.frame.intersects(area) {
                box.text.draw(with: box.frame.insetBy(dx: 6, dy: 8), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            cg.restoreGState()
            drawLabels(labels, area: area, scale: scale, in: cg)
        }
        guard let data = picture.jpegData(compressionQuality: 0.8) else { return nil }
        return (data, size)
    }
}

/// A free spot on a page for something new: as close as it can to where
/// it's wanted, on screen, covering nothing that's there.
enum PalSpot {
    /// The top-left corner for something of `size`. `taken` is everything
    /// on the page; `preferred` where it would ideally go.
    static func find(for size: CGSize, preferred: CGPoint, visible: CGRect, taken: [CGRect], below fallbackY: CGFloat) -> CGPoint {
        let blocked = taken.filter { !$0.isNull && !$0.isEmpty }.map { $0.insetBy(dx: -16, dy: -16) }
        let onScreen = visible.insetBy(dx: 12, dy: 12)
        // Spots on a grid around the preferred one, up to a screen and a
        // half away, cheapest first. Spots on screen win over closer ones off it.
        let step = max(16, max(visible.width, visible.height) / 70)
        let reach = Int((max(visible.width, visible.height) * 1.5 / step).rounded(.up))
        var candidates: [(origin: CGPoint, cost: CGFloat)] = []
        candidates.reserveCapacity((2 * reach + 1) * (2 * reach + 1))
        for row in -reach...reach {
            for column in -reach...reach {
                let origin = CGPoint(x: preferred.x + CGFloat(column) * step, y: preferred.y + CGFloat(row) * step)
                // Right of or below the preferred spot reads more naturally than above or left.
                var cost = hypot(origin.x - preferred.x, origin.y - preferred.y)
                if origin.x < preferred.x - 1 { cost *= 1.4 }
                if origin.y < preferred.y - 1 { cost *= 1.2 }
                if !onScreen.contains(CGRect(origin: origin, size: size)) { cost += 1_500 }
                candidates.append((origin, cost))
            }
        }
        candidates.sort { $0.cost < $1.cost }
        return candidates.first { candidate in
            let frame = CGRect(origin: candidate.origin, size: size)
            return !blocked.contains { $0.intersects(frame) }
        }?.origin ?? CGPoint(x: preferred.x, y: fallbackY + 40)
    }
}
