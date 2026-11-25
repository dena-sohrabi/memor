import Foundation
import Observation
import PencilKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A notebook or PDF to show.
enum OpenTarget: Codable, Hashable, Sendable {
    case notebook(UUID)
    case pdf(UUID)

    /// The notebook's or the PDF's id.
    var id: UUID {
        switch self {
        case .notebook(let id), .pdf(let id): id
        }
    }
}

/// A side of a tab that shows two items.
enum PaneSide: String, Codable, Hashable, Sendable {
    case left, right

    var other: PaneSide { self == .left ? .right : .left }
}

/// One tab: a notebook or PDF, or two of them side by side.
struct WorkspaceTab: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var left: OpenTarget
    var right: OpenTarget?
    /// The left side's share of the width, when there are two.
    var split = 0.5
    /// The side you touched last. The pen palette and the study pal work
    /// there.
    var activeSide = PaneSide.left

    init(_ target: OpenTarget) {
        left = target
    }

    var isPair: Bool { right != nil }

    /// What it shows, left to right.
    var targets: [OpenTarget] {
        if let right { [left, right] } else { [left] }
    }

    /// What's on the side you're using.
    var activeTarget: OpenTarget {
        activeSide == .right ? (right ?? left) : left
    }

    func target(on side: PaneSide) -> OpenTarget? {
        side == .left ? left : right
    }

    func side(of target: OpenTarget) -> PaneSide? {
        if left == target { return .left }
        if right == target { return .right }
        return nil
    }

    func contains(_ target: OpenTarget) -> Bool {
        side(of: target) != nil
    }

    /// Whether `side` is the one you're using. With one item, it always is.
    func isActive(_ side: PaneSide) -> Bool {
        !isPair || activeSide == side
    }
}

/// What a window was opened with. Every window has its own id, so it keeps
/// its own tabs. One opened with Open in New Window starts with that tab.
struct MemorWindow: Codable, Hashable, Sendable {
    var id = UUID()
    var tab: WorkspaceTab?
}

extension UTType {
    /// A tab being dragged, to another place in the tab bar, beside the
    /// tab on screen, or to another window. Only Memor can read it.
    static let memorTab = UTType(exportedAs: "com.denasohrabi.memor.tab")
}

extension EnvironmentValues {
    /// The tabs of the window a view is in.
    @Entry var workspace: Workspace? = nil
    /// The side of the tab a view is in. Nil outside the tabs (the library).
    @Entry var paneSide: PaneSide? = nil
}

/// A window's tabs. Tapping a card opens it in a tab (or goes to its tab).
/// A tab can show two items side by side. The library shows when no tab is
/// selected.
///
/// A notebook or PDF is in one place at a time, across every window, so two
/// screens never edit the same page. Opening one that's in another window
/// brings that window forward.
///
/// The tabs are kept on this iPad and written right away, so they come back
/// after Memor is closed (by you, a crash, or iPadOS when memory runs low).
@MainActor
@Observable
final class Workspace {
    /// The open tabs, in order.
    private(set) var tabs: [WorkspaceTab] = [] {
        didSet { save() }
    }

    /// The tab on screen, or nil for the library.
    private(set) var selectedTabID: UUID? {
        didSet { save() }
    }

    /// The tab that was on screen before, so Open Beside from the library
    /// knows what to open beside.
    private(set) var previousTabID: UUID? {
        didSet { save() }
    }

    /// Sides whose notebook page hid its toolbars (a tap on empty paper).
    /// The tab bar hides too when every side on screen did.
    private(set) var chromeHiddenSides: Set<PaneSide> = []

    @ObservationIgnored let windowID: UUID
    /// The window it's in, once it's on screen.
    @ObservationIgnored private(set) weak var window: UIWindow?
    @ObservationIgnored private var isStarted = false
    /// Tabs taken over from a window that isn't open anymore (see `init`).
    @ObservationIgnored private var adoptedKey: String?
    @ObservationIgnored private var pickerStorage: PKToolPicker?

    /// Nothing here changes what's saved or what other windows show, because
    /// SwiftUI may make a few of these before keeping one. `start()` does that.
    init(window value: MemorWindow) {
        windowID = value.id
        let saved = Self.loadAll()
        if let mine = saved[value.id.uuidString] {
            restore(mine)
        } else if let tab = value.tab {
            tabs = [tab]
            selectedTabID = tab.id
        } else if WorkspaceRegistry.shared.all.isEmpty {
            // The first window of a launch with nothing to restore: iPadOS
            // drops windows when you swipe Memor away. Bring back the tabs
            // you used last, so closing Memor doesn't lose them.
            if let last = saved
                .filter({ !$0.value.tabs.isEmpty })
                .max(by: { $0.value.savedAt < $1.value.savedAt }) {
                restore(last.value)
                adoptedKey = last.key
            } else if saved.isEmpty, let target = Self.legacyTarget() {
                // What was open when Memor had one window and no tabs.
                let tab = WorkspaceTab(target)
                tabs = [tab]
                selectedTabID = tab.id
            }
        }
    }

