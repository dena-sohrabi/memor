import SwiftUI

/// Claude's answers with their Markdown: headings, lists, quotes, code
/// blocks and rules as blocks, and bold, italics, inline code and links
/// within them. Works on half-finished text too, as the answer streams in.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Self.inline(text))
        case .listItem(let marker, let level, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 12, alignment: .trailing)
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(level) * 18)
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(.tertiary).frame(width: 3)
                }
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
            }
            .background(.background.opacity(0.55), in: .rect(cornerRadius: 10))
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    /// Bold, italics, code and links in one block, keeping its line breaks.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// The answer as plain text for a text box on the page: no Markdown
    /// symbols, with bullets and numbers kept.
    static func plainText(_ markdown: String) -> String {
        var lines: [String] = []
        for block in MarkdownBlock.parse(markdown) {
            switch block {
            case .heading(_, let text):
                if !lines.isEmpty { lines.append("") }
                lines.append(plain(text))
            case .paragraph(let text), .quote(let text):
                lines.append(plain(text))
            case .listItem(let marker, let level, let text):
                lines.append(String(repeating: "    ", count: level) + marker + " " + plain(text))
            case .code(let text):
                lines.append(text)
            case .rule:
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func plain(_ text: String) -> String {
        String(inline(text).characters)
    }
}

/// One block of a Markdown answer.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, level: Int, text: String)
    case quote(String)
    case code(String)
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [String] = []
        /// The lines of a fenced code block, while inside one.
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            if !table.isEmpty { blocks.append(.code(table.joined(separator: "\n"))) }
            paragraph = []
            quote = []
            table = []
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if var lines = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(rawLine)
                    code = lines
                }
                continue
            }
            if line.hasPrefix("```") {
                flush()
                code = []
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if let heading = heading(line) {
                flush()
                blocks.append(heading)
                continue
            }
            if isRule(line) {
                flush()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix("|") {
                if table.isEmpty { flush() }
                // Tables show as aligned text; their |---| rows are dropped.
                if !line.allSatisfy({ "|-: ".contains($0) }) { table.append(line) }
                continue
            }
            if line.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(rawLine) {
                flush()
                blocks.append(item)
                continue
            }
            // An indented line right after a list item continues it.
            if paragraph.isEmpty, quote.isEmpty, rawLine.first == " " || rawLine.first == "\t",
               case .listItem(let marker, let level, let text)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, level: level, text: text + "\n" + line)
                continue
            }
            if !quote.isEmpty || !table.isEmpty { flush() }
            paragraph.append(line)
        }
        // A code block that's still streaming in.
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes, text: text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
    }

    /// `---`, `***` or `___` (spaces allowed) on a line of its own.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard let first = marks.first, "-*_".contains(first), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func listItem(_ rawLine: String) -> MarkdownBlock? {
        let leading = rawLine.prefix(while: { $0 == " " || $0 == "\t" })
        let width = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let level = min(width / 2, 4)
        let rest = rawLine.dropFirst(leading.count)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return .listItem(marker: "•", level: level, text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix(while: \.isNumber)
        guard (1...3).contains(digits.count) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
        return .listItem(marker: String(digits) + ".", level: level, text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}
