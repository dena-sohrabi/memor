import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The open tabs, across the top of the window. The grid button shows the
/// library. Tap a tab to go to it, or one side of a tab with two to use that
/// side. Touch and hold a tab for more: Open Beside, Swap Sides, Open in New
/// Window, Close. Or drag it: along the bar to move it, onto the tab on
/// screen to put it beside, or into another of Memor's windows.
struct TabStrip: View {
    let workspace: Workspace
    @Query private var notebooks: [Notebook]
    @Query private var pdfs: [PDFItem]

    var body: some View {
        let titles = ItemTitles(notebooks: notebooks, pdfs: pdfs)
        HStack(spacing: 8) {
            libraryButton
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(workspace.tabs) { tab in
                            TabChip(tab: tab, workspace: workspace, titles: titles)
                                .id(tab.id)
                        }
                    }
                    .padding(.vertical, 2)
                    // Room to drop a tab after the last one.
                    .padding(.trailing, 48)
                }
                .scrollIndicators(.hidden)
                .onChange(of: workspace.selectedTabID, initial: true) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy) { reader.scrollTo(id) }
                }
            }
            // Dropped past the last tab: it goes last.
            .onDrop(of: [.memorTab], delegate: StripDropDelegate(workspace: workspace, targetID: nil))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Clear of the window's controls, when windows float.
        .containerCornerOffset(.leading, sizeToFit: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar, ignoresSafeAreaEdges: .top)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var libraryButton: some View {
        let isSelected = workspace.selectedTabID == nil
        return Button {
            workspace.showLibrary()
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.body.weight(.medium))
                .frame(width: 40, height: 34)
                .background(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 10))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Library")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One tab in the bar: one title, or two with a line between.
private struct TabChip: View {
    let tab: WorkspaceTab
    let workspace: Workspace
    let titles: ItemTitles
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    private var isSelected: Bool { workspace.selectedTabID == tab.id }

    var body: some View {
        HStack(spacing: 2) {
            label(.left)
            if tab.isPair {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 18)
                label(.right)
            }
            closeButton
        }
        .padding(.leading, 3)
        .frame(height: 34)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)), in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
        .onTapGesture { select(nil) }
        .hoverEffect(.highlight)
        .contextMenu { menu }
        .onDrag {
            dragProvider()
        } preview: {
            preview
        }
        .onDrop(of: [.memorTab], delegate: StripDropDelegate(workspace: workspace, targetID: tab.id))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A title. In the tab on screen, tapping one side of two makes it the
    /// side you're using, which it shows.
    private func label(_ side: PaneSide) -> some View {
        let target = tab.target(on: side) ?? tab.left
        let isUsedSide = isSelected && tab.isPair && tab.activeSide == side
        return CappedWidth(maxWidth: tab.isPair ? 150 : 200) {
            HStack(spacing: 5) {
                Image(systemName: ItemTitles.symbol(target))
                    .font(.caption)
                Text(titles(target))
                    .lineLimit(1)
            }
        }
        .font(.subheadline.weight(isSelected ? .medium : .regular))
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background(isUsedSide ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 7))
        .contentShape(.rect)
        .onTapGesture { select(side) }
    }

    private var closeButton: some View {
        Button {
            withAnimation(.snappy) { workspace.closeTab(tab.id) }
        } label: {
            Image(systemName: "xmark")
                .font(.caption2.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Close tab")
    }

    @ViewBuilder
    private var menu: some View {
        if let right = tab.right {
            Button { workspace.swapSides(tab.id) } label: {
                Label("Swap Sides", systemImage: "arrow.left.arrow.right")
            }
            Button {
                withAnimation(.snappy) { workspace.separate(tab.id) }
            } label: {
                Label("Separate Into Two Tabs", systemImage: "square.on.square")
            }
            Button { workspace.closeSide(.left, ofTab: tab.id) } label: {
                Label("Close “\(titles(tab.left))”", systemImage: "rectangle.lefthalf.inset.filled")
            }
            Button { workspace.closeSide(.right, ofTab: tab.id) } label: {
                Label("Close “\(titles(right))”", systemImage: "rectangle.righthalf.inset.filled")
            }
        } else if let base = workspace.besideTab, base.id != tab.id {
            Button {
                withAnimation(.snappy) { workspace.openBeside(tab.left) }
            } label: {
                Label(titles.besideLabel(for: base), systemImage: "rectangle.split.2x1")
            }
        }
        if supportsMultipleWindows {
            Button {
                openWindow(value: workspace.newWindow(with: tab))
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
        Divider()
        Button {
            withAnimation(.snappy) { workspace.closeTab(tab.id) }
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    private func select(_ side: PaneSide?) {
        workspace.select(tab.id)
        workspace.activate(side)
    }

    /// The dragged tab. Only Memor can read it; drops look up the tab by
    /// `draggingTabID`, which is set now.
    private func dragProvider() -> NSItemProvider {
        WorkspaceRegistry.shared.draggingTabID = tab.id
        let id = tab.id.uuidString
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.memorTab.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.utf8), nil)
            return nil
        }
        provider.suggestedName = titles(tab.left)
        return provider
    }

    private var preview: some View {
        HStack(spacing: 8) {
            ForEach(tab.targets, id: \.self) { target in
                Label(titles(target), systemImage: ItemTitles.symbol(target))
                    .lineLimit(1)
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }
}

/// A tab dropped on the tab bar: onto a tab, it takes that tab's place
/// (moving the others along); past the last one, it goes last. From
/// another window, it moves into this one.
private struct StripDropDelegate: DropDelegate {
    let workspace: Workspace
    let targetID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.memorTab]) && WorkspaceRegistry.shared.draggingTabID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = WorkspaceRegistry.shared.draggingTabID else { return false }
        WorkspaceRegistry.shared.draggingTabID = nil
        withAnimation(.snappy) { workspace.moveTab(id, to: targetID) }
        return true
    }
}

/// The titles of notebooks and PDFs, for tabs and menus.
struct ItemTitles {
    private var titles: [UUID: String] = [:]

    init(notebooks: [Notebook], pdfs: [PDFItem]) {
        for notebook in notebooks { titles[notebook.id] = notebook.title }
        for pdf in pdfs { titles[pdf.id] = pdf.title }
    }

    func callAsFunction(_ target: OpenTarget) -> String {
        guard let title = titles[target.id] else { return "Deleted" }
        return title.isEmpty ? "Untitled" : title
    }

    static func symbol(_ target: OpenTarget) -> String {
        switch target {
        case .notebook: "book.closed"
        case .pdf: "doc.text"
        }
    }

    /// The menu item that opens something beside `base`: beside its one
    /// item, or in place of the side you aren't using.
    func besideLabel(for base: WorkspaceTab) -> String {
        if base.isPair, let replaced = base.target(on: base.activeSide.other) {
            return "Open in Place of “\(self(replaced))”"
        }
        return "Open Beside “\(self(base.left))”"
    }
}

/// Lays out its content at its natural width, but no wider than `maxWidth`
/// (a long title is cut short with "…").
private struct CappedWidth: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(.unspecified)
        let width = min(natural.width, maxWidth, proposal.width ?? .infinity)
        return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
