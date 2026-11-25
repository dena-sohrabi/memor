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
    /// In a window with tabs, the window's palette is used instead (see
    /// `Workspace.toolPicker`).
    let toolPicker = PKToolPicker()
    @ObservationIgnored weak var controller: NotebookCanvasController?

    /// The toolbar and the pen palette are hidden, so the page fills the
    /// window. A tap on empty paper switches.
    var hidesChrome = false
    /// The page's zoom: 1 is 100%.
    var zoomScale: CGFloat = 1
    /// Where the pen palette covers the page (null when hidden).
    var toolPickerFrame = CGRect.null

    /// The zoom control sits at the top left, below the toolbar, unless the
    /// pen palette is there; then at the bottom left.
    var zoomCorner: Alignment {
        toolPickerFrame.intersects(CGRect(x: 0, y: 0, width: 220, height: 90)) ? .bottomLeading : .topLeading
    }

    func toggleChrome() {
        hidesChrome.toggle()
        controller?.setToolPickerVisible(!hidesChrome)
    }

    func zoomIn() { controller?.zoomIn() }
    func zoomOut() { controller?.zoomOut() }
    func zoom(to scale: CGFloat) { controller?.zoom(to: scale) }
    func zoomToFit() { controller?.zoomToFit() }

    func setTextMode(_ on: Bool) {
        if on, Pal.shared.isCircling { Pal.shared.stopCircling() }
        isTextMode = on
        controller?.applyTextMode(on)
    }

    /// Circle something on this page for the study pal.
    func setCircling(_ on: Bool) {
        if on {
            if isTextMode { setTextMode(false) }
            Pal.shared.startCircling(on: controller)
        } else {
            Pal.shared.stopCircling()
        }
    }

    func undo() { controller?.undo() }
    func redo() { controller?.redo() }
    func addImage(_ data: Data) { controller?.addImage(data: data) }
    func saveNow() { controller?.saveNow() }
    /// Saves the page on screen before another page replaces it.
    func leaveCurrentPage() { controller?.prepareToLeave() }
}

/// One notebook page, filling its side of the tab. The back button returns
/// to the grid of pages. New Page adds a page right after this one and
/// switches to it.
struct NotebookPageScreen: View {
    let notebook: Notebook
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workspace) private var workspace
    @Environment(\.paneSide) private var paneSide
    @State private var editor = NotebookEditor()
    @State private var pageID: UUID
    @State private var photoItem: PhotosPickerItem?
    @State private var showsKeySettings = false
    private var pal: Pal { .shared }

    init(notebook: Notebook, page: NotebookPage) {
        self.notebook = notebook
        _pageID = State(initialValue: page.id)
    }

    var body: some View {
        let pages = notebook.sortedPages
        let index = pages.firstIndex { $0.id == pageID }
        Group {
            if let index {
                NotebookCanvasRepresentable(
                    page: pages[index],
                    editor: editor,
                    modelContext: modelContext,
                    toolPicker: workspace?.toolPicker ?? editor.toolPicker,
                    isActivePane: workspace?.isActive(paneSide) ?? true,
                    onTouched: { [workspace, paneSide] in workspace?.activate(paneSide) }
                )
                .id(pages[index].id)
            } else {
                Color(uiColor: Paper.color)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: editor.zoomCorner) {
            if index != nil {
                ZoomControl(editor: editor)
                    .padding(16)
            }
        }
        .sheet(isPresented: $showsKeySettings) {
            SettingsView()
        }
        // Tap the title to rename the page.
        .navigationTitle(index.map { Bindable(pages[$0]).editableTitle } ?? .constant(""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar(editor.hidesChrome ? .hidden : .visible, for: .navigationBar)
        // Hidden means everything: the status bar and the home bar too.
        .statusBarHidden(editor.hidesChrome)
        .persistentSystemOverlays(editor.hidesChrome ? .hidden : .automatic)
        .toolbar {
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
                Toggle(isOn: Binding(get: { pal.isCircling }, set: { on in
                    if on, !pal.hasKey { showsKeySettings = true } else { editor.setCircling(on) }
                })) {
                    Label("Circle for Your Study Pal", systemImage: "lasso.badge.sparkles")
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
        // With its toolbars hidden, the tab bar hides too (when the other
        // side of the tab hid them as well).
        .onChange(of: editor.hidesChrome) { _, hidden in
            workspace?.setChromeHidden(hidden, on: paneSide)
        }
        // The study pal went to another page of this notebook.
        .onChange(of: PalNavigator.shared.request) { _, request in
            guard let request, request.itemID == notebook.id, let target = request.pageID,
                  notebook.sortedPages.contains(where: { $0.id == target }) else { return }
            PalNavigator.shared.done(request)
            guard target != pageID else { return }
            editor.leaveCurrentPage()
            notebook.currentPageID = target
            pageID = target
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
        .onDisappear {
            editor.saveNow()
            if editor.hidesChrome { workspace?.setChromeHidden(false, on: paneSide) }
        }
    }

    private func addPage(after page: NotebookPage?) {
        editor.setCircling(false)
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
    let toolPicker: PKToolPicker
    /// This page is on the side of the tab you're using.
    let isActivePane: Bool
    /// A finger or the Pencil touched the page.
    let onTouched: @MainActor () -> Void

    func makeUIViewController(context: Context) -> NotebookCanvasController {
        let controller = NotebookCanvasController(
            page: page,
            modelContext: modelContext,
            toolPicker: toolPicker,
            isTextMode: editor.isTextMode
        )
        controller.setInActivePane(isActivePane)
        controller.onTouched = onTouched
        controller.onTextModeEnded = { [weak editor] in editor?.isTextMode = false }
        controller.showsToolPicker = !editor.hidesChrome
        controller.onToggleChrome = { [weak editor] in
            withAnimation(.snappy) { editor?.toggleChrome() }
        }
        controller.onZoomChanged = { [weak editor] zoom in editor?.zoomScale = zoom }
        controller.onToolPickerFrame = { [weak editor] frame in editor?.toolPickerFrame = frame }
        editor.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: NotebookCanvasController, context: Context) {
        controller.onTouched = onTouched
        controller.setInActivePane(isActivePane)
    }

    static func dismantleUIViewController(_ controller: NotebookCanvasController, coordinator: ()) {
        controller.tearDown()
    }
}