    // MARK: Reading

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The tab Open Beside opens beside: the one on screen, or the one you
    /// left for the library.
    var besideTab: WorkspaceTab? {
        selectedTab ?? tabs.first { $0.id == previousTabID }
    }

    /// What's on the side you're using, or nil in the library.
    var activeTarget: OpenTarget? {
        selectedTab?.activeTarget
    }

    var showsTabStrip: Bool {
        guard !tabs.isEmpty else { return false }
        guard let tab = selectedTab else { return true }
        let sides: [PaneSide] = tab.isPair ? [.left, .right] : [.left]
        return !sides.allSatisfy(chromeHiddenSides.contains)
    }

    func contains(_ target: OpenTarget) -> Bool {
        tabs.contains { $0.contains(target) }
    }

    /// Whether `side` of the tab on screen is the one you're using.
    func isActive(_ side: PaneSide?) -> Bool {
        guard let side, let tab = selectedTab else { return true }
        return tab.isActive(side)
    }

    /// One pen palette for the window, so the pen you pick works on both
    /// sides, and only one palette is ever on screen.
    var toolPicker: PKToolPicker {
        if let pickerStorage { return pickerStorage }
        let picker = PKToolPicker()
        pickerStorage = picker
        return picker
    }

    // MARK: Opening

    /// Shows a notebook or PDF: its tab, if it's open in this window; the
    /// window it's open in, if that's another one; or else a new tab after
    /// the one on screen.
    func open(_ target: OpenTarget) {
        if let index = tabs.firstIndex(where: { $0.contains(target) }) {
            if let side = tabs[index].side(of: target), tabs[index].activeSide != side {
                tabs[index].activeSide = side
            }
            select(tabs[index].id)
            return
        }
        if let other = WorkspaceRegistry.shared.workspace(holding: target, except: self) {
            other.open(target)
            other.bringForward()
            return
        }
        let tab = WorkspaceTab(target)
        let after = (selectedTabID ?? previousTabID).flatMap { id in tabs.firstIndex { $0.id == id } }
        tabs.insert(tab, at: after.map { $0 + 1 } ?? tabs.endIndex)
        select(tab.id)
    }

    /// Shows a notebook or PDF beside the tab on screen (or the one you left
    /// for the library), on `side`. With nil, it goes on the right, or, when
    /// the tab already shows two, in place of the side you aren't using. What
    /// it replaces gets a tab of its own.
    func openBeside(_ target: OpenTarget, on side: PaneSide? = nil) {
        guard let base = besideTab else {
            open(target)
            return
        }
        guard !base.contains(target) else {
            open(target)
            return
        }
        // In one place at a time: out of its own tab, or another window.
        remove(target, keeping: base.id)
        WorkspaceRegistry.shared.removeEverywhere(target, except: self)
        guard let index = tabs.firstIndex(where: { $0.id == base.id }) else {
            open(target)
            return
        }
        var tab = tabs[index]
        if let right = tab.right {
            let replaced = side ?? tab.activeSide.other
            let old = replaced == .left ? tab.left : right
            if replaced == .left { tab.left = target } else { tab.right = target }
            tab.activeSide = replaced
            tabs[index] = tab
            tabs.insert(WorkspaceTab(old), at: index + 1)
        } else {
            let placed = side ?? .right
            if placed == .left {
                tab.right = tab.left
                tab.left = target
            } else {
                tab.right = target
            }
            tab.split = 0.5
            tab.activeSide = placed
            tabs[index] = tab
        }
        select(tab.id)
        PalWorkspace.shared.focusChanged()
    }

    /// A tab dragged onto the tab on screen goes beside it, on the side it
    /// was dropped on (from this window or another).
    func dropTab(_ id: UUID, on side: PaneSide) {
        guard let base = selectedTab, base.id != id,
              let found = WorkspaceRegistry.shared.tab(id),
              !found.tab.isPair else { return }
        found.workspace.closeTab(id)
        openBeside(found.tab.left, on: side)
    }

