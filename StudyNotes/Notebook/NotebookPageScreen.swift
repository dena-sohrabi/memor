import PencilKit
import PhotosUI
import SwiftData
import SwiftUI

/// Connects the SwiftUI toolbar to the UIKit canvas of the page on screen.
@MainActor
@Observable
final class NotebookEditor {
    var isTextMode = false
    /// Shared by every page, so the chosen pen stays when you switch pages.
    let toolPicker = PKToolPicker()
    @ObservationIgnored weak var controller: NotebookCanvasController?

    func setTextMode(_ on: Bool) {
        isTextMode = on
        controller?.applyTextMode(on)
    }

    func undo() { controller?.undo() }
    func redo() { controller?.redo() }
    func addImage(_ data: Data) { controller?.addImage(data: data) }
    func saveNow() { controller?.saveNow() }
    /// Saves the page on screen before another page replaces it.
    func leaveCurrentPage() { controller?.prepareToLeave() }
}

/// One notebook page, full screen. The back button returns to the grid of
/// pages. New Page adds a page right after this one and switches to it.
struct NotebookPageScreen: View {
    let notebook: Notebook
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var editor = NotebookEditor()
    @State private var pageID: UUID
    @State private var photoItem: PhotosPickerItem?

    init(notebook: Notebook, page: NotebookPage) {
        self.notebook = notebook
        _pageID = State(initialValue: page.id)
    }

    var body: some View {
        let pages = notebook.sortedPages
        let index = pages.firstIndex { $0.id == pageID }
        Group {
            if let index {
                NotebookCanvasRepresentable(page: pages[index], editor: editor, modelContext: modelContext)
                    .id(pages[index].id)
            } else {
                Color(uiColor: Paper.color)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(index.map { pages[$0].displayTitle(number: $0 + 1) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                LibraryButton()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { addPage(after: index.map { pages[$0] }) } label: {
                    Label("New page", systemImage: "doc.badge.plus")
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Add Image", systemImage: "photo")
                }
                Toggle(isOn: Binding(get: { editor.isTextMode }, set: { editor.setTextMode($0) })) {
                    Label("Text", systemImage: "character.textbox")
                }
                .toggleStyle(.button)
                Button { editor.undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                Button { editor.redo() } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { editor.saveNow() }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    editor.addImage(data)
                }
                photoItem = nil
            }
        }
        .onDisappear { editor.saveNow() }
    }

    private func addPage(after page: NotebookPage?) {
        editor.leaveCurrentPage()
        let newPage = notebook.addPage(after: page, in: modelContext)
        Thumbnails.writeBlankNotebookThumbnail(id: newPage.id)
        notebook.currentPageID = newPage.id
        pageID = newPage.id
        try? modelContext.save()
    }
}

private struct NotebookCanvasRepresentable: UIViewControllerRepresentable {
    let page: NotebookPage
    let editor: NotebookEditor
    let modelContext: ModelContext

    func makeUIViewController(context: Context) -> NotebookCanvasController {
        let controller = NotebookCanvasController(
            page: page,
            modelContext: modelContext,
            toolPicker: editor.toolPicker,
            isTextMode: editor.isTextMode
        )
        controller.onTextModeEnded = { [weak editor] in editor?.isTextMode = false }
        editor.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: NotebookCanvasController, context: Context) {}

    static func dismantleUIViewController(_ controller: NotebookCanvasController, coordinator: ()) {
        controller.tearDown()
    }
}
