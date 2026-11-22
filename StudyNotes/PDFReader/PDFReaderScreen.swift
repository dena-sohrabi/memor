import PDFKit
import SwiftData
import SwiftUI
import UIKit

enum PDFTool: String, CaseIterable, Identifiable {
    case select, highlight, ink, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .highlight: "Highlight"
        case .ink: "Ink"
        case .text: "Text"
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .ink: "pencil.tip"
        case .text: "character.textbox"
        }
    }
}

extension HighlightColor {
    /// Translucent color the highlight is drawn with.
    var uiColor: UIColor {
        switch self {
        case .yellow: UIColor(red: 1.00, green: 0.82, blue: 0.10, alpha: 0.40)
        case .green: UIColor(red: 0.25, green: 0.85, blue: 0.45, alpha: 0.35)
        case .blue: UIColor(red: 0.30, green: 0.62, blue: 1.00, alpha: 0.35)
        case .pink: UIColor(red: 1.00, green: 0.40, blue: 0.65, alpha: 0.35)
        }
    }

    var swatchColor: Color { Color(uiColor: uiColor.withAlphaComponent(1)) }

    var swatchImage: UIImage? {
        UIImage(systemName: "circle.fill")?.withTintColor(uiColor.withAlphaComponent(1), renderingMode: .alwaysOriginal)
    }
}

/// Connects the SwiftUI toolbar to the UIKit reader.
@MainActor
@Observable
final class PDFEditor {
    var tool: PDFTool = .select
    var highlightColor: HighlightColor = .yellow
    var currentPageIndex = 0
    var pageCount = 0
    var showsPageSidebar = false
    /// Circle-to-ask: the Ask tool is on, and the conversation in the side panel.
    var isAskMode = false
    var askSession: AskSession?
    /// A part of the page you circled in voice mode, for the study pal to
    /// talk about.
    var voiceQuestion: VoiceQuestion?
    @ObservationIgnored weak var controller: PDFReaderController?

    func setAskMode(_ on: Bool) {
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
            controller?.askPageIndex = thread.pageIndex
            controller?.askAnchor = thread.anchor
            voiceQuestion = VoiceQuestion(text: "Here's the part of my page I circled. Can you help me with it?", image: thread.imageData)
            controller?.deleteAskThread(thread.id)
            return
        }
        askSession?.cancel()
        let session = AskSession(thread: thread, surface: .pdf)
        configure(session, pageIndex: thread.pageIndex, anchor: thread.anchor)
        askSession = session
        if !thread.hasAnswer {
            session.pageContext = controller?.askPageContext(pageIndex: thread.pageIndex)
            session.start()
        }
    }

    /// What the study pal can do in voice mode: on the page you're reading.
    func voiceActions() -> AskPageActions? {
        controller?.askPageIndex = currentPageIndex
        return controller
    }

    /// A picture of the page you're reading and its notes, for voice mode.
    func voicePageContext() -> PageContext? { controller?.askPageContext(pageIndex: currentPageIndex) }

    /// A question about the current page from the compose box, typed or
    /// dictated, with nothing circled: Claude answers in the chat panel.
    func startCompose(_ question: String) {
        setAskMode(false)
        askSession?.cancel()
        let session = AskSession(image: nil, thread: nil, surface: .pdf)
        let pageIndex = currentPageIndex
        configure(session, pageIndex: pageIndex, anchor: nil)
        session.pageContext = controller?.askPageContext(pageIndex: pageIndex)
        askSession = session
        session.ask(question)
    }

    /// Lets Claude work on the chat's page: new notes go beside the
    /// circled area, or near the top of the page.
    private func configure(_ session: AskSession, pageIndex: Int?, anchor: CGPoint?) {
        session.actions = controller
        controller?.askPageIndex = pageIndex
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
    func saveNow() { controller?.saveNow() }
    func goToPage(_ index: Int) { controller?.goToPage(index) }
}

struct PDFReaderScreen: View {
    @Bindable var item: PDFItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var editor = PDFEditor()

    @State private var document: PDFDocument?
    @State private var lockedDocument: PDFDocument?
    @State private var loadFailed = false
    @State private var asksForPassword = false
    @State private var passwordWasWrong = false
    @State private var password = ""
    @State private var asksForPage = false
    @State private var pageText = ""
    @State private var showsKeySettings = false

