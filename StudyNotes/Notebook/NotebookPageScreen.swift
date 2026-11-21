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

    /// Circle-to-ask: the Ask tool is on, and the conversation in the side panel.
    var isAskMode = false
    var askSession: AskSession?

    func setTextMode(_ on: Bool) {
        if on, isAskMode { setAskMode(false) }
        isTextMode = on
        controller?.applyTextMode(on)
    }

    func setAskMode(_ on: Bool) {
        if on, isTextMode { setTextMode(false) }
        isAskMode = on
        controller?.setAskMode(on)
    }

    /// Opens the side panel and asks Claude about the circled area.
    func didCircle(_ image: UIImage) {
        isAskMode = false
        askSession?.cancel()
        let session = AskSession(image: image)
        askSession = session
        session.start()
    }

    func closeAsk() {
        askSession?.cancel()
        askSession = nil
        setAskMode(false)
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
    /// Hides the top toolbar so the page fills the window.
    @State private var hidesToolbar = false
    @State private var showsKeySettings = false

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
        .overlay(alignment: .topTrailing) {
            if hidesToolbar {
                Button {
                    withAnimation(.snappy) { hidesToolbar = false }
                } label: {
                    Label("Show Toolbar", systemImage: "arrow.down.right.and.arrow.up.left")
                        .labelStyle(.iconOnly)
                        .padding(4)
                }
                .buttonStyle(.glass)
                .padding(.top, 12)
                .padding(.trailing, 16)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .trailing) {
            if let session = editor.askSession {
                AskPanel(session: session) {
                    withAnimation(.snappy) { editor.closeAsk() }
                }
                .padding(.vertical, 12)
                .padding(.trailing, 12)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: editor.askSession?.id)
        .sheet(isPresented: $showsKeySettings) {
            APIKeySettingsView { editor.setAskMode(true) }
        }
        // Tap the title to rename the page.
        .navigationTitle(index.map { Bindable(pages[$0]).editableTitle } ?? .constant(""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar(hidesToolbar ? .hidden : .visible, for: .navigationBar)
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
                Toggle(isOn: Binding(get: { editor.isAskMode }, set: { on in
                    if on, !APIKeyStore.hasKey {
                        showsKeySettings = true
                    } else {
                        editor.setAskMode(on)
                    }
                })) {
                    Label("Ask Claude", systemImage: "sparkles")
                }
                .toggleStyle(.button)
                Button { editor.undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                Button { editor.redo() } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                Button {
                    withAnimation(.snappy) { hidesToolbar = true }
                } label: {
                    Label("Hide Toolbar", systemImage: "arrow.up.left.and.arrow.down.right")
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
        editor.setAskMode(false)
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
        controller.onAskSelection = { [weak editor] image in editor?.didCircle(image) }
        editor.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: NotebookCanvasController, context: Context) {}

    static func dismantleUIViewController(_ controller: NotebookCanvasController, coordinator: ()) {
        controller.tearDown()
    }
}
