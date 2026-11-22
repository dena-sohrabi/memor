import SwiftData
import SwiftUI

/// The root of every notebook or PDF window. The study pal sits on top
/// while this is the window you're using.
struct ItemWindow: View {
    let target: OpenTarget?

    var body: some View {
        NavigationStack {
            switch target {
            case .notebook(let id):
                NotebookWindowContent(id: id)
            case .pdf(let id):
                PDFWindowContent(id: id)
            case nil:
                DeletedItemView(kind: "item")
            }
        }
        .overlay { PalOverlay() }
    }
}

private struct NotebookWindowContent: View {
    @Query private var matches: [Notebook]

    init(id: UUID) {
        _matches = Query(filter: #Predicate<Notebook> { $0.id == id })
    }

    var body: some View {
        if let notebook = matches.first {
            NotebookScreen(notebook: notebook)
        } else {
            DeletedItemView(kind: "notebook")
        }
    }
}

private struct PDFWindowContent: View {
    @Query private var matches: [PDFItem]

    init(id: UUID) {
        _matches = Query(filter: #Predicate<PDFItem> { $0.id == id })
    }

    var body: some View {
        if let item = matches.first {
            PDFReaderScreen(item: item)
        } else {
            DeletedItemView(kind: "PDF")
        }
    }
}

/// Shown when the item of an open window was deleted from the library.
struct DeletedItemView: View {
    let kind: String
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ContentUnavailableView {
            Label("This \(kind) was deleted", systemImage: "trash")
        } description: {
            Text("You can close this window.")
        } actions: {
            Button("Close window") { dismissWindow() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { LibraryButton() }
        }
    }
}

/// Brings the library window to the front, or reopens it if it was closed.
struct LibraryButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: WindowID.library, value: LibraryWindow.main)
        } label: {
            Label("Library", systemImage: "square.grid.2x2")
        }
    }
}
