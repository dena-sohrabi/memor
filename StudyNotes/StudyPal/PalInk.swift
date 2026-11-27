import PencilKit
import UIKit
import os

/// The study pal's pen. She writes on your page in real handwriting (PencilKit
/// ink, so you can erase it, lasso it and move it like your own), marks
/// your work with circles, underlines, arrows and ticks, and sketches
/// diagrams and little pictures by hand.
///
/// Her letters are traced from a handwriting font (`PalGlyphTracer`) the
/// first time they're needed and kept behind a lock; everything else is
/// plain math with nothing shared. So it can be called from anywhere, and
/// the same `seed` always gives the same strokes.
nonisolated enum PalInk {
    /// How a piece of handwriting came out: its strokes, in page points, and the area they cover.
    struct Writing: Sendable {
        let strokes: [PKStroke]
        let bounds: CGRect
    }

    /// The marks she can make on your work.
    enum Mark: String, CaseIterable, Sendable {
        case circle, underline, doubleUnderline, box, strike, arrow, check, cross, bracket
    }

    // MARK: Handwriting

    /// Line spacing, in capital-letter heights.
    private static let lineSpacing: CGFloat = 1.55
    /// The space between two drawn letters, in capital-letter heights.
    /// (Letters traced from the font keep the font's own spacing.)
    private static let letterGap: CGFloat = 0.16
    /// The forward lean of the drawn letters: tan(6°). Letters traced from
    /// the font already lean the way the font does.
    private static let slant: CGFloat = 0.105

    /// Writes `text` by hand, with the top-left of its ink at `origin` (page points, y grows down): the first line's baseline sits as far below `origin` as its tallest letter reaches.
    /// `letterHeight` is the height of a capital letter (x-height ≈ 0.6 of it). Lines wrap at word boundaries within `maxWidth` (nil = no wrapping); "\n" starts a new line. Line spacing ≈ 1.55 × letterHeight.
    /// The letters are traced from a handwriting font when the iPad has one, with drawn letters for anything it lacks; `penWidth` is kept near the font's own line for the size. `seed` makes the natural wobble repeatable.
    static func handwriting(_ text: String, origin: CGPoint, letterHeight: CGFloat, maxWidth: CGFloat?, color: UIColor, penWidth: CGFloat, seed: UInt64 = 1) -> Writing {
        let empty = Writing(strokes: [], bounds: CGRect(origin: origin, size: .zero))
        guard letterHeight > 0, letterHeight.isFinite, !text.isEmpty else { return empty }
        let arranged = arrange(text, maxWidth: wrapWidth(maxWidth, letterHeight: letterHeight))
        let penWidth = fontPen(penWidth, letterHeight: letterHeight)
        // The pen's edge, not the middle of its line, starts at `origin`.
        let origin = CGPoint(x: origin.x + penWidth / 2, y: origin.y + penWidth / 2)
        var random = SplitMix64(seed: seed)
        var pen = Pen(color: color, width: penWidth, speed: letterHeight * 8)
        // Points along a stroke sit about half a pen width apart.
        let step = min(max(penWidth * 0.5 / letterHeight, 0.012), 0.05)

        for (row, line) in arranged.lines.enumerated() {
            let baseline = origin.y + (arranged.top + CGFloat(row) * lineSpacing) * letterHeight
            // The line drifts gently up and down, like writing without ruled lines.
            let drift = Wave(&random, amplitude: 0.02 * letterHeight, wavelength: 7 * letterHeight)
            for letter in line.letters {
                guard !letter.glyph.strokes.isEmpty else {
                    pen.pause(0.15)
                    continue
                }
                // Each letter comes out a little different (size, lean and
                // spacing), but they all stay on the line.
                let scale = 1 + random.signed() * 0.025
                let lean = letter.glyph.slant + random.signed() * 0.012
                let shiftX = line.offset + letter.x + random.signed() * 0.012
                let shiftY = random.signed() * 0.005
                let middle = letter.glyph.middle
                for path in letter.glyph.strokes {
                    // A slow, tiny wander so lines aren't machine-perfect.
                    let wanderX = Wave(&random, amplitude: 0.006, wavelength: 0.55)
                    let wanderY = Wave(&random, amplitude: 0.006, wavelength: 0.8)
                    let samples = resample(path, step: step)
                    var points: [CGPoint] = []
                    points.reserveCapacity(samples.count)
                    for sample in samples {
                        let y = (sample.point.y + wanderY.offset(at: sample.s)) * scale + shiftY
                        let x = middle + (sample.point.x + wanderX.offset(at: sample.s) - middle) * scale + y * lean
                        let pageX = origin.x + (shiftX + x) * letterHeight
                        points.append(CGPoint(x: pageX, y: baseline - y * letterHeight + drift.offset(at: pageX - origin.x)))
                    }
                    pen.draw(points)
                    pen.pause(0.05)
                }
                pen.pause(0.08)
            }
            pen.pause(0.35)
        }
        return Writing(strokes: pen.strokes, bounds: pen.bounds ?? empty.bounds)
    }

    /// The size handwriting would take, without making strokes (the same layout as above, so the two agree).
    /// It runs from the top of the ink (the first line's tallest letter) to the bottom of the lowest descender, and from the first letter's ink to the end of the longest line, with a pen as thick as the font's own line; the hand's small wobble can add a little.
    static func measure(_ text: String, letterHeight: CGFloat, maxWidth: CGFloat?) -> CGSize {
        guard letterHeight > 0, letterHeight.isFinite, !text.isEmpty else { return .zero }
        let size = arrange(text, maxWidth: wrapWidth(maxWidth, letterHeight: letterHeight)).size
        guard size.width > 0 else { return .zero }
        let pen = (handFont?.thickness ?? 0.1) * letterHeight
        return CGSize(width: size.width * letterHeight + pen, height: size.height * letterHeight + pen)
    }

    /// The wrapping width in capital-letter heights. (Line widths already
    /// include the lean.)
    private static func wrapWidth(_ maxWidth: CGFloat?, letterHeight: CGFloat) -> CGFloat {
        guard let maxWidth, maxWidth.isFinite else { return .infinity }
        return max(maxWidth / letterHeight, 0)
    }

    /// The pen for writing `letterHeight` tall: as thick as asked, but kept
    /// near the font's own line (from 80% of it to twice it), so the traced
    /// letters look the way the font draws them.
    private static func fontPen(_ asked: CGFloat, letterHeight: CGFloat) -> CGFloat {
        let asked = max(asked, 0.1)
        guard let handFont else { return asked }
        let line = handFont.thickness * letterHeight
        return min(max(asked, line * 0.8), line * 2)
    }

    // MARK: Layout

    /// Where some ink lies, in capital-letter heights: x from the start of
    /// its letter (or line), y up from the baseline.
    private struct Extent: Sendable {
        var minX: CGFloat
        var maxX: CGFloat
        var minY: CGFloat
        var maxY: CGFloat

        func union(_ other: Extent) -> Extent {
            Extent(minX: min(minX, other.minX), maxX: max(maxX, other.maxX), minY: min(minY, other.minY), maxY: max(maxY, other.maxY))
        }

        func shifted(by dx: CGFloat) -> Extent {
            Extent(minX: minX + dx, maxX: maxX + dx, minY: minY, maxY: maxY)
        }
    }

    /// A letter placed on a line, `x` capital-letter heights from the line's start.
    private struct Placed {
        let glyph: Glyph
        let x: CGFloat
    }

    private struct TextLine {
        var letters: [Placed] = []
        /// Where the next letter would start.
        var cursor: CGFloat = 0
        /// How far the line moves sideways so its first letter's ink starts
        /// right at the left edge.
        var offset: CGFloat = 0
        /// Where the line's ink lies (before `offset`), or nil while it has none.
        var ink: Extent?

        mutating func add(_ glyph: Glyph) {
            letters.append(Placed(glyph: glyph, x: cursor))
            if let box = glyph.ink?.shifted(by: cursor) {
                ink = ink?.union(box) ?? box
            }
            cursor += glyph.advance
        }
    }

    /// Text laid out for writing: its lines, where the first baseline sits,
    /// and the size of its ink, all in capital-letter heights.
    private struct Arrangement {
        var lines: [TextLine]
        /// From the top of the ink down to the first line's baseline.
        var top: CGFloat
        var size: CGSize
    }

    /// Lays the text out (see `layout`) and works out where its ink lies,
    /// so `handwriting` and `measure` agree.
    private static func arrange(_ text: String, maxWidth: CGFloat) -> Arrangement {
        var lines = layout(text, maxWidth: maxWidth)
        for index in lines.indices {
            if let first = lines[index].letters.first, let ink = first.glyph.ink {
                lines[index].offset = -ink.minX
            }
        }
        // The top is the first line's tallest letter (a capital's height when it's empty).
        let top = lines.first?.ink?.maxY ?? 1
        var width: CGFloat = 0
        var height = top
        for (row, line) in lines.enumerated() {
            let baseline = top + CGFloat(row) * lineSpacing
            height = max(height, baseline - min(line.ink?.minY ?? 0, 0))
            if let ink = line.ink { width = max(width, ink.maxX + line.offset) }
        }
        return Arrangement(lines: lines, top: top, size: CGSize(width: width, height: max(height, 0)))
    }

    /// How far some letters reach: from where the first starts to the end
    /// of the last one's ink.
    private static func reach(of glyphs: [Glyph]) -> CGFloat {
        guard let last = glyphs.last else { return 0 }
        let before = glyphs.dropLast().reduce(0) { $0 + $1.advance }
        return before + (last.ink?.maxX ?? last.advance)
    }

    /// Splits the text into lines, wrapping between words (and inside a word
    /// only when it's too long for a line by itself). Widths are in
    /// capital-letter heights.
    private static func layout(_ text: String, maxWidth: CGFloat) -> [TextLine] {
        var lines: [TextLine] = []
        let space = wordSpace
        for paragraph in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = TextLine()
            var word: [Glyph] = []
            var spaces: [Glyph] = []
            var startOfParagraph = true

            func placeWord() {
                guard !word.isEmpty else { return }
                // Spaces at the start of a paragraph indent it; at a wrap they're dropped.
                let keepSpaces = !line.letters.isEmpty || startOfParagraph
                let spaceWidth = keepSpaces ? spaces.reduce(0) { $0 + $1.advance } : 0
                if !line.letters.isEmpty && line.cursor + spaceWidth + reach(of: word) > maxWidth {
                    lines.append(line)
                    line = TextLine()
                } else if keepSpaces {
                    for glyph in spaces { line.add(glyph) }
                }
                for glyph in word {
                    if !line.letters.isEmpty && line.cursor + reach(of: [glyph]) > maxWidth {
                        lines.append(line)
                        line = TextLine()
                    }
                    line.add(glyph)
                }
                word.removeAll(keepingCapacity: true)
                spaces.removeAll(keepingCapacity: true)
                startOfParagraph = false
            }

            for character in paragraph {
                if character == "\t" {
                    placeWord()
                    spaces += Array(repeating: space, count: 4)
                } else if character.isWhitespace && character != "\u{00A0}" {
                    placeWord()
                    spaces.append(space)
                } else {
                    word += glyphs(for: character)
                }
            }
            placeWord()
            lines.append(line)
        }
        return lines
    }

    /// The letter shapes for one character: a small raised or lowered copy
    /// (², ₂), traced from the handwriting font, drawn (for what the font
    /// lacks, like arrows and Greek), a stand-in (æ → ae), an accented
    /// letter built from its plain one, or a small gap.
    private static func glyphs(for character: Character) -> [Glyph] {
        if character == " " { return [wordSpace] }
        if let small = smallForms[character], let plain = glyphs(for: small.plain).first, !plain.strokes.isEmpty {
            return [shrunk(plain, lift: small.lift)]
        }
        if let glyph = tracedGlyph(for: character) { return [glyph] }
        if let glyph = glyphTable[character] { return [glyph] }
        if let standIn = standIns[character] { return standIn.flatMap { glyphs(for: $0) } }
        if let glyph = accented(character) { return [glyph] }
        return [gap]
    }

    // MARK: The pen

    /// Turns lists of page points into PencilKit strokes, moving at a natural
    /// speed (slower at the ends, a touch lighter too) and keeping track of
    /// the area the ink covers.
    private struct Pen {
        let ink: PKInk
        let width: CGFloat
        /// Points per second.
        let speed: CGFloat
        let start = Date()
        private(set) var strokes: [PKStroke] = []
        private(set) var bounds: CGRect?
        private var clock: TimeInterval = 0

        init(color: UIColor, width: CGFloat, speed: CGFloat) {
            ink = PKInk(.pen, color: color)
            self.width = width
            self.speed = max(speed, 1)
        }

        mutating func pause(_ seconds: TimeInterval) {
            clock += seconds
        }

        mutating func draw(_ points: [CGPoint]) {
            guard var previous = points.first else { return }
            var lengths: [CGFloat] = [0]
            lengths.reserveCapacity(points.count)
            for point in points.dropFirst() {
                lengths.append(lengths[lengths.count - 1] + hypot(point.x - previous.x, point.y - previous.y))
                previous = point
            }
            let total = lengths[lengths.count - 1]
            // Dots (on i, j, !, :) stay round and full.
            let isDot = total < width * 1.5
            let ramp = min(total * 0.35, max(width * 2.5, 5))

            var controlPoints: [PKStrokePoint] = []
            controlPoints.reserveCapacity(points.count + 1)
            var time: TimeInterval = 0
            var minX = CGFloat.infinity, minY = CGFloat.infinity
            var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
            for index in points.indices {
                let s = lengths[index]
                let pressure = isDot ? 1 : PalInk.smoothstep(min(s, total - s) / ramp)
                if index > 0 {
                    let moved = TimeInterval((s - lengths[index - 1]) / (speed * (0.45 + 0.55 * pressure)))
                    time += max(moved, 0.001)
                }
                let size = width * (isDot ? 1.1 : 0.78 + 0.22 * pressure)
                let location = points[index]
                controlPoints.append(PKStrokePoint(
                    location: location,
                    timeOffset: time,
                    size: CGSize(width: size, height: size),
                    opacity: 1,
                    force: 0.5 + 0.45 * pressure,
                    azimuth: 0,
                    altitude: .pi / 2
                ))
                minX = min(minX, location.x - size / 2)
                minY = min(minY, location.y - size / 2)
                maxX = max(maxX, location.x + size / 2)
                maxY = max(maxY, location.y + size / 2)
            }
            // PencilKit needs at least two points to draw anything.
            if controlPoints.count == 1, let only = controlPoints.first {
                controlPoints.append(PKStrokePoint(
                    location: CGPoint(x: only.location.x + 0.01, y: only.location.y),
                    timeOffset: only.timeOffset + 0.01,
                    size: only.size,
                    opacity: 1,
                    force: only.force,
                    azimuth: 0,
                    altitude: .pi / 2
                ))
            }

            let path = PKStrokePath(controlPoints: controlPoints, creationDate: start.addingTimeInterval(clock))
            strokes.append(PKStroke(ink: ink, path: path, transform: .identity, mask: nil))
            clock += time
            let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            bounds = bounds?.union(box) ?? box
        }
    }

    /// A gentle, repeatable wave (two slow sines mixed), for wobble that
    /// looks like a hand rather than noise.
    private struct Wave {
        let amplitude: CGFloat
        let slow: CGFloat
        let fast: CGFloat
        let slowPhase: CGFloat
        let fastPhase: CGFloat

        init(_ random: inout SplitMix64, amplitude: CGFloat, wavelength: CGFloat) {
            let wavelength = max(wavelength, 0.0001)
            self.amplitude = amplitude
            slow = 2 * .pi / (wavelength * (0.85 + 0.3 * random.unit()))
            fast = 2 * .pi / (wavelength * (0.38 + 0.12 * random.unit()))
            slowPhase = random.unit() * 2 * .pi
            fastPhase = random.unit() * 2 * .pi
        }

        func offset(at x: CGFloat) -> CGFloat {
            amplitude * (0.7 * sin(slow * x + slowPhase) + 0.3 * sin(fast * x + fastPhase))
        }
    }

    /// A tiny seeded random number generator (SplitMix64), so the same seed
    /// always gives the same wobble.
    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// A number from 0 up to 1.
        mutating func unit() -> CGFloat {
            CGFloat(next() >> 11) * 0x1p-53
        }

        /// A number from -1 to 1.
        mutating func signed() -> CGFloat {
            unit() * 2 - 1
        }
    }

    // MARK: Geometry helpers

    /// A point along a path, and how far along the path it is.
    private struct Sample {
        let point: CGPoint
        let s: CGFloat
    }

    /// Adds points so none are more than `step` apart, keeping every corner.
    private static func resample(_ path: [CGPoint], step: CGFloat) -> [Sample] {
        guard let first = path.first else { return [] }
        var samples = [Sample(point: first, s: 0)]
        samples.reserveCapacity(path.count * 2)
        var travelled: CGFloat = 0
        for index in path.indices.dropFirst() {
            let a = path[index - 1], b = path[index]
            let length = distance(a, b)
            guard length > 0.000_001 else { continue }
            let count = max(1, Int((length / step).rounded(.up)))
            for k in 1...count {
                let t = CGFloat(k) / CGFloat(count)
                samples.append(Sample(point: mix(a, b, t), s: travelled + length * t))
            }
            travelled += length
        }
        if samples.count == 1 { samples.append(Sample(point: first, s: 0)) }
        return samples
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private static func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Points along a quadratic curve, after `a` and ending at `b`.
    private static func quadratic(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, spacing: CGFloat) -> [CGPoint] {
        let count = max(3, Int(((distance(a, c) + distance(c, b)) / spacing).rounded(.up)))
        return (1...count).map { index in
            let t = CGFloat(index) / CGFloat(count), u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                           y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        }
    }

    /// Points along a cubic curve, after `a` and ending at `b`.
    private static func cubic(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint, spacing: CGFloat) -> [CGPoint] {
        let count = max(4, Int(((distance(a, c1) + distance(c1, c2) + distance(c2, b)) / spacing).rounded(.up)))
        return (1...count).map { index in
            let t = CGFloat(index) / CGFloat(count), u = 1 - t
            let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
            return CGPoint(x: w0 * a.x + w1 * c1.x + w2 * c2.x + w3 * b.x,
                           y: w0 * a.y + w1 * c1.y + w2 * c2.y + w3 * b.y)
        }
    }

    /// Points along part of an ellipse, start included. Angles are in degrees,
    /// counterclockwise with y pointing up (as in the font).
    private static func ellipse(center: CGPoint, radii: CGSize, from start: CGFloat, sweep: CGFloat, spacing: CGFloat) -> [CGPoint] {
        let first = start * .pi / 180
        let turn = sweep * .pi / 180
        let length = abs(turn) * (radii.width + radii.height) / 2
        let count = max(8, Int((length / spacing).rounded(.up)))
        return (0...count).map { index in
            let angle = first + turn * CGFloat(index) / CGFloat(count)
            return CGPoint(x: center.x + radii.width * cos(angle), y: center.y + radii.height * sin(angle))
        }
    }

    // MARK: Marks

    /// A hand-drawn mark: `circle` is a loose ellipse around `rect` (slightly overshooting its start, like a real pen), `underline` sits just under it, `strike` through its middle, `box` a hand-drawn rectangle, `bracket` a curly brace on its left, `check`/`cross` small marks at its right side, `arrow` from `rect`'s center to `to` (or pointing at `rect` from its upper-left when `to` is nil) with a head.
    /// The arrow leaves from the edge of `rect`, so it doesn't cover what's inside.
    static func mark(_ kind: Mark, around rect: CGRect, to: CGPoint?, color: UIColor, penWidth: CGFloat, seed: UInt64 = 1) -> [PKStroke] {
        let rect = rect.standardized
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return [] }
        if let to, !(to.x.isFinite && to.y.isFinite) { return [] }
        let penWidth = max(penWidth, 0.1)
        var random = SplitMix64(seed: seed)
        let paths = shape(of: kind, around: rect, to: to, penWidth: penWidth, random: &random)
        let pen = byHand(paths, color: color, penWidth: penWidth, size: max(rect.width, rect.height, 10), random: &random)
        return pen.strokes
    }

    /// Inks paths in page points with a hand's slow wander, which fades out
    /// at each end so lines still meet where they should (an arrowhead its
    /// tip, a box its corner). `size` sets how far the hand wanders; nil
    /// goes by each path's own size.
    private static func byHand(_ paths: [[CGPoint]], color: UIColor, penWidth: CGFloat, size: CGFloat?, random: inout SplitMix64) -> Pen {
        var pen = Pen(color: color, width: penWidth, speed: 650)
        let step = max(penWidth * 0.5, 0.5)
        for path in paths {
            let reach = size ?? extent(of: path)
            let wanderX = Wave(&random, amplitude: min(max(reach * 0.005, 0.3), 1.2), wavelength: max(reach * 0.4, 30))
            let wanderY = Wave(&random, amplitude: min(max(reach * 0.005, 0.3), 1.2), wavelength: max(reach * 0.45, 34))
            let samples = resample(path, step: step)
            let total = samples.last?.s ?? 0
            let points = samples.map { sample -> CGPoint in
                let fade = min(1, min(sample.s, total - sample.s) / max(total * 0.12, 1))
                return CGPoint(x: sample.point.x + wanderX.offset(at: sample.s) * fade,
                               y: sample.point.y + wanderY.offset(at: sample.s) * fade)
            }
            pen.draw(points)
            pen.pause(0.15)
        }
        return pen
    }

    /// The longer side of the area a path covers, at least 10 points.
    private static func extent(of path: [CGPoint]) -> CGFloat {
        guard let first = path.first else { return 10 }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in path {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return max(maxX - minX, maxY - minY, 10)
    }

    // MARK: Drawing

    /// A sketch drawn by hand: its strokes in page points, the area they
    /// cover, and where the drawing's own coordinates landed on the page.
    struct Sketch: Sendable {
        let strokes: [PKStroke]
        let bounds: CGRect
        /// Where the drawing's (0, 0) is on the page.
        let origin: CGPoint
        /// How many page points one of the drawing's units is.
        let scale: CGFloat
        /// It ran out of its box, so it was shrunk to fit.
        let wasShrunk: Bool

        /// Where it went, and how to find a spot of the drawing on the page
        /// (to label it), for her.
        var summary: String {
            func number(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }
            var text = "Drew it at x \(Int(bounds.minX.rounded())), y \(Int(bounds.minY.rounded())), width \(Int(bounds.width.rounded())), height \(Int(bounds.height.rounded()))."
            if wasShrunk { text += " It ran outside the box, so it was shrunk to fit." }
            text += " A point (u, v) of the drawing is at x = \(number(origin.x)) + \(number(scale)) × u, y = \(number(origin.y)) + \(number(scale)) × v on the page."
            return text
        }
    }

    /// Sketches by hand inside `box` (page points): a diagram, a graph, a simple picture.
    /// Each of `strokes` is one pen line in the box's own coordinates, where the box's longer side runs 0–100 and the other in proportion (a 300 × 150 box runs x 0–100, y 0–50), with y growing down. A stroke is pen commands (`M x y` moves the pen, `L x y` draws a line, `H x` and `V y` straight across or down to there, `Q cx cy x y` and `C c1x c1y c2x c2y x y` curves, `A cx cy rx ry start sweep` part of an ellipse in degrees with 0 at the right and 90 at the bottom, `Z` back to the start), or plain numbers `x y x y …` for a smooth freehand line through those points.
    /// A drawing that runs well outside its box is shrunk to fit it, keeping its shape. The pen wobbles like a hand, as in `mark`.
    static func sketch(_ strokes: [String], in box: CGRect, color: UIColor, penWidth: CGFloat, seed: UInt64 = 1) -> Sketch {
        let box = box.standardized
        let nothing = Sketch(strokes: [], bounds: CGRect(origin: box.origin, size: .zero), origin: box.origin, scale: 1, wasShrunk: false)
        guard box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return nothing }
        let paths = strokes.flatMap { sketchPaths($0) }.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return nothing }

        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for point in paths.joined() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return nothing }
        var scale = max(box.width, box.height) / 100
        var origin = box.origin
        // Well outside the box: shrink it to fit (never grow it), in the middle.
        let slack = max(box.width, box.height) * 0.05
        let left = origin.x + minX * scale, right = origin.x + maxX * scale
        let upper = origin.y + minY * scale, lower = origin.y + maxY * scale
        let outside = left < box.minX - slack || right > box.maxX + slack || upper < box.minY - slack || lower > box.maxY + slack
        if outside {
            let fit = min(box.width / max(right - left, 0.001), box.height / max(lower - upper, 0.001), 1)
            scale *= fit
            origin = CGPoint(x: box.midX - (minX + maxX) / 2 * scale, y: box.midY - (minY + maxY) / 2 * scale)
        }
        let placed = paths.map { path in
            path.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }
        }
        var random = SplitMix64(seed: seed)
        let pen = byHand(placed, color: color, penWidth: max(penWidth, 0.1), size: nil, random: &random)
        return Sketch(strokes: pen.strokes, bounds: pen.bounds ?? nothing.bounds, origin: origin, scale: scale, wasShrunk: outside)
    }

    /// One sketch stroke's pen lines, in the drawing's own units.
    private static func sketchPaths(_ text: String) -> [[CGPoint]] {
        // Commands and numbers however they're spaced: "M10,20L30 40" → M 10 20 L 30 40.
        var spaced = ""
        var previous: Character = " "
        for character in text {
            if character.isLetter {
                spaced += " \(character.uppercased()) "
            } else if character == "," || character.isWhitespace {
                spaced += " "
            } else if character == "-" && (previous.isNumber || previous == ".") {
                spaced += " -"
            } else {
                spaced.append(character)
            }
            previous = character
        }
        let tokens = spaced.split(separator: " ")
        guard let first = tokens.first else { return [] }
        guard isNumber(first) else { return parsePath(tokens[...], spacing: 1, repeatsCommands: true) }
        // Plain numbers: a smooth line through the points.
        let values = tokens.compactMap { Double($0) }.filter(\.isFinite).map { CGFloat($0) }
        var points: [CGPoint] = []
        var index = 0
        while index + 1 < values.count {
            points.append(CGPoint(x: values[index], y: values[index + 1]))
            index += 2
        }
        return points.isEmpty ? [] : [smoothLine(through: points, spacing: 1)]
    }

    /// A token that starts a number, like "12", "-.5" or "+3".
    private static func isNumber(_ token: Substring) -> Bool {
        guard let first = token.first else { return false }
        return first.isNumber || first == "-" || first == "+" || first == "."
    }

    /// A smooth line through the points (Catmull–Rom), going all the way
    /// round when it ends where it began.
    private static func smoothLine(through points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        let closed = points.count > 3 && distance(first, last) < spacing * 0.5
        let knots = closed ? Array(points.dropLast()) : points
        let count = knots.count
        func knot(_ index: Int) -> CGPoint {
            closed ? knots[(index % count + count) % count] : knots[min(max(index, 0), count - 1)]
        }
        func blend(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ t: CGFloat) -> CGFloat {
            let linear = c - a
            let square = 2 * a - 5 * b + 4 * c - d
            let cube = 3 * (b - c) + d - a
            return 0.5 * (2 * b + linear * t + square * t * t + cube * t * t * t)
        }
        var line = [knots[0]]
        for index in 0..<(closed ? count : count - 1) {
            let a = knot(index - 1), b = knot(index), c = knot(index + 1), d = knot(index + 2)
            let steps = max(2, Int((distance(b, c) / spacing).rounded(.up)))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                line.append(CGPoint(x: blend(a.x, b.x, c.x, d.x, t), y: blend(a.y, b.y, c.y, d.y, t)))
            }
        }
        return line
    }

    /// The mark's strokes in page points, before the hand's wander.
    private static func shape(of kind: Mark, around rect: CGRect, to target: CGPoint?, penWidth: CGFloat, random: inout SplitMix64) -> [[CGPoint]] {
        let pad = min(max(penWidth * 2, min(rect.width, rect.height) * 0.15, 5), 16)
        let below = max(penWidth * 1.5, rect.height * 0.08 + 1.5)
        switch kind {
        case .circle:
            return [loop(around: rect, pad: pad, random: &random)]
        case .underline:
            return [underline(rect, below: below, inset: 0, pad: pad, random: &random)]
        case .doubleUnderline:
            let first = underline(rect, below: below, inset: 0, pad: pad, random: &random)
            let second = underline(rect, below: below + max(penWidth * 2.6, 4), inset: rect.width * 0.04, pad: pad, random: &random)
            return [first, second]
        case .strike:
            let y = rect.midY + random.signed() * rect.height * 0.05
            let tilt = random.signed() * min(rect.height * 0.08, 3)
            let bow = random.signed() * 1.5
            return [straight(CGPoint(x: rect.minX - pad * 0.25, y: y - tilt), CGPoint(x: rect.maxX + pad * 0.25, y: y + tilt), bow: bow)]
        case .box:
            return [box(around: rect, pad: pad, random: &random)]
        case .bracket:
            return [brace(beside: rect, pad: pad)]
        case .check:
            let size = min(max(rect.height * 0.9, 12), 44)
            let x = rect.maxX + pad * 0.8, y = rect.midY
            let corner = CGPoint(x: x + size * 0.32, y: y + size * 0.38)
            let end = CGPoint(x: x + size * (0.92 + random.signed() * 0.05), y: y - size * 0.6)
            var path = straight(CGPoint(x: x, y: y - size * 0.04), corner, bow: size * 0.02)
            path += quadratic(corner, CGPoint(x: x + size * 0.52, y: y - size * 0.04), end, spacing: 4)
            return [path]
        case .cross:
            let size = min(max(rect.height * 0.75, 10), 36)
            let x = rect.maxX + pad * 0.8, y = rect.midY
            let firstBow = random.signed() * size * 0.03
            let secondBow = random.signed() * size * 0.03
            return [
                straight(CGPoint(x: x, y: y - size / 2), CGPoint(x: x + size, y: y + size / 2), bow: firstBow),
                straight(CGPoint(x: x + size * 0.96, y: y - size * 0.52), CGPoint(x: x + size * 0.04, y: y + size * 0.5), bow: secondBow),
            ]
        case .arrow:
            return arrow(from: rect, to: target, pad: pad, penWidth: penWidth, random: &random)
        }
    }

    /// A straight-ish line from `a` to `b`, bowed sideways by `bow` points in the middle.
    private static func straight(_ a: CGPoint, _ b: CGPoint, bow: CGFloat = 0) -> [CGPoint] {
        let length = distance(a, b)
        guard length > 0.001, abs(bow) > 0.01 else { return [a, b] }
        let normalX = -(b.y - a.y) / length, normalY = (b.x - a.x) / length
        let count = max(4, Int(length / 5))
        return (0...count).map { index in
            let t = CGFloat(index) / CGFloat(count)
            let lift = bow * sin(.pi * t)
            let point = mix(a, b, t)
            return CGPoint(x: point.x + normalX * lift, y: point.y + normalY * lift)
        }
    }

    /// One loose loop around the rect that ends a little past where it began.
    private static func loop(around rect: CGRect, pad: CGFloat, random: inout SplitMix64) -> [CGPoint] {
        let radiusX = rect.width * 0.56 + pad, radiusY = rect.height * 0.6 + pad
        let tilt = random.signed() * 0.05
        let start = (100 + random.signed() * 25) * .pi / 180
        let sweep = 2 * .pi + 0.3 + random.unit() * 0.25
        let lumpPhase = random.unit() * 2 * .pi, ripplePhase = random.unit() * 2 * .pi
        let count = max(48, Int(2 * .pi * ((radiusX * radiusX + radiusY * radiusY) / 2).squareRoot() / 4))
        let cosTilt = cos(tilt), sinTilt = sin(tilt)
        return (0...count).map { index in
            let t = CGFloat(index) / CGFloat(count)
            let angle = start + sweep * t
            // Starts just inside and ends just outside, so the overshoot shows.
            let reach = (0.98 + 0.07 * t) * (1 + 0.025 * sin(2 * angle + lumpPhase) + 0.015 * sin(3 * angle + ripplePhase))
            let x = radiusX * reach * cos(angle), y = -radiusY * reach * sin(angle)
            return CGPoint(x: rect.midX + x * cosTilt - y * sinTilt, y: rect.midY + x * sinTilt + y * cosTilt)
        }
    }

    private static func underline(_ rect: CGRect, below: CGFloat, inset: CGFloat, pad: CGFloat, random: inout SplitMix64) -> [CGPoint] {
        let y = rect.maxY + below
        let start = CGPoint(x: rect.minX - pad * 0.3 + inset + random.signed() * 2, y: y + random.signed())
        let end = CGPoint(x: rect.maxX + pad * 0.3 - inset + random.signed() * 2, y: y + random.signed() * 1.5)
        return straight(start, end, bow: random.signed() * min(3, max(rect.width * 0.01, 0.5)))
    }

    /// A rectangle in one stroke, running on a little past its first corner.
    private static func box(around rect: CGRect, pad: CGFloat, random: inout SplitMix64) -> [CGPoint] {
        let frame = rect.insetBy(dx: -pad, dy: -pad)
        let jitter = min(pad * 0.3, 3)
        var corners: [CGPoint] = []
        for (x, y) in [(frame.minX, frame.minY), (frame.maxX, frame.minY), (frame.maxX, frame.maxY), (frame.minX, frame.maxY)] {
            corners.append(CGPoint(x: x + random.signed() * jitter, y: y + random.signed() * jitter))
        }
        let begin = mix(corners[0], corners[1], 0.05)
        let over = mix(corners[0], corners[1], 0.16 + random.unit() * 0.06)
        let bow = min(max(frame.width, frame.height) * 0.01, 2.5)
        var path = [begin]
        for (a, b) in [(begin, corners[1]), (corners[1], corners[2]), (corners[2], corners[3]), (corners[3], corners[0])] {
            path += straight(a, b, bow: random.signed() * bow).dropFirst()
        }
        path += straight(corners[0], CGPoint(x: over.x, y: over.y + 1.5)).dropFirst()
        return path
    }

    /// A curly brace just left of the rect, as tall as it.
    private static func brace(beside rect: CGRect, pad: CGFloat) -> [CGPoint] {
        let top = rect.minY - pad * 0.4, bottom = rect.maxY + pad * 0.4
        let height = bottom - top
        let width = min(max(height * 0.12, 6), 18)
        let right = rect.minX - pad * 0.6
        let spine = right - width * 0.5
        let tip = right - width
        let middle = (top + bottom) / 2
        let curl = min(width * 0.9, height * 0.2)
        var path = [CGPoint(x: right, y: top)]
        path += quadratic(path[0], CGPoint(x: spine, y: top), CGPoint(x: spine, y: top + curl), spacing: 3)
        path.append(CGPoint(x: spine, y: middle - curl))
        path += quadratic(CGPoint(x: spine, y: middle - curl), CGPoint(x: spine, y: middle), CGPoint(x: tip, y: middle), spacing: 3)
        path += quadratic(CGPoint(x: tip, y: middle), CGPoint(x: spine, y: middle), CGPoint(x: spine, y: middle + curl), spacing: 3)
        path.append(CGPoint(x: spine, y: bottom - curl))
        path += quadratic(CGPoint(x: spine, y: bottom - curl), CGPoint(x: spine, y: bottom), CGPoint(x: right, y: bottom), spacing: 3)
        return path
    }

    /// A shaft and two head strokes. With `target`, it runs from the rect
    /// (its edge, or its middle when the target is inside) to the target;
    /// without one, it comes in from the upper-left and points at the rect.
    private static func arrow(from rect: CGRect, to target: CGPoint?, pad: CGFloat, penWidth: CGFloat, random: inout SplitMix64) -> [[CGPoint]] {
        let frame = rect.insetBy(dx: -pad * 0.6, dy: -pad * 0.6)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let tip: CGPoint
        var tail: CGPoint
        if let target {
            tip = target
            tail = frame.contains(target) ? center : exitPoint(of: frame, from: center, toward: target)
        } else {
            let reach = min(max(rect.height * 1.8, 40), 110)
            tail = CGPoint(x: rect.minX - reach * 0.8, y: rect.minY - reach * 0.6)
            tip = exitPoint(of: frame, from: center, toward: tail)
        }
        if distance(tail, tip) < 8 {
            tail = CGPoint(x: tip.x - 24, y: tip.y - 18)
        }
        let length = distance(tail, tip)
        let shaft = straight(tail, tip, bow: random.signed() * length * 0.05)
        // Which way the shaft runs into the tip, pointing back along it.
        let back = shaft[max(0, shaft.count - 3)]
        let backLength = max(distance(back, tip), 0.001)
        let backX = (back.x - tip.x) / backLength, backY = (back.y - tip.y) / backLength
        let head = min(max(length * 0.2, 8 + penWidth * 2), 24)
        let spread = (26 + random.signed() * 4) * .pi / 180
        func barb(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: tip.x + head * (backX * cos(angle) - backY * sin(angle)),
                    y: tip.y + head * (backX * sin(angle) + backY * cos(angle)))
        }
        return [shaft, straight(barb(spread), tip), straight(barb(-spread), tip)]
    }

    /// Where a line from `center` toward `target` leaves `rect` (or `target`
    /// itself, if that comes first).
    private static func exitPoint(of rect: CGRect, from center: CGPoint, toward target: CGPoint) -> CGPoint {
        let dx = target.x - center.x, dy = target.y - center.y
        var t = CGFloat.infinity
        if dx > 0 { t = min(t, (rect.maxX - center.x) / dx) } else if dx < 0 { t = min(t, (rect.minX - center.x) / dx) }
        if dy > 0 { t = min(t, (rect.maxY - center.y) / dy) } else if dy < 0 { t = min(t, (rect.minY - center.y) / dy) }
        guard t.isFinite else { return center }
        t = min(max(t, 0), 1)
        return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }

    // MARK: The letters

    /// One character's shape, in capital-letter heights, with the baseline
    /// at y = 0 and y pointing up.
    private struct Glyph: Sendable {
        /// How far on the next letter starts (its width and the space after it).
        let advance: CGFloat
        /// How much it leans forward as it's written (tan of the angle).
        let slant: CGFloat
        /// Its pen strokes, in the order they're written.
        let strokes: [[CGPoint]]
        /// Where its ink lies, leaning as written. Nil for a space.
        let ink: Extent?
        /// The middle of its ink, side to side, before the lean.
        let middle: CGFloat

        init(advance: CGFloat, slant: CGFloat, strokes: [[CGPoint]]) {
            self.advance = advance
            self.slant = slant
            self.strokes = strokes
            var box: Extent?
            var left = CGFloat.infinity, right = -CGFloat.infinity
            for point in strokes.joined() {
                let x = point.x + point.y * slant
                let here = Extent(minX: x, maxX: x, minY: point.y, maxY: point.y)
                box = box?.union(here) ?? here
                left = min(left, point.x)
                right = max(right, point.x)
            }
            ink = box
            middle = left <= right ? (left + right) / 2 : advance / 2
        }
    }

    /// The handwriting font her letters are traced from: Bradley Hand, which
    /// looks like quick, tidy handwriting with a felt-tip pen, or else
    /// Noteworthy. Both come with iPadOS; with neither, she writes with the
    /// drawn letters below.
    private struct HandFont: Sendable {
        let font: PalGlyphTracer.Font
        /// How thick its line is, in capital-letter heights.
        let thickness: CGFloat
        /// The space between words, in capital-letter heights.
        let space: CGFloat
    }

    private static let handFont: HandFont? = {
        guard let font = PalGlyphTracer.font(named: ["BradleyHandITCTT-Bold", "Noteworthy-Light"]) else { return nil }
        // Its line, from a few plain letters.
        let samples: [Character] = ["n", "o", "l", "e", "H"]
        let widths = samples.compactMap { PalGlyphTracer.trace($0, in: font)?.thickness }.sorted()
        guard !widths.isEmpty else { return nil }
        return HandFont(
            font: font,
            thickness: min(max(widths[widths.count / 2], 0.04), 0.25),
            space: PalGlyphTracer.advance(of: " ", in: font) ?? 0.3
        )
    }()

    /// Letters already traced, shared by every writer (nil: the font doesn't
    /// have it, or it didn't trace well).
    private static let tracedLetters = OSAllocatedUnfairLock<[Character: Glyph?]>(initialState: [:])

    /// A character's shape traced from the handwriting font, the first time
    /// it's needed. Nil when there's no font or it doesn't have the character.
    private static func tracedGlyph(for character: Character) -> Glyph? {
        guard let handFont else { return nil }
        if let known = tracedLetters.withLock({ $0[character] }) { return known }
        let glyph = PalGlyphTracer.trace(character, in: handFont.font).map { letter in
            Glyph(advance: letter.advance, slant: 0, strokes: letter.strokes)
        }
        tracedLetters.withLock { $0[character] = .some(glyph) }
        return glyph
    }

    /// The space between words: the font's own, a touch wider (writing by
    /// hand spreads out), or the drawn letters' one.
    private static let wordSpace = Glyph(
        advance: handFont.map { max($0.space, 0.25) * 1.15 } ?? (0.2 + letterGap),
        slant: 0,
        strokes: []
    )
    /// The drawn letters' space.
    private static let space = Glyph(advance: 0.2 + letterGap, slant: slant, strokes: [])
    /// What a character no font knows becomes: a small gap.
    private static let gap = Glyph(advance: 0.3 + letterGap, slant: slant, strokes: [])
    /// How finely curves are cut into straight bits, in capital-letter heights.
    private static let flatness: CGFloat = 0.025

    /// Every drawn character's shape, read from `glyphSource` once.
    private static let glyphTable: [Character: Glyph] = makeGlyphTable()

    /// The drawn letters: neat, slightly rounded print, one pen line per
    /// stroke, for what the handwriting font lacks (arrows, Greek, math
    /// signs) or when there's no such font.
    ///
    /// Each line is a character, its width, then its strokes in the order a
    /// person writes them. Units are capital-letter heights: the baseline is
    /// at 0, capitals and ascenders reach 1, lowercase letters 0.62 and
    /// descenders -0.32. `M x y` puts the pen down, `L x y` draws a line,
    /// `Q cx cy x y` and `C c1x c1y c2x c2y x y` draw curves,
    /// `A cx cy rx ry start sweep` draws part of an ellipse (degrees,
    /// counterclockwise from the right) and `|` lifts the pen.
    private static let glyphSource = #"""
        ! 0.2 M .1 1 L .1 .3 M .09 .04 L .11 0
        " 0.32 M .08 1 L .08 .74 M .24 1 L .24 .74
        # 0.6 M .24 .9 L .16 .1 M .48 .9 L .4 .1 M .04 .64 L .58 .64 M .02 .36 L .56 .36
        $ 0.58 M .5 .76 C .45 .84 .37 .87 .29 .87 C .17 .87 .08 .8 .08 .69 C .08 .58 .18 .54 .29 .5 C .42 .46 .52 .41 .52 .29 C .52 .18 .42 .12 .29 .12 C .19 .12 .1 .16 .06 .23 M .3 1 L .3 -.02
        % 0.64 A .14 .82 .12 .16 90 365 M .56 1 L .08 0 | A .5 .18 .12 .16 90 365
        & 0.7 M .66 0 L .24 .58 C .14 .7 .12 .78 .12 .84 C .12 .94 .2 1 .3 1 C .4 1 .47 .94 .47 .85 C .47 .74 .38 .67 .26 .6 C .12 .52 .04 .42 .04 .27 C .04 .1 .16 0 .32 0 C .46 0 .56 .08 .66 .3
        ' 0.2 M .1 1 L .1 .74
        ( 0.28 M .26 1.04 C .1 .86 .04 .64 .04 .4 C .04 .16 .1 -.06 .26 -.22
        ) 0.28 M .02 1.04 C .18 .86 .24 .64 .24 .4 C .24 .16 .18 -.06 .02 -.22
        * 0.5 M .25 .96 L .25 .5 M .05 .86 L .45 .6 M .45 .86 L .05 .6
        + 0.6 M .04 .38 L .56 .38 M .3 .66 L .3 .1
        , 0.16 M .1 .05 Q .1 -.06 .03 -.16
        - 0.4 M .04 .38 L .36 .38
        . 0.14 M .06 .03 L .09 0
        / 0.48 M .44 1 L .04 -.1
        0 0.54 A .27 .5 .25 .5 95 365
        1 0.36 M .08 .8 L .28 1 L .28 0
        2 0.66 M .06 .78 C .1 .93 .22 1 .34 1 C .5 1 .6 .9 .6 .76 C .6 .6 .48 .48 .3 .3 L .04 0 L .62 0
        3 0.68 M .06 .88 C .14 .97 .24 1 .34 1 C .5 1 .6 .91 .6 .77 C .6 .62 .48 .54 .3 .54 C .52 .54 .64 .44 .64 .27 C .64 .1 .5 0 .32 0 C .2 0 .1 .04 .03 .13
        4 0.68 M .5 1 L .04 .32 L .66 .32 M .5 1 L .5 0
        5 0.68 M .14 1 L .1 .56 C .18 .62 .27 .64 .35 .64 C .52 .64 .64 .52 .64 .33 C .64 .13 .51 0 .33 0 C .2 0 .1 .05 .03 .14 M .14 1 L .58 1
        6 0.66 M .55 .93 C .49 .98 .42 1 .35 1 C .16 1 .05 .8 .05 .5 C .05 .2 .15 0 .34 0 C .51 0 .62 .12 .62 .3 C .62 .48 .5 .6 .34 .6 C .2 .6 .1 .52 .06 .4
        7 0.64 M .04 1 L .62 1 L .24 0
        8 0.68 M .56 .82 C .56 .93 .46 1 .33 1 C .2 1 .1 .93 .1 .8 C .1 .66 .22 .6 .34 .55 C .5 .49 .62 .4 .62 .25 C .62 .1 .5 0 .34 0 C .18 0 .06 .1 .06 .25 C .06 .4 .18 .49 .34 .55 C .46 .6 .56 .68 .56 .82
        9 0.62 A .32 .7 .26 .3 0 360 L .58 0
        : 0.14 M .06 .5 L .09 .47 M .06 .03 L .09 0
        ; 0.16 M .07 .5 L .1 .47 M .1 .05 Q .1 -.06 .03 -.16
        < 0.6 M .54 .7 L .06 .38 L .54 .06
        = 0.56 M .04 .5 L .52 .5 M .04 .26 L .52 .26
        > 0.6 M .06 .7 L .54 .38 L .06 .06
        ? 0.6 M .06 .78 C .1 .92 .2 1 .32 1 C .47 1 .56 .9 .56 .77 C .56 .62 .44 .55 .34 .48 C .3 .45 .3 .38 .3 .3 M .29 .04 L .31 0
        @ 0.88 A .44 .42 .14 .18 20 340 M .58 .6 L .58 .32 C .58 .22 .62 .2 .68 .2 C .78 .2 .84 .32 .84 .46 C .84 .74 .66 .9 .44 .9 C .2 .9 .04 .72 .04 .46 C .04 .2 .22 .02 .44 .02 C .54 .02 .62 .05 .7 .1
        A 0.68 M .02 0 L .34 1 L .66 0 M .14 .36 L .54 .36
        B 0.68 M .06 1 L .06 0 M .06 1 L .34 1 C .5 1 .58 .92 .58 .78 C .58 .62 .48 .55 .34 .55 L .06 .55 M .34 .55 C .54 .55 .64 .46 .64 .28 C .64 .1 .52 0 .34 0 L .06 0
        C 0.74 A .44 .5 .42 .5 50 260
        D 0.76 M .06 1 L .06 0 M .06 1 L .3 1 C .58 1 .72 .8 .72 .5 C .72 .2 .58 0 .3 0 L .06 0
        E 0.62 M .58 1 L .06 1 L .06 0 L .6 0 M .06 .52 L .48 .52
        F 0.6 M .58 1 L .06 1 L .06 0 M .06 .54 L .48 .54
        G 0.9 A .46 .5 .44 .5 48 272 L .8 .44 L .52 .44
        H 0.72 M .06 1 L .06 0 M .66 1 L .66 0 M .06 .52 L .66 .52
        I 0.4 M .02 1 L .38 1 M .2 1 L .2 0 M .02 0 L .38 0
        J 0.62 M .56 1 L .56 .3 C .56 .1 .46 0 .3 0 C .14 0 .04 .1 .02 .26
        K 0.68 M .06 1 L .06 0 M .62 1 L .06 .4 M .27 .62 L .66 0
        L 0.58 M .06 1 L .06 0 L .54 0
        M 0.84 M .04 0 L .1 1 L .42 .3 L .74 1 L .8 0
        N 0.72 M .06 0 L .06 1 L .66 0 L .66 1
        O 0.9 A .45 .5 .43 .5 95 368
        P 0.66 M .06 0 L .06 1 L .34 1 C .52 1 .62 .9 .62 .74 C .62 .58 .52 .48 .34 .48 L .06 .48
        Q 0.9 A .45 .5 .43 .5 95 368 M .56 .24 L .84 -.06
        R 0.7 M .06 0 L .06 1 L .34 1 C .52 1 .62 .9 .62 .75 C .62 .6 .52 .5 .34 .5 L .06 .5 M .3 .5 L .66 0
        S 0.7 M .62 .86 C .56 .96 .46 1 .34 1 C .18 1 .06 .92 .06 .76 C .06 .6 .2 .55 .34 .5 C .52 .44 .66 .38 .66 .22 C .66 .07 .52 0 .34 0 C .2 0 .09 .05 .03 .16
        T 0.68 M .02 1 L .66 1 M .34 1 L .34 0
        U 0.72 M .06 1 L .06 .32 C .06 .12 .18 0 .36 0 C .54 0 .66 .12 .66 .32 L .66 1
        V 0.68 M .02 1 L .34 0 L .66 1
        W 0.88 M .02 1 L .22 0 L .44 .72 L .66 0 L .86 1
        X 0.66 M .04 1 L .62 0 M .62 1 L .04 0
        Y 0.64 M .02 1 L .32 .5 M .62 1 L .32 .5 L .32 0
        Z 0.68 M .04 1 L .62 1 L .04 0 L .64 0
        [ 0.3 M .26 1.04 L .06 1.04 L .06 -.2 L .26 -.2
        \ 0.48 M .04 1 L .44 -.1
        ] 0.3 M .04 1.04 L .24 1.04 L .24 -.2 L .04 -.2
        ^ 0.52 M .06 .7 L .26 1 L .46 .7
        _ 0.56 M 0 -.12 L .56 -.12
        ` 0.22 M .06 1 L .16 .84
        a 0.54 A .26 .31 .25 .31 20 340 M .52 .62 L .52 0
        b 0.52 M .04 1 L .04 0 | A .28 .31 .24 .31 160 -340
        c 0.5 A .26 .31 .26 .31 45 270
        d 0.54 A .26 .31 .25 .31 20 340 M .52 1 L .52 0
        e 0.54 M .04 .33 L .52 .34 A .27 .31 .25 .31 5 310
        f 0.44 M .44 .93 C .4 .99 .34 1 .29 1 C .21 1 .16 .94 .16 .84 L .16 0 M .02 .62 L .36 .62
        g 0.54 A .26 .33 .25 .29 20 340 M .52 .62 L .52 -.14 C .52 -.28 .43 -.33 .3 -.33 C .18 -.33 .09 -.28 .05 -.2
        h 0.52 M .04 1 L .04 0 M .04 .4 C .1 .56 .2 .62 .29 .62 C .42 .62 .48 .54 .48 .4 L .48 0
        i 0.12 M .06 .62 L .06 0 M .05 .84 L .07 .87
        j 0.3 M .24 .62 L .24 -.16 C .24 -.28 .18 -.33 .11 -.33 C .06 -.33 .02 -.31 0 -.27 M .23 .84 L .25 .87
        k 0.48 M .04 1 L .04 0 M .42 .62 L .06 .26 M .17 .37 L .46 0
        l 0.18 M .06 1 L .06 .1 C .06 .03 .1 0 .16 .01
        m 0.74 M .04 .62 L .04 0 M .04 .42 C .08 .56 .15 .62 .23 .62 C .33 .62 .37 .54 .37 .42 L .37 0 M .37 .42 C .41 .56 .48 .62 .56 .62 C .66 .62 .7 .54 .7 .42 L .7 0
        n 0.5 M .04 .62 L .04 0 M .04 .42 C .08 .56 .16 .62 .26 .62 C .39 .62 .46 .54 .46 .4 L .46 0
        o 0.54 A .27 .31 .27 .31 80 365
        p 0.52 M .04 .62 L .04 -.32 | A .28 .31 .24 .31 160 -340
        q 0.58 A .26 .31 .25 .31 20 340 M .52 .62 L .52 -.3 Q .53 -.34 .6 -.28
        r 0.42 M .04 .62 L .04 0 M .04 .38 C .09 .54 .18 .62 .3 .62 C .35 .62 .39 .61 .42 .58
        s 0.48 M .43 .55 C .38 .61 .31 .62 .24 .62 C .13 .62 .05 .57 .05 .47 C .05 .37 .14 .34 .24 .31 C .36 .28 .45 .24 .45 .14 C .45 .04 .36 0 .24 0 C .15 0 .07 .03 .03 .09
        t 0.4 M .18 .9 L .18 .1 C .18 .03 .22 0 .28 0 C .32 0 .35 .01 .38 .03 M .02 .62 L .36 .62
        u 0.5 M .04 .62 L .04 .22 C .04 .08 .12 0 .24 0 C .36 0 .45 .08 .46 .22 M .46 .62 L .46 0
        v 0.48 M .02 .62 L .24 0 L .46 .62
        w 0.66 M .02 .62 L .17 0 L .33 .5 L .49 0 L .64 .62
        x 0.48 M .04 .62 L .44 0 M .44 .62 L .04 0
        y 0.5 M .03 .62 L .25 .02 M .47 .62 L .14 -.26 Q .11 -.32 .04 -.32
        z 0.5 M .04 .62 L .44 .62 L .04 0 L .46 0
        { 0.34 M .3 1.04 C .2 1.04 .16 1 .16 .9 L .16 .52 C .16 .45 .12 .42 .04 .41 C .12 .4 .16 .37 .16 .3 L .16 -.1 C .16 -.18 .2 -.2 .3 -.2
        | 0.2 M .1 1.04 L .1 -.2
        } 0.34 M .04 1.04 C .14 1.04 .18 1 .18 .9 L .18 .52 C .18 .45 .22 .42 .3 .41 C .22 .4 .18 .37 .18 .3 L .18 -.1 C .18 -.18 .14 -.2 .04 -.2
        ~ 0.54 M .04 .34 C .1 .44 .18 .46 .26 .4 C .34 .34 .42 .36 .5 .46
        \#u{00D7} 0.54 M .08 .62 L .46 .16 M .46 .62 L .08 .16
        \#u{00F7} 0.56 M .04 .38 L .52 .38 M .27 .62 L .29 .6 M .27 .16 L .29 .14
        \#u{00B1} 0.6 M .04 .5 L .56 .5 M .3 .76 L .3 .24 M .04 .06 L .56 .06
        \#u{2264} 0.58 M .52 .8 L .06 .56 L .52 .32 M .06 .14 L .52 .14
        \#u{2265} 0.58 M .06 .8 L .52 .56 L .06 .32 M .06 .14 L .52 .14
        \#u{2260} 0.56 M .04 .5 L .52 .5 M .04 .26 L .52 .26 M .42 .7 L .14 .06
        \#u{2248} 0.54 M .04 .46 C .1 .56 .18 .58 .26 .52 C .34 .46 .42 .48 .5 .58 M .04 .2 C .1 .3 .18 .32 .26 .26 C .34 .2 .42 .22 .5 .32
        \#u{2192} 0.86 M .04 .38 L .8 .38 M .62 .54 L .82 .38 L .62 .22
        \#u{2190} 0.86 M .82 .38 L .06 .38 M .24 .54 L .04 .38 L .24 .22
        \#u{2191} 0.52 M .26 0 L .26 .96 M .08 .78 L .26 .98 L .44 .78
        \#u{2193} 0.52 M .26 1 L .26 .04 M .08 .22 L .26 .02 L .44 .22
        \#u{00B0} 0.28 A .14 .86 .1 .12 90 365
        \#u{221A} 0.88 M .02 .46 L .12 .52 L .28 0 L .52 1.06 L .86 1.06
        \#u{03C0} 0.62 M .02 .62 L .6 .62 M .18 .62 L .14 0 M .44 .62 L .44 .08 Q .45 0 .54 .02
        \#u{221E} 0.88 M .44 .34 C .36 .46 .28 .52 .2 .52 C .1 .52 .04 .44 .04 .34 C .04 .24 .1 .16 .2 .16 C .28 .16 .36 .22 .44 .34 C .52 .46 .6 .52 .68 .52 C .78 .52 .84 .44 .84 .34 C .84 .24 .78 .16 .68 .16 C .6 .16 .52 .22 .44 .34
        \#u{2211} 0.66 M .6 1 L .04 1 L .38 .5 L .04 0 L .62 0
        \#u{0394} 0.7 M .34 1 L .02 0 L .68 0 L .34 1
        \#u{03B1} 0.64 M .56 .62 C .5 .3 .42 0 .24 0 C .1 0 .04 .14 .04 .3 C .04 .48 .14 .62 .26 .62 C .4 .62 .46 .4 .5 .22 C .53 .1 .56 0 .62 0
        \#u{03B2} 0.62 M .08 -.32 L .08 .72 C .08 .9 .18 1 .3 1 C .44 1 .52 .92 .52 .8 C .52 .66 .42 .58 .26 .58 C .46 .58 .58 .46 .58 .3 C .58 .12 .46 0 .3 0 C .2 0 .12 .04 .08 .1
        \#u{03B3} 0.54 M .02 .56 C .08 .64 .14 .6 .18 .5 L .3 .1 L .3 -.32 M .52 .62 L .3 .1
        \#u{03B4} 0.54 M .4 .94 C .34 .99 .26 1 .2 1 C .1 1 .06 .94 .06 .88 C .06 .78 .18 .72 .3 .64 C .44 .55 .5 .44 .5 .3 C .5 .12 .4 0 .27 0 C .14 0 .04 .12 .04 .28 C .04 .46 .16 .58 .3 .64
        \#u{03B5} 0.46 M .42 .56 C .36 .61 .3 .62 .24 .62 C .12 .62 .06 .56 .06 .48 C .06 .38 .14 .34 .26 .34 C .12 .34 .04 .28 .04 .17 C .04 .06 .12 0 .25 0 C .33 0 .39 .02 .44 .07
        \#u{03B7} 0.5 M .04 .62 L .04 0 M .04 .42 C .08 .56 .16 .62 .26 .62 C .39 .62 .46 .54 .46 .4 L .46 -.32
        \#u{03B8} 0.56 A .28 .5 .24 .5 95 365 M .06 .5 L .5 .5
        \#u{03BB} 0.58 M .06 1 Q .16 1 .22 .86 L .54 0 M .32 .56 L .04 0
        \#u{03BC} 0.58 M .06 .62 L .06 -.32 M .06 .22 C .06 .08 .14 0 .26 0 C .38 0 .46 .08 .46 .22 M .46 .62 L .46 .06 Q .47 0 .54 .02
        \#u{03C1} 0.52 M .06 -.32 L .06 .3 C .06 .5 .16 .62 .28 .62 C .42 .62 .5 .5 .5 .31 C .5 .12 .4 0 .27 0 C .16 0 .09 .06 .06 .14
        \#u{03C3} 0.64 M .62 .62 L .3 .6 C .14 .6 .04 .46 .04 .3 C .04 .12 .14 0 .28 0 C .42 0 .5 .12 .5 .28 C .5 .46 .42 .58 .3 .6
        \#u{03C4} 0.5 M .02 .56 Q .06 .62 .14 .62 L .48 .62 M .26 .62 L .26 .1 Q .26 0 .36 .02
        \#u{03C6} 0.66 A .33 .31 .29 .3 90 360 M .33 .98 L .33 -.32
        \#u{03C9} 0.72 M .14 .6 C .06 .48 .04 .36 .04 .26 C .04 .1 .1 0 .2 0 C .3 0 .34 .1 .36 .28 C .38 .1 .42 0 .52 0 C .62 0 .68 .1 .68 .26 C .68 .36 .66 .48 .58 .6
        \#u{03A9} 0.8 M .04 0 L .26 0 L .26 .1 C .12 .2 .06 .36 .06 .54 C .06 .82 .22 1 .4 1 C .58 1 .74 .82 .74 .54 C .74 .36 .68 .2 .54 .1 L .54 0 L .76 0
        \#u{201C} 0.34 M .16 1 Q .08 .9 .1 .76 M .32 1 Q .24 .9 .26 .76
        \#u{201D} 0.34 M .1 1 Q .16 .9 .06 .76 M .26 1 Q .32 .9 .22 .76
        \#u{2018} 0.2 M .14 1 Q .06 .9 .08 .76
        \#u{2019} 0.2 M .08 1 Q .14 .9 .04 .76
        \#u{2013} 0.54 M .04 .38 L .5 .38
        \#u{2014} 0.9 M .04 .38 L .86 .38
        \#u{2026} 0.56 M .06 .03 L .09 0 M .26 .03 L .29 0 M .46 .03 L .49 0
        \#u{0131} 0.12 M .06 .62 L .06 0
        \#u{0237} 0.3 M .24 .62 L .24 -.16 C .24 -.28 .18 -.33 .11 -.33 C .06 -.33 .02 -.31 0 -.27
        \#u{00F8} 0.54 A .27 .31 .27 .31 80 365 M .5 .68 L .04 -.06
        \#u{00D8} 0.9 A .45 .5 .43 .5 95 368 M .84 1.04 L .06 -.04
        \#u{20AC} 0.76 A .48 .5 .4 .5 50 260 M .02 .6 L .5 .6 M .02 .4 L .46 .4
        \#u{00A3} 0.64 M .54 .86 C .5 .96 .44 1 .36 1 C .24 1 .18 .9 .18 .78 L .18 .3 C .18 .14 .12 .04 .04 0 L .62 0 M .04 .5 L .42 .5
        \#u{2022} 0.24 A .12 .4 .07 .07 0 360 | A .12 .4 .03 .03 0 360
        \#u{00B7} 0.14 M .06 .4 L .09 .37
        \#u{222B} 0.4 M .36 1 C .3 1.06 .2 1.04 .2 .9 L .18 -.1 C .18 -.24 .08 -.26 .02 -.2
        \#u{2713} 0.62 M .04 .36 L .2 .04 Q .32 .44 .6 .78
        \#u{2717} 0.56 M .06 .7 L .5 .04 M .5 .7 L .06 .04
        """#

    /// Characters drawn with other ones: ligatures, look-alikes and letters
    /// the font spells out (æ → ae).
    private static let standIns: [Character: String] = [
        "\u{00A0}": " ", "\u{2007}": " ", "\u{202F}": " ",
        "\u{2010}": "-", "\u{2011}": "-", "\u{2012}": "\u{2013}", "\u{2015}": "\u{2014}", "\u{2212}": "-",
        "\u{2032}": "'", "\u{2033}": "\"", "\u{00B4}": "'", "\u{201A}": ",", "\u{201B}": "\u{2018}",
        "\u{201E}": "\u{201D}", "\u{201F}": "\u{201C}",
        "\u{00AB}": "<<", "\u{00BB}": ">>", "\u{2039}": "<", "\u{203A}": ">",
        "\u{00A1}": "!", "\u{00BF}": "?", "\u{02C6}": "^", "\u{02DC}": "~",
        "\u{00E6}": "ae", "\u{00C6}": "AE", "\u{0153}": "oe", "\u{0152}": "OE", "\u{00DF}": "ss", "\u{1E9E}": "SS",
        "\u{0142}": "l", "\u{0141}": "L", "\u{0111}": "d", "\u{0110}": "D", "\u{00F0}": "d", "\u{00D0}": "D",
        "\u{00FE}": "p", "\u{00DE}": "P", "\u{0127}": "h", "\u{0126}": "H",
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl",
        "\u{00BC}": "1/4", "\u{00BD}": "1/2", "\u{00BE}": "3/4", "\u{2153}": "1/3", "\u{2154}": "2/3",
        "\u{00A9}": "(c)", "\u{00AE}": "(R)", "\u{2122}": "TM",
        "\u{2206}": "\u{0394}", "\u{03A3}": "\u{2211}", "\u{00B5}": "\u{03BC}", "\u{03D5}": "\u{03C6}",
        "\u{21D2}": "\u{2192}", "\u{21D0}": "\u{2190}", "\u{27F6}": "\u{2192}", "\u{27F5}": "\u{2190}",
        "\u{2794}": "\u{2192}", "\u{279C}": "\u{2192}",
        "\u{22C5}": "\u{00B7}", "\u{2219}": "\u{00B7}", "\u{2027}": "\u{00B7}",
        "\u{2A7D}": "\u{2264}", "\u{2A7E}": "\u{2265}",
        "\u{2714}": "\u{2713}", "\u{2718}": "\u{2717}", "\u{2716}": "\u{00D7}",
    ]

    /// Reads `glyphSource` into the drawn letters.
    private static func makeGlyphTable() -> [Character: Glyph] {
        var table: [Character: Glyph] = [" ": space]
        for line in glyphSource.split(whereSeparator: \.isNewline) {
            guard let key = line.first, !key.isWhitespace else { continue }
            let tokens = line.dropFirst().split(separator: " ")
            guard let width = tokens.first else { continue }
            table[key] = Glyph(advance: number(width) + letterGap, slant: slant, strokes: parsePath(tokens.dropFirst()))
        }
        return table
    }

    /// Small raised and lowered copies of the digits and a few signs (x²,
    /// H₂O): which character each is a copy of, and how far it's lifted.
    private static let smallForms: [Character: (plain: Character, lift: CGFloat)] = {
        let raised: [UInt32] = [0x2070, 0x00B9, 0x00B2, 0x00B3, 0x2074, 0x2075, 0x2076, 0x2077, 0x2078, 0x2079]
        var small: [(up: UInt32, down: UInt32, plain: Character)] = (0...9).map { digit in
            (up: raised[digit], down: 0x2080 + UInt32(digit), plain: Character(String(digit)))
        }
        small += [(0x207A, 0x208A, "+"), (0x207B, 0x208B, "-"), (0x207C, 0x208C, "="), (0x207D, 0x208D, "("),
                  (0x207E, 0x208E, ")"), (0x207F, 0x2099, "n"), (0x2071, 0x1D62, "i"), (0x02E3, 0x2093, "x")]
        var forms: [Character: (plain: Character, lift: CGFloat)] = [:]
        for entry in small {
            if let up = Unicode.Scalar(entry.up) { forms[Character(up)] = (plain: entry.plain, lift: 0.44) }
            if let down = Unicode.Scalar(entry.down) { forms[Character(down)] = (plain: entry.plain, lift: -0.16) }
        }
        return forms
    }()

    private static func shrunk(_ glyph: Glyph, lift: CGFloat) -> Glyph {
        let scale: CGFloat = 0.58
        return Glyph(advance: glyph.advance * scale, slant: glyph.slant, strokes: glyph.strokes.map { stroke in
            stroke.map { CGPoint(x: $0.x * scale, y: $0.y * scale + lift) }
        })
    }

    /// Turns path commands into strokes, with curves cut into straight bits
    /// `spacing` long. With `repeatsCommands`, more numbers after a command
    /// repeat it (after `M`, as lines), as in SVG; `H x` and `V y` draw
    /// straight across or down to there, and `Z` goes back to the start.
    private static func parsePath(_ tokens: ArraySlice<Substring>, spacing: CGFloat = flatness, repeatsCommands: Bool = false) -> [[CGPoint]] {
        let tokens = Array(tokens)
        let repeatable: Set<Substring> = ["M", "L", "H", "V", "Q", "C", "A"]
        var index = 0
        var strokes: [[CGPoint]] = []
        var current: [CGPoint] = []
        var last: Substring = ""

        func value() -> CGFloat {
            defer { index += 1 }
            return index < tokens.count ? number(tokens[index]) : 0
        }
        func point() -> CGPoint {
            let x = value()
            return CGPoint(x: x, y: value())
        }
        func lift() {
            if current.count == 1 { current.append(current[0]) }
            if !current.isEmpty { strokes.append(current) }
            current.removeAll()
        }

        while index < tokens.count {
            var command = tokens[index]
            if repeatsCommands && isNumber(command) {
                guard repeatable.contains(last) else {
                    index += 1
                    continue
                }
                command = last == "M" ? "L" : last
            } else {
                index += 1
            }
            switch command {
            case "M":
                lift()
                current.append(point())
            case "L":
                current.append(point())
            case "H":
                let x = value()
                current.append(CGPoint(x: x, y: current.last?.y ?? 0))
            case "V":
                let y = value()
                current.append(CGPoint(x: current.last?.x ?? 0, y: y))
            case "Q":
                let control = point()
                let end = point()
                current += quadratic(current.last ?? control, control, end, spacing: spacing)
            case "C":
                let first = point()
                let second = point()
                let end = point()
                current += cubic(current.last ?? first, first, second, end, spacing: spacing)
            case "A":
                let center = point()
                let radiusX = value()
                let radiusY = value()
                let start = value()
                let sweep = value()
                current += ellipse(center: center, radii: CGSize(width: radiusX, height: radiusY), from: start, sweep: sweep, spacing: spacing)
            case "Z":
                if let start = current.first, current.count > 1 { current.append(start) }
            case "|":
                lift()
            default:
                break
            }
            last = command
        }
        lift()
        return strokes
    }

    /// Reads a number like "-.32" or "1.04".
    private static func number(_ text: Substring) -> CGFloat {
        var sign: CGFloat = 1, total: CGFloat = 0, place: CGFloat = 0
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "-"):
                sign = -1
            case UInt8(ascii: "."):
                place = 1
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                let digit = CGFloat(byte - UInt8(ascii: "0"))
                if place == 0 {
                    total = total * 10 + digit
                } else {
                    place /= 10
                    total += digit * place
                }
            default:
                break
            }
        }
        return sign * total
    }

    // MARK: Accents

    /// A letter with accents (é, ñ, ü, ç…): its plain letter plus small
    /// accent strokes, or nil when there's no plain letter to build on.
    private static func accented(_ character: Character) -> Glyph? {
        let scalars = Array(String(character).decomposedStringWithCanonicalMapping.unicodeScalars)
        guard scalars.count > 1 else { return nil }
        var base = Character(scalars[0])
        // An accent replaces the dot on i and j.
        if base == "i" { base = "\u{0131}" } else if base == "j" { base = "\u{0237}" }
        guard let plain = glyphs(for: base).first, !plain.strokes.isEmpty else { return nil }
        // Accents sit over the middle of the letter, just above its top.
        let points = plain.strokes.joined()
        var height = (points.map(\.y).max() ?? 0.62) + 0.1
        var strokes = plain.strokes
        for mark in scalars.dropFirst() {
            let (marks, used) = accent(mark.value, middle: plain.middle, height: height)
            strokes += marks
            height += used
        }
        return Glyph(advance: plain.advance, slant: plain.slant, strokes: strokes)
    }

    /// One accent's strokes, centered on `middle` and sitting at `height`
    /// (cedillas and ogoneks hang below the line instead), and how much
    /// height it uses up.
    private static func accent(_ code: UInt32, middle x: CGFloat, height y: CGFloat) -> ([[CGPoint]], CGFloat) {
        func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
        switch code {
        case 0x301: // acute
            return ([[at(-0.04, 0), at(0.07, 0.14)]], 0.18)
        case 0x300: // grave
            return ([[at(-0.07, 0.14), at(0.04, 0)]], 0.18)
        case 0x302: // circumflex
            return ([[at(-0.1, 0), at(0, 0.12), at(0.1, 0)]], 0.16)
        case 0x30C: // caron
            return ([[at(-0.1, 0.12), at(0, 0), at(0.1, 0.12)]], 0.16)
        case 0x303: // tilde
            let start = at(-0.12, 0.02)
            return ([[start] + cubic(start, at(-0.06, 0.15), at(0.06, -0.05), at(0.12, 0.09), spacing: flatness)], 0.15)
        case 0x304: // macron
            return ([[at(-0.12, 0.05), at(0.12, 0.05)]], 0.1)
        case 0x306: // breve
            let start = at(-0.1, 0.12)
            return ([[start] + quadratic(start, at(0, -0.04), at(0.1, 0.12), spacing: flatness)], 0.16)
        case 0x307: // dot above
            return ([[at(-0.01, 0.03), at(0.01, 0.06)]], 0.1)
        case 0x308: // diaeresis
            return ([[at(-0.1, 0.03), at(-0.08, 0.06)], [at(0.08, 0.03), at(0.1, 0.06)]], 0.1)
        case 0x30A: // ring
            return ([ellipse(center: at(0, 0.08), radii: CGSize(width: 0.06, height: 0.07), from: 90, sweep: 365, spacing: flatness)], 0.18)
        case 0x30B: // double acute
            return ([[at(-0.1, 0), at(-0.02, 0.14)], [at(0.04, 0), at(0.12, 0.14)]], 0.18)
        case 0x327: // cedilla
            let turn = CGPoint(x: x + 0.01, y: -0.08)
            return ([[CGPoint(x: x, y: 0), turn] + quadratic(turn, CGPoint(x: x + 0.12, y: -0.1), CGPoint(x: x - 0.05, y: -0.19), spacing: flatness)], 0)
        case 0x328: // ogonek
            let start = CGPoint(x: x + 0.1, y: 0)
            return ([[start] + quadratic(start, CGPoint(x: x, y: -0.12), CGPoint(x: x + 0.14, y: -0.17), spacing: flatness)], 0)
        default:
            return ([], 0)
        }
    }
}
