import SwiftData
import SwiftUI

/// The first screen of a notebook window: its pages in a grid, like the
/// library. Tapping a page opens it in `NotebookPageScreen`.
struct NotebookScreen: View {
    @Bindable var notebook: Notebook
    @Environment(\.modelContext) private var modelContext
    @State private var openedPage: NotebookPage?
    @State private var renamingPage: NotebookPage?
    @State private var pageTitle = ""
    @State private var pageToDelete: NotebookPage?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 20, alignment: .top)]

    var body: some View {
        let pages = notebook.sortedPages
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    Button { open(page) } label: {
                        NotebookPageCard(page: page, number: index + 1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: page, at: index, of: pages) }
                    .draggable(page.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                        return movePage(id: id, to: page)
                    }
                }
                AddTile(title: "New page", systemImage: "plus", aspectRatio: 4 / 3) {
                    addPage()
                }
            }
            .padding(24)
        }
        .navigationTitle($notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                LibraryButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { addPage() } label: {
                    Label("New page", systemImage: "plus")
                }
            }
        }
        .navigationDestination(item: $openedPage) { page in
            NotebookPageScreen(notebook: notebook, page: page)
        }
        .onAppear {
            notebook.lastOpenedAt = .now
            if notebook.sortedPages.isEmpty {
                notebook.ensureFirstPage(in: modelContext)
                try? modelContext.save()
            }
        }
        .alert("Rename page", isPresented: isPresent($renamingPage), presenting: renamingPage) { page in
            TextField("Page name", text: $pageTitle)
            Button("Rename") { rename(page) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Leave it empty to use the page number.")
        }
        .alert("Delete this page?", isPresented: isPresent($pageToDelete), presenting: pageToDelete) { page in
            Button("Delete", role: .destructive) { delete(page) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its ink and text will be deleted. This can't be undone.")
        }
    }

    @ViewBuilder
    private func menu(for page: NotebookPage, at index: Int, of pages: [NotebookPage]) -> some View {
        Button { open(page) } label: {
            Label("Open", systemImage: "arrow.up.forward.square")
        }
        Button {
            pageTitle = page.title
            renamingPage = page
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button { movePage(page, by: -1) } label: {
            Label("Move Earlier", systemImage: "arrow.left")
        }
        .disabled(index == 0)
        Button { movePage(page, by: 1) } label: {
            Label("Move Later", systemImage: "arrow.right")
        }
        .disabled(index == pages.count - 1)
        Divider()
        Button(role: .destructive) { pageToDelete = page } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(pages.count == 1)
    }

    // MARK: Actions

    private func open(_ page: NotebookPage) {
        notebook.currentPageID = page.id
        openedPage = page
    }

    /// Adds a page at the end and opens it.
    private func addPage() {
        let page = notebook.addPage(after: nil, in: modelContext)
        Thumbnails.writeBlankNotebookThumbnail(id: page.id)
        try? modelContext.save()
        open(page)
    }

    private func rename(_ page: NotebookPage) {
        page.title = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        try? modelContext.save()
    }

    private func movePage(_ page: NotebookPage, by offset: Int) {
        var ordered = notebook.sortedPages
        guard let index = ordered.firstIndex(where: { $0.id == page.id }),
              ordered.indices.contains(index + offset) else { return }
        ordered.swapAt(index, index + offset)
        notebook.applyPageOrder(ordered)
        try? modelContext.save()
    }

    /// Drag and drop: the dragged page takes the target's place.
    private func movePage(id: UUID, to target: NotebookPage) -> Bool {
        var ordered = notebook.sortedPages
        guard id != target.id,
              let from = ordered.firstIndex(where: { $0.id == id }),
              let to = ordered.firstIndex(where: { $0.id == target.id }) else { return false }
        let page = ordered.remove(at: from)
        ordered.insert(page, at: to)
        withAnimation(.snappy) { notebook.applyPageOrder(ordered) }
        try? modelContext.save()
        return true
    }

    private func delete(_ page: NotebookPage) {
        let pages = notebook.sortedPages
        guard pages.count > 1 else { return }
        if notebook.currentPageID == page.id { notebook.currentPageID = nil }
        FileStore.removeItem(at: FileStore.thumbnailURL(for: page.id))
        modelContext.delete(page)
        notebook.applyPageOrder(pages.filter { $0.id != page.id })
        try? modelContext.save()
    }

    private func isPresent<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

private struct NotebookPageCard: View {
    let page: NotebookPage
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    ThumbnailView(id: page.id, version: page.modifiedAt, placeholderSymbol: "scribble")
                }
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5)
                }
            Text(page.displayTitle(number: number))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text("Edited \(page.modifiedAt, format: .relative(presentation: .named))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .hoverEffect(.highlight)
    }
}
