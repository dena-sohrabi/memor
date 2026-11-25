import SwiftData
import SwiftUI

/// A notebook or PDF, on one side of a tab.
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
    let id: UUID
    @Query private var matches: [Notebook]

    init(id: UUID) {
        self.id = id
        _matches = Query(filter: #Predicate<Notebook> { $0.id == id })
    }

    var body: some View {
        if let notebook = matches.first {
            NotebookScreen(notebook: notebook)
        } else {
            DeletedItemView(kind: "notebook", target: .notebook(id))
        }
    }
}

private struct PDFItemContent: View {
    let id: UUID
    @Query private var matches: [PDFItem]

    init(id: UUID) {
        self.id = id
        _matches = Query(filter: #Predicate<PDFItem> { $0.id == id })
    }

    var body: some View {
        if let item = matches.first {
            PDFReaderScreen(item: item)
        } else {
            DeletedItemView(kind: "PDF", target: .pdf(id))
        }
    }
}

/// Shown when an open notebook or PDF was deleted (on another iPad, say).
struct DeletedItemView: View {
    let kind: String
    let target: OpenTarget
    @Environment(\.workspace) private var workspace

    var body: some View {
        ContentUnavailableView {
            Label("This \(kind) was deleted", systemImage: "trash")
        } actions: {
            Button("Close") { workspace?.remove(target) }
        }
    }
}
