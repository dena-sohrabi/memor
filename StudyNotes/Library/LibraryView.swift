import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The first screen: notebooks on top, PDFs below, each opening in its own window.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    @Query(sort: \Notebook.modifiedAt, order: .reverse) private var notebooks: [Notebook]
    @Query(sort: \PDFItem.lastOpenedAt, order: .reverse) private var pdfs: [PDFItem]

    @State private var showsImporter = false
    @State private var importMessage: String?
    @State private var isDropTargeted = false
    @State private var renameTarget: LibraryItem?
    @State private var renameText = ""
    @State private var deleteTarget: LibraryItem?
    @State private var showsKeySettings = false

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 20, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    section("Notebooks") {
                        ForEach(notebooks) { notebook in
                            Button { open(.notebook(notebook.id)) } label: {
                                NotebookCard(notebook: notebook)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: .notebook(notebook)) }
                        }
                        AddTile(title: "New notebook", systemImage: "plus", aspectRatio: 4 / 3) {
                            createNotebook()
                        }
                    }

                    section("PDFs") {
                        ForEach(pdfs) { pdf in
                            Button { open(.pdf(pdf.id)) } label: {
                                PDFCard(pdf: pdf)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: .pdf(pdf)) }
                        }
                        AddTile(title: "Import PDF", systemImage: "square.and.arrow.down", aspectRatio: 3 / 4) {
                            showsImporter = true
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Memor")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showsKeySettings = true } label: {
                        Label("Ask Claude Settings", systemImage: "sparkles")
                    }
                    Button { showsImporter = true } label: {
                        Label("Import PDF", systemImage: "square.and.arrow.down")
                    }
                    Button { createNotebook() } label: {
                        Label("New notebook", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showsKeySettings) {
                APIKeySettingsView()
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                importPDFs(urls, openAfterImport: false)
            case .failure(let error):
                importMessage = error.localizedDescription
            }
        }
        .dropDestination(for: PDFDrop.self) { drops, _ in
            importPDFs(drops.map(\.url), openAfterImport: false, removeSourcesAfterImport: true)
            return !drops.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // "Open in Memor" from Files, Mail or Safari. The system hands
        // over a copy in the Inbox folder, which is removed after importing.
        .onOpenURL { url in
            importPDFs([url], openAfterImport: true, removeSourcesAfterImport: url.pathComponents.contains("Inbox"))
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .alert("Rename", isPresented: isRenaming, presenting: renameTarget) { item in
            TextField("Name", text: $renameText)
            Button("Save") { rename(item, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deleteTarget?.title ?? "")”?",
            isPresented: isDeleting,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { item in
            Button("Delete", role: .destructive) { delete(item) }
        } message: { _ in
            Text("This can't be undone.")
        }
        .alert("Couldn't import", isPresented: showsImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    // MARK: Layout

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.bold())
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                content()
            }
        }
    }

    @ViewBuilder
    private func menu(for item: LibraryItem) -> some View {
        Button { open(item.target) } label: {
            Label("Open", systemImage: "macwindow.badge.plus")
        }
        Button {
            renameText = item.title
            renameTarget = item
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button(role: .destructive) { deleteTarget = item } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Actions

    private func open(_ target: OpenTarget) {
        openWindow(id: WindowID.item, value: target)
    }

    private func createNotebook() {
        let notebook = Notebook()
        modelContext.insert(notebook)
        let firstPage = notebook.ensureFirstPage(in: modelContext)
        Thumbnails.writeBlankNotebookThumbnail(id: firstPage.id)
        try? modelContext.save()
        open(.notebook(notebook.id))
    }

    private func importPDFs(_ urls: [URL], openAfterImport: Bool, removeSourcesAfterImport: Bool = false) {
        Task {
            var failedNames: [String] = []
            for url in urls {
                do {
                    let imported = try await Task.detached { try PDFImporter.importFile(at: url) }.value
                    let item = PDFItem(id: imported.id, title: imported.title, fileName: imported.fileName, pageCount: imported.pageCount)
                    modelContext.insert(item)
                    try? modelContext.save()
                    if openAfterImport { open(.pdf(item.id)) }
                } catch {
                    failedNames.append(url.lastPathComponent)
                }
                if removeSourcesAfterImport { FileStore.removeItem(at: url) }
            }
            if !failedNames.isEmpty {
                importMessage = "\(failedNames.formatted()) couldn't be read as a PDF."
            }
        }
    }

    private func rename(_ item: LibraryItem, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        switch item {
        case .notebook(let notebook): notebook.title = title
        case .pdf(let pdf): pdf.title = title
        }
        try? modelContext.save()
    }

    private func delete(_ item: LibraryItem) {
        switch item {
        case .notebook(let notebook):
            FileStore.removeItem(at: FileStore.thumbnailURL(for: notebook.id))
            for page in notebook.pages ?? [] {
                FileStore.removeItem(at: FileStore.thumbnailURL(for: page.id))
            }
            modelContext.delete(notebook)
        case .pdf(let pdf):
            FileStore.removeItem(at: FileStore.pdfURL(fileName: pdf.fileName))
            FileStore.removeItem(at: FileStore.thumbnailURL(for: pdf.id))
            modelContext.delete(pdf)
        }
        try? modelContext.save()
    }

    // MARK: Bindings

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var showsImportMessage: Binding<Bool> {
        Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })
    }
}

enum LibraryItem {
    case notebook(Notebook)
    case pdf(PDFItem)

    var title: String {
        switch self {
        case .notebook(let notebook): notebook.title
        case .pdf(let pdf): pdf.title
        }
    }

    var target: OpenTarget {
        switch self {
        case .notebook(let notebook): .notebook(notebook.id)
        case .pdf(let pdf): .pdf(pdf.id)
        }
    }
}

/// A PDF dropped onto the library. The file is copied out of the drop
/// session right away, because the system deletes the original afterwards.
struct PDFDrop: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .pdf) { received in
            let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PDFDrop(url: copy)
        }
    }
}
