import CoreGraphics
import Foundation
import SwiftData

// Every stored property has a default value and every relationship is
// optional. Those are SwiftData's CloudKit rules, so iCloud sync can be
// turned on later without a migration.

/// Where a notebook was scrolled to, so it reopens at the same spot.
struct Viewport: Codable, Hashable, Sendable {
    /// Center of the visible area, in canvas points.
    var centerX: Double
    var centerY: Double
    var zoom: Double
}

/// Where a PDF was being read, so it reopens at the same spot.
struct ReadingPosition: Codable, Hashable, Sendable {
    var pageIndex: Int
    /// The point (PDF page space) at the top-left of the visible area.
    var x: Double
    var y: Double
    var scale: Double
}

struct CodableRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

enum HighlightColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow, green, blue, pink

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@Model
final class Notebook {
    var id: UUID = UUID()
    var title: String = "Untitled Notebook"
    var createdAt: Date = Date.now
    /// Last content edit (ink or text). Viewport changes don't touch it.
    var modifiedAt: Date = Date.now
    var lastOpenedAt: Date = Date.now
    /// The page that was open last, so the notebook reopens on it.
    var currentPageID: UUID? = nil

    @Relationship(deleteRule: .cascade, inverse: \NotebookPage.notebook)
    var pages: [NotebookPage]? = []

    // From before notebooks had pages, when a notebook was one canvas.
    // `ensureFirstPage(in:)` moves them into page 1.
    @Attribute(.externalStorage) var drawingData: Data? = nil
    var viewport: Viewport? = nil
    @Relationship(deleteRule: .cascade, inverse: \TextBox.notebook)
    var textBoxes: [TextBox]? = []

    init(title: String = "Untitled Notebook") {
        self.title = title
    }
}

/// One page of a notebook. Each page is its own infinite canvas.
@Model
final class NotebookPage {
    var id: UUID = UUID()
    /// Empty means the default name, "Page 3".
    var title: String = ""
    /// Position in the notebook, from 0.
    var sortIndex: Int = 0
    var createdAt: Date = Date.now
    /// Last content edit (ink or text).
    var modifiedAt: Date = Date.now
    /// `PKDrawing.dataRepresentation()` of the page's canvas.
    @Attribute(.externalStorage) var drawingData: Data? = nil
    var viewport: Viewport? = nil
    var notebook: Notebook? = nil

    @Relationship(deleteRule: .cascade, inverse: \TextBox.notebookPage)
    var textBoxes: [TextBox]? = []

    init(sortIndex: Int = 0) {
        self.sortIndex = sortIndex
    }

    func displayTitle(number: Int) -> String {
        title.isEmpty ? "Page \(number)" : title
    }
}

extension Notebook {
    /// Pages in notebook order.
    var sortedPages: [NotebookPage] {
        (pages ?? [])
            .filter { !$0.isDeleted }
            .sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }

    /// The page the library card shows.
    var coverPageID: UUID {
        sortedPages.first?.id ?? id
    }

    /// Makes sure the notebook has a page. A notebook from before pages
    /// existed gets its canvas moved into page 1.
    @discardableResult
    func ensureFirstPage(in context: ModelContext) -> NotebookPage {
        if let first = sortedPages.first { return first }
        let page = NotebookPage(sortIndex: 0)
        context.insert(page)
        page.notebook = self
        page.drawingData = drawingData
        page.viewport = viewport
        for box in textBoxes ?? [] {
            box.notebookPage = page
            box.notebook = nil
        }
        drawingData = nil
        viewport = nil
        FileStore.moveItem(at: FileStore.thumbnailURL(for: id), to: FileStore.thumbnailURL(for: page.id))
        return page
    }

    /// Adds a blank page right after `page`, or at the end.
    func addPage(after page: NotebookPage?, in context: ModelContext) -> NotebookPage {
        var ordered = sortedPages
        let position = page.flatMap { page in ordered.firstIndex { $0.id == page.id } }.map { $0 + 1 } ?? ordered.count
        let newPage = NotebookPage(sortIndex: position)
        context.insert(newPage)
        newPage.notebook = self
        ordered.insert(newPage, at: position)
        applyPageOrder(ordered)
        return newPage
    }

    /// Renumbers the pages to match `ordered`.
    func applyPageOrder(_ ordered: [NotebookPage]) {
        for (index, page) in ordered.enumerated() where page.sortIndex != index {
            page.sortIndex = index
        }
        modifiedAt = .now
    }
}

