import PDFKit
import PencilKit
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
    @ObservationIgnored weak var controller: PDFReaderController?
    @ObservationIgnored private var pickerStorage: PKToolPicker?

    /// The pen palette, outside a window with tabs. In one, the window's
    /// palette is used (see `Workspace.toolPicker`).
    var toolPicker: PKToolPicker {
        if let pickerStorage { return pickerStorage }
        let picker = PKToolPicker()
        pickerStorage = picker
        return picker
    }

    /// Circle something on a page for the study pal.
    func setCircling(_ on: Bool) {
        if on {
            Pal.shared.startCircling(on: controller)
        } else {
            Pal.shared.stopCircling()
        }
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
    @Environment(\.workspace) private var workspace
    @Environment(\.paneSide) private var paneSide
    @State private var editor = PDFEditor()

    @State private var document: PDFDocument?
    @State private var lockedDocument: PDFDocument?
    @State private var loadFailed = false
    /// The file hasn't come from iCloud yet.
    @State private var fileIsMissing = false
    @State private var asksForPassword = false
    @State private var passwordWasWrong = false
    @State private var password = ""
    @State private var asksForPage = false
    @State private var pageText = ""
    @State private var showsKeySettings = false
    private var pal: Pal { .shared }

    var body: some View {
        content
            .sheet(isPresented: $showsKeySettings) {
                SettingsView()
            }
            .navigationTitle($item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar { toolbarContent }
            .task { await loadDocument() }
            .onChange(of: editor.tool) { _, tool in
                // Picking a tool uses this side of the tab.
                workspace?.activate(paneSide)
                editor.controller?.apply(tool: tool)
            }
            .onChange(of: editor.showsPageSidebar) { _, shows in
                editor.controller?.setPageSidebarVisible(shows)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { editor.saveNow() }
            }
            // The study pal went to a page of this PDF.
            .onChange(of: PalNavigator.shared.request) { _, request in
                guard let request, request.itemID == item.id, let index = request.pageIndex, editor.controller != nil else { return }
                PalNavigator.shared.done(request)
                editor.goToPage(index)
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
            PDFReaderRepresentable(
                document: document,
                item: item,
                editor: editor,
                modelContext: modelContext,
                toolPicker: workspace?.toolPicker ?? editor.toolPicker,
                isActivePane: workspace?.isActive(paneSide) ?? true,
                onTouched: { [workspace, paneSide] in workspace?.activate(paneSide) }
            )
            .ignoresSafeArea(.container, edges: .bottom)
        } else if fileIsMissing {
            ContentUnavailableView(
                "This PDF isn't on this iPad yet",
                systemImage: "icloud.and.arrow.down",
                description: Text("It comes through iCloud from the iPad it was imported on. Open Memor there, with iCloud on.")
            )
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
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

    private func loadDocument() async {
        guard document == nil, lockedDocument == nil, !loadFailed, !fileIsMissing else { return }
        item.lastOpenedAt = .now
        // On a new iPad the file is written from the database first.
        let id = item.id
        let fileName = item.fileName
        guard let url = await Task.detached(operation: { PDFFiles.localURL(id: id, fileName: fileName) }).value else {
            fileIsMissing = true
            return
        }
        guard document == nil, lockedDocument == nil else { return }
        guard let loaded = PDFDocument(url: url) else {
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
    let toolPicker: PKToolPicker
    /// This PDF is on the side of the tab you're using.
    let isActivePane: Bool
    /// A finger or the Pencil touched the PDF.
    let onTouched: @MainActor () -> Void

    func makeUIViewController(context: Context) -> PDFReaderController {
        let controller = PDFReaderController(document: document, item: item, editor: editor, modelContext: modelContext, toolPicker: toolPicker)
        controller.setInActivePane(isActivePane)
        controller.onTouched = onTouched
        editor.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: PDFReaderController, context: Context) {
        controller.onTouched = onTouched
        controller.setInActivePane(isActivePane)
    }

    static func dismantleUIViewController(_ controller: PDFReaderController, coordinator: ()) {
        controller.tearDown()
    }
}
