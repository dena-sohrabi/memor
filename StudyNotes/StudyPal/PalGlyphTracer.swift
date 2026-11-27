import CoreGraphics
import CoreText
import Foundation

/// Letters traced from a handwriting font, so the study pal writes with the
/// shapes of a real hand instead of drawn ones. Each letter's outline is
/// filled in large, worn down to the one-pixel line along the middle of its
/// strokes, and that line is followed into pen strokes, written in about the
/// order and direction a person would.
///
/// It's all plain math with nothing shared, so it can run anywhere.
nonisolated enum PalGlyphTracer {
    /// A font on this iPad, ready to trace from.
    struct Font: Sendable {
        /// Its PostScript name.
        let name: String
        /// How tall its capital letters are at size 100.
        let capHeight: CGFloat
    }

    /// One traced letter, in capital-letter heights: the baseline is at
    /// y = 0 and y points up.
    struct Letter: Sendable {
        /// How far on the next letter starts.
        let advance: CGFloat
        /// Its pen strokes, in about the order they're written. A stroke
        /// with a single point is a dot.
        let strokes: [[CGPoint]]
        /// How thick the font's line is in this letter.
        let thickness: CGFloat
    }

    /// Letters are traced with a capital letter this many pixels tall.
    private static let capPixels: CGFloat = 120
    /// The size fonts are opened at.
    private static let fontSize: CGFloat = 100

    /// The first of `names` (PostScript names) that's on this iPad.
    static func font(named names: [String]) -> Font? {
        for name in names {
            let font = CTFontCreateWithName(name as CFString, fontSize, nil)
            // A missing font quietly turns into another one, so check it's the one asked for.
            guard (CTFontCopyPostScriptName(font) as String) == name else { continue }
            var capHeight = CTFontGetCapHeight(font)
            // In a handwriting font, the top of a real H beats what the font says.
            if let glyph = glyph(for: "H", in: font), let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
                let top = outline.boundingBoxOfPath.maxY
                if top > fontSize * 0.3, top < fontSize * 1.2 { capHeight = top }
            }
            guard capHeight > fontSize * 0.3, capHeight < fontSize * 1.2 else { continue }
            return Font(name: name, capHeight: capHeight)
        }
        return nil
    }

    /// How far on the pen moves after `character`, in capital-letter
    /// heights, or nil if the font doesn't have it.
    static func advance(of character: Character, in font: Font) -> CGFloat? {
        let ctFont = CTFontCreateWithName(font.name as CFString, fontSize, nil)
        guard var glyph = glyph(for: character, in: ctFont) else { return nil }
        var advance = CGSize.zero
        _ = CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        return advance.width / font.capHeight
    }

    /// Traces one letter into pen strokes, or nil when the font doesn't have
    /// it or it has no ink.
    static func trace(_ character: Character, in font: Font) -> Letter? {
        let ctFont = CTFontCreateWithName(font.name as CFString, fontSize, nil)
        guard var glyph = glyph(for: character, in: ctFont) else { return nil }
        var advance = CGSize.zero
        _ = CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        let scale = capPixels / font.capHeight
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        guard let outline = CTFontCreatePathForGlyph(ctFont, glyph, &transform), !outline.isEmpty,
              let raster = Raster(outline) else { return nil }
        let width = raster.width, height = raster.height

        var skeleton = raster.ink
        thin(&skeleton, width: width, height: height)
        squareCorners(&skeleton, width: width, height: height)

        // How thick the font's line is: twice how deep the middle of its
        // strokes lies in the ink.
        let depth = depths(raster.ink, width: width, height: height)
        var middles: [Int32] = []
        for index in skeleton.indices where skeleton[index] == 1 {
            middles.append(depth[index])
        }
        guard !middles.isEmpty else { return nil }
        middles.sort()
        let thickness = max(2 * CGFloat(middles[middles.count / 2]) / 3 - 1, 1)

        let found = lines(in: skeleton, width: width, height: height, thickness: thickness)
        guard !found.isEmpty, found.count <= 16 else { return nil }
        // From pixels (row 0 at the top) to capital-letter heights, y up.
        let left = CGFloat(raster.originX), top = CGFloat(raster.originY + height)
        let strokes = found.map { line -> [CGPoint] in
            written(line.map { CGPoint(x: (left + $0.x + 0.5) / capPixels, y: (top - $0.y - 0.5) / capPixels) })
        }
        return Letter(advance: advance.width / font.capHeight, strokes: writingOrder(strokes), thickness: thickness / capPixels)
    }

    /// The font's glyph for one character, or nil if it doesn't have one.
    private static func glyph(for character: Character, in font: CTFont) -> CGGlyph? {
        let units = Array(String(character).utf16)
        // A single character: one code unit, or a surrogate pair. (A letter
        // with a separate accent is built from its plain letter instead.)
        guard units.count == 1 || (units.count == 2 && UTF16.isLeadSurrogate(units[0])) else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    // MARK: Pixels

    /// A letter filled in as pixels, 1 for ink and 0 for paper, with row 0
    /// at the top and a clear margin all round.
    private struct Raster {
        let width: Int
        let height: Int
        /// Where the bottom-left corner of the pixels is, in the outline's
        /// coordinates (y up).
        let originX: Int
        let originY: Int
        let ink: [UInt8]

        init?(_ outline: CGPath) {
            let box = outline.boundingBoxOfPath
            guard !box.isNull, box.width > 0, box.height > 0,
                  box.width < PalGlyphTracer.capPixels * 4, box.height < PalGlyphTracer.capPixels * 4 else { return nil }
            let margin = 4
            let left = Int(box.minX.rounded(.down)) - margin
            let bottom = Int(box.minY.rounded(.down)) - margin
            // Rows a multiple of 16 bytes long, which Core Graphics likes.
            let columns = (Int(box.maxX.rounded(.up)) - left + margin + 15) / 16 * 16
            let rows = Int(box.maxY.rounded(.up)) - bottom + margin
            var pixels = [UInt8](repeating: 0, count: columns * rows)
            let filled = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: columns,
                    height: rows,
                    bitsPerComponent: 8,
                    bytesPerRow: columns,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.setFillColor(gray: 1, alpha: 1)
                context.translateBy(x: CGFloat(-left), y: CGFloat(-bottom))
                context.addPath(outline)
                context.fillPath()
                return true
            }
            guard filled else { return nil }
            var ink = pixels.map { $0 >= 128 ? UInt8(1) : UInt8(0) }
            // Keep the outer edge clear, so every inked pixel has neighbours all round.
            for column in 0..<columns {
                ink[column] = 0
                ink[(rows - 1) * columns + column] = 0
            }
            for row in 0..<rows {
                ink[row * columns] = 0
                ink[row * columns + columns - 1] = 0
            }
            width = columns
            height = rows
            originX = left
            originY = bottom
            self.ink = ink
        }
    }

    /// Wears the ink down to lines one pixel wide along the middle of its
    /// strokes, keeping their shape and how they join (Zhang–Suen thinning).
    private static func thin(_ grid: inout [UInt8], width: Int, height: Int) {
        var doomed: [Int] = []
        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                doomed.removeAll(keepingCapacity: true)
                for row in 1..<(height - 1) {
                    for column in 1..<(width - 1) {
                        let i = row * width + column
                        guard grid[i] == 1 else { continue }
                        // The eight neighbours, clockwise from the one above.
                        let n = grid[i - width], ne = grid[i - width + 1], e = grid[i + 1], se = grid[i + width + 1]
                        let s = grid[i + width], sw = grid[i + width - 1], w = grid[i - 1], nw = grid[i - width - 1]
                        let inked = Int(n &+ ne &+ e &+ se) + Int(s &+ sw &+ w &+ nw)
                        guard inked >= 2, inked <= 6 else { continue }
                        // Going round, ink should start only once.
                        var starts = 0
                        if n == 0 && ne == 1 { starts += 1 }
                        if ne == 0 && e == 1 { starts += 1 }
                        if e == 0 && se == 1 { starts += 1 }
                        if se == 0 && s == 1 { starts += 1 }
                        if s == 0 && sw == 1 { starts += 1 }
                        if sw == 0 && w == 1 { starts += 1 }
                        if w == 0 && nw == 1 { starts += 1 }
                        if nw == 0 && n == 1 { starts += 1 }
                        guard starts == 1 else { continue }
                        if pass == 0 {
                            guard n & e & s == 0, e & s & w == 0 else { continue }
                        } else {
                            guard n & e & w == 0, n & s & w == 0 else { continue }
                        }
                        doomed.append(i)
                    }
                }
                for i in doomed { grid[i] = 0 }
                if !doomed.isEmpty { changed = true }
            }
        }
    }

    /// Takes the inside corner off steps in the thinned lines, so each is a
    /// clean chain of pixels without little triangles where it turns.
    private static func squareCorners(_ grid: inout [UInt8], width: Int, height: Int) {
        for row in 1..<(height - 1) {
            for column in 1..<(width - 1) {
                let i = row * width + column
                guard grid[i] == 1 else { continue }
                let n = grid[i - width], ne = grid[i - width + 1], e = grid[i + 1], se = grid[i + width + 1]
                let s = grid[i + width], sw = grid[i + width - 1], w = grid[i - 1], nw = grid[i - width - 1]
                // Two neighbours that touch each other anyway, with nothing on the other side.
                let upRight = n == 1 && e == 1 && s == 0 && w == 0 && sw == 0
                let downRight = e == 1 && s == 1 && w == 0 && n == 0 && nw == 0
                let downLeft = s == 1 && w == 1 && n == 0 && e == 0 && ne == 0
                let upLeft = w == 1 && n == 1 && e == 0 && s == 0 && se == 0
                if upRight || downRight || downLeft || upLeft { grid[i] = 0 }
            }
        }
    }

    /// How deep each pixel lies in the ink: 3 for each step straight to the
    /// nearest paper, 4 for each step on the diagonal (a chamfer distance).
    private static func depths(_ ink: [UInt8], width: Int, height: Int) -> [Int32] {
        var depth: [Int32] = ink.map { $0 == 1 ? Int32.max / 2 : 0 }
        for row in 1..<(height - 1) {
            for column in 1..<(width - 1) {
                let i = row * width + column
                guard depth[i] > 0 else { continue }
                depth[i] = min(depth[i], depth[i - 1] + 3, depth[i - width] + 3, depth[i - width - 1] + 4, depth[i - width + 1] + 4)
            }
        }
        for row in stride(from: height - 2, through: 1, by: -1) {
            for column in stride(from: width - 2, through: 1, by: -1) {
                let i = row * width + column
                guard depth[i] > 0 else { continue }
                depth[i] = min(depth[i], depth[i + 1] + 3, depth[i + width] + 3, depth[i + width + 1] + 4, depth[i + width - 1] + 4)
            }
        }
        return depth
    }

    // MARK: Strokes

    /// Follows the thinned lines into pen strokes, in pixels (x across, y
    /// down from the top): straight on through crossings, with the little
    /// stubs thinning leaves at ends and corners trimmed off, then smoothed.
    private static func lines(in skeleton: [UInt8], width: Int, height: Int, thickness: CGFloat) -> [[CGPoint]] {
        let count = skeleton.count
        let around = [-width - 1, -width, -width + 1, -1, 1, width - 1, width, width + 1]
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(i % width), y: CGFloat(i / width))
        }

        var degree = [Int](repeating: 0, count: count)
        for i in 0..<count where skeleton[i] == 1 {
            var neighbours = 0
            for step in around where skeleton[i + step] == 1 { neighbours += 1 }
            degree[i] = neighbours
        }

        // Ends, dots and crossings are where lines meet; crossing pixels
        // side by side make one meeting point.
        var nodeOf = [Int](repeating: -1, count: count)
        var nodes: [CGPoint] = []
        for i in 0..<count where skeleton[i] == 1 && degree[i] != 2 && nodeOf[i] == -1 {
            let node = nodes.count
            nodeOf[i] = node
            var members = [i]
            var next = 0
            while degree[i] > 2 && next < members.count {
                let pixel = members[next]
                next += 1
                for step in around {
                    let other = pixel + step
                    if skeleton[other] == 1 && degree[other] > 2 && nodeOf[other] == -1 {
                        nodeOf[other] = node
                        members.append(other)
                    }
                }
            }
            var sumX: CGFloat = 0, sumY: CGFloat = 0
            for pixel in members {
                sumX += point(pixel).x
                sumY += point(pixel).y
            }
            nodes.append(CGPoint(x: sumX / CGFloat(members.count), y: sumY / CGFloat(members.count)))
        }

        // The lines between meeting points. A loop with no meeting point
        // (like an o) has a and b of -1.
        struct Edge {
            var a: Int
            var b: Int
            var points: [CGPoint]
            var alive = true
        }
        var edges: [Edge] = []
        var visited = [Bool](repeating: false, count: count)
        var joined = Set<Int>()
        for i in 0..<count where nodeOf[i] != -1 {
            for step in around {
                let first = i + step
                guard skeleton[first] == 1 else { continue }
                if nodeOf[first] != -1 {
                    // Two meeting points side by side.
                    guard nodeOf[first] != nodeOf[i], joined.insert(min(i, first) * count + max(i, first)).inserted else { continue }
                    edges.append(Edge(a: nodeOf[i], b: nodeOf[first], points: [nodes[nodeOf[i]], nodes[nodeOf[first]]]))
                    continue
                }
                guard !visited[first] else { continue }
                visited[first] = true
                var line = [nodes[nodeOf[i]], point(first)]
                var previous = i, current = first
                var end = -1
                while end == -1 {
                    var next = -1
                    for step in around where skeleton[current + step] == 1 && current + step != previous {
                        next = current + step
                        break
                    }
                    if next == -1 { break }
                    if nodeOf[next] != -1 {
                        line.append(nodes[nodeOf[next]])
                        end = nodeOf[next]
                    } else if visited[next] {
                        break
                    } else {
                        visited[next] = true
                        line.append(point(next))
                        previous = current
                        current = next
                    }
                }
                if end != -1 { edges.append(Edge(a: nodeOf[i], b: end, points: line)) }
            }
        }
        for i in 0..<count where skeleton[i] == 1 && nodeOf[i] == -1 && !visited[i] {
            visited[i] = true
            var line = [point(i)]
            var previous = -1, current = i
            var closed = false
            while !closed {
                var next = -1
                for step in around {
                    let other = current + step
                    guard skeleton[other] == 1, other != previous else { continue }
                    if other == i {
                        if line.count > 2 {
                            closed = true
                            break
                        }
                        continue
                    }
                    if !visited[other] {
                        next = other
                        break
                    }
                }
                if closed || next == -1 { break }
                visited[next] = true
                line.append(point(next))
                previous = current
                current = next
            }
            if line.count > 2 {
                line.append(line[0])
                edges.append(Edge(a: -1, b: -1, points: line))
            }
        }

        // Which bits of ink belong together, so a bit left with only stubs
        // can become a dot.
        var group = Array(nodes.indices)
        func top(_ node: Int) -> Int {
            var node = node
            while group[node] != node { node = group[node] }
            return node
        }
        for edge in edges where edge.a >= 0 {
            let x = top(edge.a), y = top(edge.b)
            if x != y { group[x] = y }
        }

        // Trim the stubs thinning leaves (short lines from an end to a
        // crossing, and tiny loops), and join crossings that sit so close
        // they're really one.
        let stub = max(thickness * 0.8, 3)
        func ends() -> [Int] {
            var counts = [Int](repeating: 0, count: nodes.count)
            for edge in edges where edge.alive && edge.a >= 0 {
                counts[edge.a] += 1
                counts[edge.b] += 1
            }
            return counts
        }
        for _ in 0..<3 {
            var changed = false
            let before = ends()
            for index in edges.indices where edges[index].alive {
                let edge = edges[index]
                let size = length(edge.points)
                let stubby: Bool
                if edge.a < 0 {
                    stubby = size < stub * 2
                } else if edge.a == edge.b {
                    stubby = size < stub * 2.5
                } else {
                    let fewer = min(before[edge.a], before[edge.b]), more = max(before[edge.a], before[edge.b])
                    stubby = size < stub && fewer == 1 && more >= 3
                }
                if stubby {
                    edges[index].alive = false
                    changed = true
                }
            }
            var degrees = ends()
            for index in edges.indices where edges[index].alive {
                let edge = edges[index]
                guard edge.a >= 0, edge.a != edge.b, degrees[edge.a] >= 3, degrees[edge.b] >= 3, length(edge.points) < thickness else { continue }
                edges[index].alive = false
                let middle = CGPoint(x: (nodes[edge.a].x + nodes[edge.b].x) / 2, y: (nodes[edge.a].y + nodes[edge.b].y) / 2)
                nodes[edge.a] = middle
                for other in edges.indices where edges[other].alive && edges[other].a >= 0 {
                    if edges[other].a == edge.b { edges[other].a = edge.a }
                    if edges[other].b == edge.b { edges[other].b = edge.a }
                    let last = edges[other].points.count - 1
                    if edges[other].a == edge.a { edges[other].points[0] = middle }
                    if edges[other].b == edge.a { edges[other].points[last] = middle }
                }
                degrees[edge.a] += degrees[edge.b] - 2
                degrees[edge.b] = 0
                changed = true
            }
            if !changed { break }
        }

        // At each crossing, pair up the lines that carry on most nearly
        // straight; the rest start or end there.
        let reach = max(thickness * 1.5, 4)
        func heading(_ edge: Int, fromStart: Bool) -> CGPoint {
            let points = fromStart ? edges[edge].points : Array(edges[edge].points.reversed())
            let origin = points[0]
            var far = origin
            for spot in points.dropFirst() {
                far = spot
                if hypot(spot.x - origin.x, spot.y - origin.y) >= reach { break }
            }
            let dx = far.x - origin.x, dy = far.y - origin.y
            let size = hypot(dx, dy)
            return size > 0 ? CGPoint(x: dx / size, y: dy / size) : .zero
        }
        // Each end of each line is `index * 2` (its start) or `index * 2 + 1`.
        var meeting = [[Int]](repeating: [], count: nodes.count)
        for index in edges.indices where edges[index].alive && edges[index].a >= 0 {
            meeting[edges[index].a].append(index * 2)
            meeting[edges[index].b].append(index * 2 + 1)
        }
        var partner: [Int: Int] = [:]
        for here in meeting where here.count >= 2 {
            if here.count == 2 {
                partner[here[0]] = here[1]
                partner[here[1]] = here[0]
                continue
            }
            let headings = here.map { heading($0 / 2, fromStart: $0 % 2 == 0) }
            var pairs: [(score: CGFloat, first: Int, second: Int)] = []
            for first in here.indices {
                for second in here.indices where second > first {
                    let score = headings[first].x * headings[second].x + headings[first].y * headings[second].y
                    pairs.append((score: score, first: first, second: second))
                }
            }
            pairs.sort { $0.score < $1.score }
            var taken = Set<Int>()
            for pair in pairs where pair.score < -0.4 && !taken.contains(pair.first) && !taken.contains(pair.second) {
                taken.insert(pair.first)
                taken.insert(pair.second)
                partner[here[pair.first]] = here[pair.second]
                partner[here[pair.second]] = here[pair.first]
            }
        }

        // Chain the paired lines into pen strokes.
        var strokes: [(points: [CGPoint], closed: Bool)] = []
        var used = [Bool](repeating: false, count: edges.count)
        for start in edges.indices where edges[start].alive && !used[start] {
            if edges[start].a < 0 {
                used[start] = true
                strokes.append((points: edges[start].points, closed: true))
                continue
            }
            // Back up to where this stroke begins (anywhere, if it goes round in a loop).
            var edge = start, entry = 0
            var steps = 0
            while let previous = partner[edge * 2 + entry], previous / 2 != start, steps < edges.count {
                edge = previous / 2
                entry = 1 - previous % 2
                steps += 1
            }
            let first = edge
            var points: [CGPoint] = []
            var closed = false
            while true {
                used[edge] = true
                let path = entry == 0 ? edges[edge].points : Array(edges[edge].points.reversed())
                points += points.isEmpty ? path : Array(path.dropFirst())
                guard let next = partner[edge * 2 + 1 - entry] else { break }
                if next / 2 == first {
                    closed = true
                    break
                }
                if used[next / 2] { break }
                edge = next / 2
                entry = next % 2
            }
            strokes.append((points: points, closed: closed))
        }

        // A bit of ink with nothing left but stubs is a dot (on an i, or a full stop).
        var hasLine = Set<Int>()
        for edge in edges where edge.alive && edge.a >= 0 { hasLine.insert(top(edge.a)) }
        var dots: [Int: [CGPoint]] = [:]
        for node in nodes.indices where !hasLine.contains(top(node)) {
            dots[top(node), default: []].append(nodes[node])
        }
        for key in dots.keys.sorted() {
            guard let members = dots[key], !members.isEmpty else { continue }
            let x = members.reduce(0) { $0 + $1.x } / CGFloat(members.count)
            let y = members.reduce(0) { $0 + $1.y } / CGFloat(members.count)
            strokes.append((points: [CGPoint(x: x, y: y)], closed: false))
        }

        let radius = min(max(Int((thickness * 0.3).rounded()), 1), 4)
        return strokes.map { stroke -> [CGPoint] in
            var points = stroke.points
            guard points.count > 2 else { return points }
            for _ in 0..<2 {
                points = smoothed(points, radius: radius, closed: stroke.closed)
            }
            return simplified(points, tolerance: 0.35)
        }
    }

    /// Turns a stroke the way it's usually written: a loop starts near its
    /// top right and goes counterclockwise, like an o; a line starts at its
    /// top, or at its left when it's flat. (Capital-letter heights, y up.)
    private static func written(_ stroke: [CGPoint]) -> [CGPoint] {
        guard stroke.count > 1, let first = stroke.first, let last = stroke.last else { return stroke }
        if stroke.count > 3 && hypot(last.x - first.x, last.y - first.y) < 0.02 {
            var ring = Array(stroke.dropLast())
            // Counterclockwise, with y up, has a positive area.
            var area: CGFloat = 0
            for index in ring.indices {
                let a = ring[index], b = ring[(index + 1) % ring.count]
                area += a.x * b.y - b.x * a.y
            }
            if area < 0 { ring.reverse() }
            let start = ring.indices.max { ring[$0].y + 0.35 * ring[$0].x < ring[$1].y + 0.35 * ring[$1].x } ?? 0
            ring = Array(ring[start...] + ring[..<start])
            ring.append(ring[0])
            return ring
        }
        func lead(_ point: CGPoint) -> CGFloat { point.y - 0.6 * point.x }
        return lead(first) >= lead(last) ? stroke : Array(stroke.reversed())
    }

    /// Puts strokes in about the order they're written: left to right, with
    /// flat bars (as on t and f) after the strokes they cross, and dots last.
    private static func writingOrder(_ strokes: [[CGPoint]]) -> [[CGPoint]] {
        func rank(_ stroke: [CGPoint]) -> CGFloat {
            let xs = stroke.map(\.x), ys = stroke.map(\.y)
            let left = xs.min() ?? 0
            let wide = (xs.max() ?? 0) - left
            let tall = (ys.max() ?? 0) - (ys.min() ?? 0)
            if max(wide, tall) < 0.08 { return left + 100 }
            if tall < wide * 0.3 { return left + 0.3 }
            return left
        }
        return strokes.map { (rank: rank($0), stroke: $0) }.sorted { $0.rank < $1.rank }.map { $0.stroke }
    }

    /// Evens out the pixel steps with a moving average, keeping the ends
    /// of an open stroke where they are.
    private static func smoothed(_ points: [CGPoint], radius: Int, closed: Bool) -> [CGPoint] {
        var ring = points
        if closed { ring.removeLast() }
        let count = ring.count
        guard count > 2 else { return points }
        var result: [CGPoint] = []
        result.reserveCapacity(count + 1)
        for index in 0..<count {
            // Near the ends of an open stroke, the window shrinks so the ends stay put.
            let reach = closed ? radius : min(radius, index, count - 1 - index)
            var x: CGFloat = 0, y: CGFloat = 0
            for offset in -reach...reach {
                let point = ring[((index + offset) % count + count) % count]
                x += point.x
                y += point.y
            }
            let total = CGFloat(2 * reach + 1)
            result.append(CGPoint(x: x / total, y: y / total))
        }
        if closed { result.append(result[0]) }
        return result
    }

    /// Drops points that lie within `tolerance` of the line through their
    /// neighbours (Ramer–Douglas–Peucker).
    private static func simplified(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var spans = [(points.startIndex, points.count - 1)]
        while let span = spans.popLast() {
            let (first, last) = span
            guard last > first + 1 else { continue }
            var farthest = -1
            var most: CGFloat = 0
            for index in (first + 1)..<last {
                let away = distance(from: points[index], toSegment: points[first], points[last])
                if away > most {
                    most = away
                    farthest = index
                }
            }
            if farthest > 0 && most > tolerance {
                keep[farthest] = true
                spans.append((first, farthest))
                spans.append((farthest, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    private static func length(_ points: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for index in points.indices.dropFirst() {
            total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        return total
    }
}