    var body: some View {
        content
            .overlay {
                AskOverlay(
                    session: editor.askSession,
                    isAskMode: editor.isAskMode,
                    showsPal: document != nil,
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
            .navigationTitle($item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar { toolbarContent }
            .task { loadDocument() }
            .onChange(of: editor.tool) { _, tool in
                editor.controller?.apply(tool: tool)
            }
            .onChange(of: editor.showsPageSidebar) { _, shows in
                editor.controller?.setPageSidebarVisible(shows)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { editor.saveNow() }
            }
            .onDisappear { editor.saveNow() }
            .alert(passwordWasWrong ? "Wrong password" : "This PDF is locked", isPresented: $asksForPassword) {
                SecureField("Password", text: $password)
                Button("Unlock") { unlock() }
                Button("Cancel", role: .cancel) { password = "" }
            } message: {
                Text("Enter the password for “\(item.title)”.")
            }
            .alert("Go to page", isPresented: $asksForPage) {
                TextField("Page", text: $pageText)
                    .keyboardType(.numberPad)
                Button("Go") {
                    if let page = Int(pageText) { editor.goToPage(page - 1) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a page from 1 to \(editor.pageCount).")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let document {
            PDFReaderRepresentable(document: document, item: item, editor: editor, modelContext: modelContext)
                .ignoresSafeArea(.container, edges: .bottom)
        } else if loadFailed {
            ContentUnavailableView(
                "Couldn't open this PDF",
                systemImage: "exclamationmark.triangle",
                description: Text("The file may be damaged or missing.")
            )
        } else if lockedDocument != nil {
            ContentUnavailableView {
                Label("This PDF is locked", systemImage: "lock")
            } description: {
                Text("Enter its password to open it.")
            } actions: {
                Button("Enter password") { asksForPassword = true }
            }
        } else {
            ProgressView()
        }
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            LibraryButton()
            Button { editor.showsPageSidebar.toggle() } label: {
                Label("Pages", systemImage: "sidebar.left")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if editor.pageCount > 0 {
                Button {
                    pageText = ""
                    asksForPage = true
                } label: {
                    Text("\(editor.currentPageIndex + 1) / \(editor.pageCount)")
                        .monospacedDigit()
                }
            }
            Picker("Tool", selection: $editor.tool) {
                ForEach(PDFTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if editor.tool == .highlight {
                ForEach(HighlightColor.allCases) { color in
                    Button { editor.highlightColor = color } label: {
                        Label(color.title, systemImage: editor.highlightColor == color ? "largecircle.fill.circle" : "circle.fill")
                    }
                    .tint(color.swatchColor)
                }
            }
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

    private func loadDocument() {
        guard document == nil, lockedDocument == nil, !loadFailed else { return }
        item.lastOpenedAt = .now
        guard let loaded = PDFDocument(url: FileStore.pdfURL(fileName: item.fileName)) else {
            loadFailed = true
            return
        }
        if loaded.isLocked {
            lockedDocument = loaded
            asksForPassword = true
        } else {
            document = loaded
        }
    }

    private func unlock() {
        defer { password = "" }
        guard let lockedDocument else { return }
        if lockedDocument.unlock(withPassword: password) {
            if item.pageCount == 0 { item.pageCount = lockedDocument.pageCount }
            passwordWasWrong = false
            document = lockedDocument
            self.lockedDocument = nil
        } else {
            passwordWasWrong = true
            Task { asksForPassword = true }
        }
    }
}

private struct PDFReaderRepresentable: UIViewControllerRepresentable {
    let document: PDFDocument
    let item: PDFItem
    let editor: PDFEditor
    let modelContext: ModelContext

    func makeUIViewController(context: Context) -> PDFReaderController {
        let controller = PDFReaderController(document: document, item: item, editor: editor, modelContext: modelContext)
        controller.onOpenAskThread = { [weak editor] thread in editor?.openAskThread(thread) }
        controller.onDeleteAskThread = { [weak editor] id in editor?.askThreadDeleted(id) }
        editor.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: PDFReaderController, context: Context) {}
}
