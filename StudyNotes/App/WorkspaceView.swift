import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// One of Memor's windows: the tab bar on top, and below it the tab on
/// screen (a notebook or PDF, or two side by side), or the library.
struct WorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var workspace: Workspace
    @State private var importMessage: String?

    init(window: MemorWindow) {
        _workspace = State(initialValue: Workspace(window: window))
    }

    var body: some View {
        VStack(spacing: 0) {
            if workspace.showsTabStrip {
                TabStrip(workspace: workspace)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy, value: workspace.showsTabStrip)
        .environment(\.workspace, workspace)
        // The study pal, over everything in the window.
        .overlay { PalOverlay() }
        .background {
            WindowReader { workspace.attach(to: $0) }
                .frame(width: 0, height: 0)
        }
        .onAppear { workspace.start() }
        // "Open in Memor" from Files, Mail or Safari. The system hands
        // over a copy in the Inbox folder, which is removed after importing.
        .onOpenURL { url in openFromAnotherApp(url) }
        // An open window takes it, instead of a new window opening for it.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .alert("Couldn't import", isPresented: showsImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let tab = workspace.selectedTab {
            TabContent(tab: tab, workspace: workspace)
                .id(tab.id)
        } else {
            LibraryView()
        }
    }

    private func openFromAnotherApp(_ url: URL) {
        Task {
            let result = await LibraryImport.importPDFs([url], into: modelContext, removingSources: url.pathComponents.contains("Inbox"))
            if let id = result.ids.first { workspace.open(.pdf(id)) }
            importMessage = result.failureMessage
        }
    }

    private var showsImportMessage: Binding<Bool> {
        Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })
    }
}

/// The tab on screen: a notebook or PDF, or two side by side with a divider
/// you can drag (double-tap it to even them out). Drop a tab here to put it
/// beside what's on screen.
private struct TabContent: View {
    let tab: WorkspaceTab
    let workspace: Workspace
    /// Where the divider is while you drag it.
    @State private var draggedSplit: Double?
    /// The side a tab dragged over this one would go on.
    @State private var dropSide: PaneSide?

    private static let space = "tabContent"
    private static let dividerWidth: CGFloat = 12

    private var split: Double { draggedSplit ?? tab.split }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            HStack(spacing: 0) {
                ForEach(tab.targets, id: \.self) { target in
                    let side = tab.side(of: target) ?? .left
                    if side == .right {
                        divider(totalWidth: size.width)
                    }
                    PaneView(target: target, side: side, isActive: tab.isActive(side), isPair: tab.isPair)
                        .frame(width: width(of: side, in: size.width))
                }
            }
            .coordinateSpace(.named(Self.space))
            .overlay(alignment: .topLeading) {
                dropHighlight(in: size)
            }
            .animation(.easeOut(duration: 0.15), value: dropSide)
            .onDrop(of: [.memorTab], delegate: ContentDropDelegate(
                tab: tab,
                workspace: workspace,
                side: { point in side(at: point, in: size) },
                dropSide: $dropSide
            ))
        }
    }

    // MARK: Layout

    private func width(of side: PaneSide, in total: CGFloat) -> CGFloat {
        guard tab.isPair else { return total }
        let available = max(total - Self.dividerWidth, 0)
        return side == .left ? available * split : available * (1 - split)
    }

    private func divider(totalWidth: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .secondarySystemBackground))
            Capsule()
                .fill(.tertiary)
                .frame(width: 4, height: 44)
        }
        .frame(width: Self.dividerWidth)
        .contentShape(.rect)
        .hoverEffect(.highlight)
        .onTapGesture(count: 2) {
            withAnimation(.snappy) { workspace.setSplit(0.5) }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    let available = max(totalWidth - Self.dividerWidth, 1)
                    draggedSplit = Workspace.clampedSplit((value.location.x - Self.dividerWidth / 2) / available)
                }
                .onEnded { _ in
                    if let draggedSplit { workspace.setSplit(draggedSplit) }
                    draggedSplit = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Divider")
        .accessibilityValue("\(Int((split * 100).rounded())) percent on the left")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: workspace.setSplit(split + 0.1)
            case .decrement: workspace.setSplit(split - 0.1)
            @unknown default: break
            }
        }
    }

    // MARK: Dropping a tab

    private func side(at point: CGPoint, in size: CGSize) -> PaneSide {
        if tab.isPair {
            return point.x < width(of: .left, in: size.width) + Self.dividerWidth / 2 ? .left : .right
        }
        return point.x < size.width / 2 ? .left : .right
    }

    /// Where a dropped tab would go: half of the window, or the side it
    /// would take the place of.
    private func dropFrame(_ side: PaneSide, in size: CGSize) -> CGRect {
        if tab.isPair {
            let left = width(of: .left, in: size.width)
            return side == .left
                ? CGRect(x: 0, y: 0, width: left, height: size.height)
                : CGRect(x: left + Self.dividerWidth, y: 0, width: size.width - left - Self.dividerWidth, height: size.height)
        }
        let half = size.width / 2
        return CGRect(x: side == .left ? 0 : half, y: 0, width: half, height: size.height)
    }

    @ViewBuilder
    private func dropHighlight(in size: CGSize) -> some View {
        if let dropSide {
            let frame = dropFrame(dropSide, in: size)
            RoundedRectangle(cornerRadius: 18)
                .fill(.tint.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 18).strokeBorder(.tint, lineWidth: 3)
                }
                .padding(10)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// One side of the tab on screen, with its own navigation (a notebook's page
/// grid and its pages) and toolbar. With two, a line on top marks the side
/// you're using.
private struct PaneView: View {
    let target: OpenTarget
    let side: PaneSide
    let isActive: Bool
    let isPair: Bool

    var body: some View {
        NavigationStack {
            ItemScreen(target: target)
        }
        .environment(\.paneSide, side)
        .overlay(alignment: .top) {
            if isPair && isActive {
                Rectangle()
                    .fill(.tint)
                    .frame(height: 3)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A tab dragged over the tab on screen goes beside it: on the half it's
/// dropped on, or in place of the side it's dropped on.
private struct ContentDropDelegate: DropDelegate {
    let tab: WorkspaceTab
    let workspace: Workspace
    let side: (CGPoint) -> PaneSide
    @Binding var dropSide: PaneSide?

    /// Only a tab with one item, and not this one, can go beside it.
    private var canDrop: Bool {
        guard let id = WorkspaceRegistry.shared.draggingTabID, id != tab.id,
              let found = WorkspaceRegistry.shared.tab(id) else { return false }
        return !found.tab.isPair
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.memorTab]) && canDrop
    }

    func dropEntered(info: DropInfo) {
        dropSide = canDrop ? side(info.location) : nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard canDrop else {
            dropSide = nil
            return DropProposal(operation: .forbidden)
        }
        dropSide = side(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropSide = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let placed = side(info.location)
        dropSide = nil
        guard canDrop, let id = WorkspaceRegistry.shared.draggingTabID else { return false }
        WorkspaceRegistry.shared.draggingTabID = nil
        withAnimation(.snappy) { workspace.dropTab(id, on: placed) }
        return true
    }
}