    /// Moves a tab to where `targetID` is (or to the end), so it lands
    /// after that tab when moving right and before it when moving left. A
    /// tab from another window moves into this one, before `targetID`.
    func moveTab(_ id: UUID, to targetID: UUID?) {
        guard id != targetID else { return }
        let destination = targetID.flatMap { target in tabs.firstIndex { $0.id == target } } ?? tabs.endIndex
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            var reordered = tabs
            let tab = reordered.remove(at: index)
            reordered.insert(tab, at: min(destination, reordered.endIndex))
            tabs = reordered
        } else if let found = WorkspaceRegistry.shared.tab(id) {
            found.workspace.closeTab(id)
            // Out of the other window, which may have held what it shows.
            for target in found.tab.targets { remove(target) }
            let destination = targetID.flatMap { target in tabs.firstIndex { $0.id == target } } ?? tabs.endIndex
            tabs.insert(found.tab, at: destination)
            select(found.tab.id)
        }
    }

    /// The window value for Open in New Window: the new window starts with
    /// `tab`, which leaves this window and every other.
    func newWindow(with tab: WorkspaceTab) -> MemorWindow {
        if tabs.contains(where: { $0.id == tab.id }) { closeTab(tab.id) }
        for target in tab.targets {
            WorkspaceRegistry.shared.removeEverywhere(target)
        }
        return MemorWindow(tab: tab)
    }

    // MARK: Tabs

    func select(_ id: UUID?) {
        guard id != selectedTabID else { return }
        if let selectedTabID { previousTabID = selectedTabID }
        chromeHiddenSides = []
        selectedTabID = id
        PalWorkspace.shared.focusChanged()
    }

    func showLibrary() {
        select(nil)
    }

    /// Closes a tab. The tab beside it comes on screen, or the library when
    /// it was the last one.
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var remaining = tabs
        remaining.remove(at: index)
        if previousTabID == id { previousTabID = nil }
        if selectedTabID == id {
            let next = remaining.indices.contains(index) ? remaining[index] : remaining.last
            chromeHiddenSides = []
            tabs = remaining
            selectedTabID = next?.id
            PalWorkspace.shared.focusChanged()
        } else {
            tabs = remaining
        }
    }

    /// Closes one side of a tab with two; the other fills the tab.
    func closeSide(_ side: PaneSide, ofTab id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs[index]
        guard let right = tab.right else {
            closeTab(id)
            return
        }
        if side == .left { tab.left = right }
        tab.right = nil
        tab.activeSide = .left
        tabs[index] = tab
        chromeHiddenSides = []
        PalWorkspace.shared.focusChanged()
    }

    /// Takes a notebook or PDF out of this window: its tab closes, or its
    /// side of a tab with two. `keeping` is a tab to leave alone.
    func remove(_ target: OpenTarget, keeping: UUID? = nil) {
        for tab in tabs where tab.id != keeping {
            guard let side = tab.side(of: target) else { continue }
            if tab.isPair { closeSide(side, ofTab: tab.id) } else { closeTab(tab.id) }
        }
    }

    /// Splits a tab with two into two tabs, side by side in the tab bar.
    func separate(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), let right = tabs[index].right else { return }
        var reordered = tabs
        reordered[index].right = nil
        reordered[index].activeSide = .left
        reordered.insert(WorkspaceTab(right), at: index + 1)
        chromeHiddenSides = []
        tabs = reordered
        PalWorkspace.shared.focusChanged()
    }

    func swapSides(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), let right = tabs[index].right else { return }
        var tab = tabs[index]
        tab.right = tab.left
        tab.left = right
        tab.split = 1 - tab.split
        tab.activeSide = tab.activeSide.other
        chromeHiddenSides = Set(chromeHiddenSides.map(\.other))
        tabs[index] = tab
    }

    // MARK: The tab on screen

    /// You touched `side` of the tab on screen: it's the one you're using now.
    func activate(_ side: PaneSide?) {
        guard let side, let index = tabs.firstIndex(where: { $0.id == selectedTabID }),
              tabs[index].isPair, tabs[index].activeSide != side else { return }
        tabs[index].activeSide = side
        PalWorkspace.shared.focusChanged()
    }

    /// Where the divider is, as the left side's share of the width.
    func setSplit(_ split: Double) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        tabs[index].split = Self.clampedSplit(split)
    }

    static func clampedSplit(_ split: Double) -> Double {
        min(max(split, 0.3), 0.7)
    }

    func setChromeHidden(_ hidden: Bool, on side: PaneSide?) {
        let side = side ?? .left
        if hidden { chromeHiddenSides.insert(side) } else { chromeHiddenSides.remove(side) }
    }

    // MARK: The window

    /// The window is on screen: it takes part in opening and moving tabs.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        WorkspaceRegistry.shared.add(self)
        if let adoptedKey {
            var saved = Self.loadAll()
            saved[adoptedKey] = nil
            Self.storeAll(saved)
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        // In one place at a time: what another window already shows (it
        // came back first) leaves this one.
        for other in WorkspaceRegistry.shared.all where other !== self {
            for target in other.tabs.flatMap(\.targets) where contains(target) {
                remove(target)
            }
        }
        if selectedTabID != nil, selectedTab == nil { selectedTabID = tabs.first?.id }
        save()
    }

    func attach(to window: UIWindow) {
        self.window = window
    }

    /// Brings this window to the front.
    func bringForward() {
        guard let session = window?.windowScene?.session else { return }
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session), errorHandler: nil)
    }

    // MARK: Saving

    private struct Saved: Codable {
        var tabs: [WorkspaceTab]
        var selectedTabID: UUID?
        var previousTabID: UUID?
        var savedAt: Date
    }

    private static let storeKey = "workspace.windows"
    /// Where the one window kept what was open, before tabs.
    private static let legacyKey = "navigation.open"
    /// How many windows' tabs are kept. Windows you closed leave theirs
    /// behind, so the oldest go.
    private static let keptWindows = 12

    private func restore(_ saved: Saved) {
        let isOpen = { (id: UUID) in saved.tabs.contains { $0.id == id } }
        tabs = saved.tabs
        selectedTabID = saved.selectedTabID.flatMap { isOpen($0) ? $0 : nil }
        previousTabID = saved.previousTabID.flatMap { isOpen($0) ? $0 : nil }
    }

    private func save() {
        guard isStarted else { return }
        var saved = Self.loadAll()
        saved[windowID.uuidString] = Saved(tabs: tabs, selectedTabID: selectedTabID, previousTabID: previousTabID, savedAt: .now)
        if saved.count > Self.keptWindows {
            let oldest = saved.sorted { $0.value.savedAt < $1.value.savedAt }.prefix(saved.count - Self.keptWindows)
            for (key, _) in oldest { saved[key] = nil }
        }
        Self.storeAll(saved)
    }

    private static func loadAll() -> [String: Saved] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let saved = try? JSONDecoder().decode([String: Saved].self, from: data) else { return [:] }
        return saved
    }

    private static func storeAll(_ saved: [String: Saved]) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private static func legacyTarget() -> OpenTarget? {
        guard let data = UserDefaults.standard.data(forKey: legacyKey) else { return nil }
        return (try? JSONDecoder().decode([OpenTarget].self, from: data))?.last
    }
}