@Model
final class PDFItem {
    var id: UUID = UUID()
    var title: String = ""
    /// File name inside `FileStore.pdfDirectory`. The file is never modified.
    var fileName: String = ""
    var pageCount: Int = 0
    var importedAt: Date = Date.now
    /// Last annotation change.
    var modifiedAt: Date = Date.now
    var lastOpenedAt: Date = Date.now
    var readingPosition: ReadingPosition? = nil

    @Relationship(deleteRule: .cascade, inverse: \Highlight.pdf)
    var highlights: [Highlight]? = []
    @Relationship(deleteRule: .cascade, inverse: \PageInk.pdf)
    var pageInk: [PageInk]? = []
    @Relationship(deleteRule: .cascade, inverse: \TextBox.pdf)
    var textBoxes: [TextBox]? = []

    init(id: UUID, title: String, fileName: String, pageCount: Int) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.pageCount = pageCount
    }
}

@Model
final class Highlight {
    var id: UUID = UUID()
    var pageIndex: Int = 0
    var colorName: String = HighlightColor.yellow.rawValue
    /// One rectangle per line of text, in PDF page space.
    var rects: [CodableRect] = []
    /// The highlighted text, kept for search and export later.
    var text: String = ""
    var createdAt: Date = Date.now
    var pdf: PDFItem? = nil

    var color: HighlightColor {
        get { HighlightColor(rawValue: colorName) ?? .yellow }
        set { colorName = newValue.rawValue }
    }

    init(id: UUID = UUID(), pageIndex: Int, color: HighlightColor, rects: [CodableRect], text: String) {
        self.id = id
        self.pageIndex = pageIndex
        self.colorName = color.rawValue
        self.rects = rects
        self.text = text
    }
}

/// Pencil ink for one PDF page.
@Model
final class PageInk {
    var pageIndex: Int = 0
    /// `PKDrawing.dataRepresentation()`, in the page overlay's coordinates
    /// (page points, top-left origin).
    @Attribute(.externalStorage) var drawingData: Data? = nil
    var pdf: PDFItem? = nil

    init(pageIndex: Int, drawingData: Data?) {
        self.pageIndex = pageIndex
        self.drawingData = drawingData
    }
}

/// A typed text box. Used both on notebook canvases and on PDF pages.
@Model
final class TextBox {
    var id: UUID = UUID()
    /// Notebook: canvas points. PDF: page points with a top-left origin.
    var x: Double = 0
    var y: Double = 0
    var width: Double = 280
    /// Set only for text notes on a PDF page.
    var pageIndex: Int? = nil
    /// The styled text, archived with `RichText`.
    var richText: Data? = nil
    /// Plain copy of the text, kept for search later.
    var plainText: String = ""
    var createdAt: Date = Date.now
    var notebookPage: NotebookPage? = nil
    var pdf: PDFItem? = nil
    /// From before notebooks had pages. See `Notebook.ensureFirstPage(in:)`.
    var notebook: Notebook? = nil

    init(id: UUID = UUID(), x: Double, y: Double, width: Double, pageIndex: Int? = nil) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.pageIndex = pageIndex
    }
}

// MARK: - Snapshots for undo

/// Everything needed to bring back a deleted text box.
struct TextBoxSnapshot: Sendable {
    let id: UUID
    let x: Double
    let y: Double
    let width: Double
    let pageIndex: Int?
    let richText: Data?
    let plainText: String

    init(_ box: TextBox) {
        id = box.id
        x = box.x
        y = box.y
        width = box.width
        pageIndex = box.pageIndex
        richText = box.richText
        plainText = box.plainText
    }

    func makeModel() -> TextBox {
        let box = TextBox(id: id, x: x, y: y, width: width, pageIndex: pageIndex)
        box.richText = richText
        box.plainText = plainText
        return box
    }
}

/// Everything needed to bring back a deleted highlight.
struct HighlightSnapshot: Sendable {
    let id: UUID
    let pageIndex: Int
    let colorName: String
    let rects: [CodableRect]
    let text: String

    init(_ highlight: Highlight) {
        id = highlight.id
        pageIndex = highlight.pageIndex
        colorName = highlight.colorName
        rects = highlight.rects
        text = highlight.text
    }

    func makeModel() -> Highlight {
        Highlight(id: id, pageIndex: pageIndex, color: HighlightColor(rawValue: colorName) ?? .yellow, rects: rects, text: text)
    }
}
