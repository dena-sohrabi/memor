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
    @Relationship(deleteRule: .cascade, inverse: \CanvasImage.page)
    var images: [CanvasImage]? = []
    @Relationship(deleteRule: .cascade, inverse: \AskThread.notebookPage)
    var askThreads: [AskThread]? = []

    init(sortIndex: Int = 0) {
        self.sortIndex = sortIndex
    }

    func displayTitle(number: Int) -> String {
        title.isEmpty ? "Page \(number)" : title
    }
}

extension NotebookPage {
    /// The page's position in its notebook, from 1.
    var number: Int {
        (notebook?.sortedPages.firstIndex { $0.id == id } ?? 0) + 1
    }

    /// The title as shown and edited: "Page 3" until renamed. Renaming it
    /// back to the default name, or to nothing, clears the custom title.
    var editableTitle: String {
        get { displayTitle(number: number) }
        set {
            let newTitle = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            title = newTitle.isEmpty || newTitle == "Page \(number)" ? "" : newTitle
        }
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
    @Relationship(deleteRule: .cascade, inverse: \AskThread.pdf)
    var askThreads: [AskThread]? = []

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

/// An image on a notebook page. It sits under the ink, so you can write on it.
@Model
final class CanvasImage {
    var id: UUID = UUID()
    /// Frame in canvas points.
    var x: Double = 0
    var y: Double = 0
    var width: Double = 300
    var height: Double = 200
    /// A locked image can't be moved, resized or deleted until it's unlocked.
    var isLocked: Bool = false
    /// Stacking order on the page. Higher is on top.
    var zIndex: Int = 0
    var createdAt: Date = Date.now
    /// JPEG (or PNG when it has transparency), at most 2048 pixels on its longest side.
    @Attribute(.externalStorage) var imageData: Data? = nil
    var page: NotebookPage? = nil

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.origin.x
            y = newValue.origin.y
            width = newValue.size.width
            height = newValue.size.height
        }
    }

    init(id: UUID = UUID(), frame: CGRect, imageData: Data?) {
        self.id = id
        self.x = frame.origin.x
        self.y = frame.origin.y
        self.width = frame.size.width
        self.height = frame.size.height
        self.imageData = imageData
    }
}

/// A saved "circle to ask" chat, shown as a marker where you circled.
@Model
final class AskThread {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    /// Where the marker sits: canvas points on a notebook page, or page
    /// points with a top-left origin on a PDF page.
    var anchorX: Double = 0
    var anchorY: Double = 0
    /// The PDF page, for chats on a PDF.
    var pageIndex: Int? = nil
    /// The circled area, as JPEG.
    @Attribute(.externalStorage) var imageData: Data? = nil
    /// What the panel shows: a JSON array of `{role, text}`.
    var transcriptData: Data? = nil
    /// The API conversation exactly as sent and received, so the chat can go on.
    @Attribute(.externalStorage) var historyData: Data? = nil
    var notebookPage: NotebookPage? = nil
    var pdf: PDFItem? = nil

    var anchor: CGPoint { CGPoint(x: anchorX, y: anchorY) }
    var hasAnswer: Bool { transcriptData != nil }

    init(anchor: CGPoint, pageIndex: Int? = nil, imageData: Data?) {
        self.anchorX = anchor.x
        self.anchorY = anchor.y
        self.pageIndex = pageIndex
        self.imageData = imageData
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

/// Everything needed to bring back a deleted canvas image.
struct CanvasImageSnapshot: Sendable {
    let id: UUID
    let frame: CGRect
    let isLocked: Bool
    let zIndex: Int
    let createdAt: Date
    let imageData: Data?

    init(_ image: CanvasImage) {
        id = image.id
        frame = image.frame
        isLocked = image.isLocked
        zIndex = image.zIndex
        createdAt = image.createdAt
        imageData = image.imageData
    }

    func makeModel() -> CanvasImage {
        let image = CanvasImage(id: id, frame: frame, imageData: imageData)
        image.isLocked = isLocked
        image.zIndex = zIndex
        image.createdAt = createdAt
        return image
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
