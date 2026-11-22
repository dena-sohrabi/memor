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
    /// A part of the page you circled in voice mode, for the study pal to
    /// talk about.
    var voiceQuestion: VoiceQuestion?
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
        if on, isAskMode { setAskMode(false) }
        isTextMode = on
        controller?.applyTextMode(on)
    }

    func setAskMode(_ on: Bool) {
        if on, isTextMode { setTextMode(false) }
        isAskMode = on
        controller?.setAskMode(on)
    }

    /// Opens a chat in the side panel: a new one for an area just circled
    /// (it asks Claude right away), or a saved one from its marker.
    func openAskThread(_ thread: AskThread) {
        setAskMode(false)
        // In voice mode, a new circled question goes to the study pal to talk
        // about, and keeps no marker. (A saved chat reopens in the panel.)
        if !thread.hasAnswer, StudyPalSpeaker.isVoiceMode {
            controller?.askAnchor = thread.anchor
            voiceQuestion = VoiceQuestion(text: "Here's the part of my page I circled. Can you help me with it?", image: thread.imageData)
            controller?.deleteAskThread(thread.id)
            return
        }
        askSession?.cancel()
        let session = AskSession(thread: thread, surface: .notebook)
        configure(session, anchor: thread.anchor)
        askSession = session
        if !thread.hasAnswer {
            session.pageContext = controller?.askPageContext()
            session.start()
        }
    }

    /// What the study pal can do on this page in voice mode.
    func voiceActions() -> AskPageActions? { controller }

    /// A picture of the page and its typed notes, for voice mode.
    func voicePageContext() -> PageContext? { controller?.askPageContext() }

    /// A question about the page from the compose box, typed or dictated,
    /// with nothing circled: Claude answers in the chat panel.
    func startCompose(_ question: String) {
        setAskMode(false)
        askSession?.cancel()
        let session = AskSession(image: nil, thread: nil, surface: .notebook)
        configure(session, anchor: nil)
        session.pageContext = controller?.askPageContext()
        askSession = session
        session.ask(question)
    }

    /// Lets Claude work on this page: what it adds goes beside the circled
    /// area, or in view when nothing was circled.
    private func configure(_ session: AskSession, anchor: CGPoint?) {
        session.actions = controller
        controller?.askAnchor = anchor
        session.onSaved = { [weak self] in self?.controller?.saveAskThreads() }
    }

    func closeAsk() {
        askSession?.cancel()
        // A circled chat that never got an answer isn't worth keeping.
        if let thread = askSession?.thread, !thread.hasAnswer {
            controller?.deleteAskThread(thread.id)
        }
        askSession = nil
        setAskMode(false)
    }

    /// Closes the panel if its chat was deleted from the marker.
    func askThreadDeleted(_ id: UUID) {
        guard askSession?.thread?.id == id else { return }
        askSession?.cancel()
        askSession = nil
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
        .overlay(alignment: editor.zoomCorner) {
            if index != nil {
                ZoomControl(editor: editor)
                    .padding(16)
            }
        }
        .overlay {
            AskOverlay(
                session: editor.askSession,
                isAskMode: editor.isAskMode,
                showsPal: index != nil,
                voiceQuestion: editor.voiceQuestion,
                pageActions: { editor.voiceActions() },
                pageContext: { editor.voicePageContext() },
                onSummon: { askClaude() },
                onSend: { editor.startCompose($0) },
                onCancelCompose: { editor.setAskMode(false) },
                onClose: { withAnimation(.snappy) { editor.closeAsk() } }
            )
        }
        .animation(.snappy, value: editor.askSession?.id)
        .animation(.snappy, value: editor.isAskMode)
        .sheet(isPresented: $showsKeySettings) {
            SettingsView { editor.setAskMode(true) }
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
                    if on { askClaude() } else { editor.setAskMode(false) }
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

    /// Turns on Ask Claude, from the toolbar or the study pal. Without an
    /// API key, asks for one first.
    private func askClaude() {
        if APIKeyStore.hasKey {
            editor.setAskMode(true)
        } else {
            showsKeySettings = true
        }
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
        controller.showsToolPicker = !editor.hidesChrome
        controller.onToggleChrome = { [weak editor] in
            withAnimation(.snappy) { editor?.toggleChrome() }
        }
        controller.onZoomChanged = { [weak editor] zoom in editor?.zoomScale = zoom }
        controller.onToolPickerFrame = { [weak editor] frame in editor?.toolPickerFrame = frame }
        controller.onOpenAskThread = { [weak editor] thread in editor?.openAskThread(thread) }
        controller.onDeleteAskThread = { [weak editor] id in editor?.askThreadDeleted(id) }
        editor.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: NotebookCanvasController, context: Context) {}

    static func dismantleUIViewController(_ controller: NotebookCanvasController, coordinator: ()) {
        controller.tearDown()
    }
}
