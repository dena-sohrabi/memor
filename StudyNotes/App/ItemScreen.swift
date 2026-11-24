import SwiftData
import SwiftUI

/// A notebook or PDF, opened from the library in the same window. Back
/// returns to the library.
struct ItemScreen: View {
    let target: OpenTarget

    var body: some View {
        switch target {
        case .notebook(let id):
            NotebookItemContent(id: id)
        case .pdf(let id):
            PDFItemContent(id: id)
        }
    }
}

private struct NotebookItemContent: View {
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

private struct PDFItemContent: View {
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

/// Shown when the open notebook or PDF was deleted.
struct DeletedItemView: View {
    let kind: String

    var body: some View {
        ContentUnavailableView {
            Label("This \(kind) was deleted", systemImage: "trash")
        } actions: {
            Button("Back to Library") { AppNavigator.shared.showLibrary() }
        }
    }
}

/// Goes straight back to the library, from a notebook's page.
struct LibraryButton: View {
    var body: some View {
        Button {
            AppNavigator.shared.showLibrary()
        } label: {
            Label("Library", systemImage: "square.grid.2x2")
        }
    }
}