/// Memor's windows that are open now, so opening something can find the
/// window it's already in, and the study pal knows which window you're using.
@MainActor
final class WorkspaceRegistry {
    static let shared = WorkspaceRegistry()

    private struct Entry {
        weak var workspace: Workspace?
    }

    private var entries: [Entry] = []

    var all: [Workspace] {
        entries.compactMap(\.workspace)
    }

    func add(_ workspace: Workspace) {
        entries.removeAll { $0.workspace == nil || $0.workspace === workspace }
        entries.append(Entry(workspace: workspace))
    }

    /// The window you're using: the one the study pal is in, or else the
    /// key window.
    var current: Workspace? {
        let open = all
        if let active = PalWorkspace.shared.activeWindow, let workspace = workspace(in: active) {
            return workspace
        }
        return open.first { $0.window?.isKeyWindow == true } ?? open.first
    }

    func workspace(in window: ObjectIdentifier) -> Workspace? {
        all.first { $0.window.map { ObjectIdentifier($0) } == window }
    }

    func workspace(holding target: OpenTarget, except excluded: Workspace?) -> Workspace? {
        all.first { $0 !== excluded && $0.contains(target) }
    }

    /// A tab by its id, and the window it's in.
    func tab(_ id: UUID) -> (workspace: Workspace, tab: WorkspaceTab)? {
        for workspace in all {
            if let tab = workspace.tabs.first(where: { $0.id == id }) { return (workspace, tab) }
        }
        return nil
    }

    /// Takes a notebook or PDF out of every window but `excluded`: when it's
    /// deleted, or moves somewhere else.
    func removeEverywhere(_ target: OpenTarget, except excluded: Workspace? = nil) {
        for workspace in all where workspace !== excluded {
            workspace.remove(target)
        }
    }

    /// The tab being dragged now, set when a drag starts. Drops read it
    /// instead of the dragged data, which arrives later.
    var draggingTabID: UUID?
}
