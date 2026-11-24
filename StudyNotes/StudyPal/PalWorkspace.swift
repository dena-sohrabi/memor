import UIKit

/// What a window shows: a notebook page or a PDF.
enum PalPageKind {
    case notebook, pdf
}

/// A page as the study pal sees it: a picture of the part on screen, and
/// its text.
struct PalSnapshot {
    /// JPEG of what's on screen, or nil for an empty page.
    var image: Data?
    /// The part of the page the picture shows, in page points.
    var area: CGRect
    /// The pixel size of the picture, so she can turn spots in it into
    /// page points.
    var imageSize: CGSize
    /// Typed notes, and on a PDF the text of the page in view.
    var text: String
    /// Text the student selected, if any.
    var selection: String?
}

/// Something the student circled for the study pal.
struct PalCircle: Equatable {
    let id = UUID()
    /// The page it's on (`PalPage.palPageID`).
    let pageID: UUID
    /// On a PDF, which page of it (from 0).
    let pageIndex: Int?
    /// The circled area, in page points.
    let rect: CGRect
    /// The circled area, as JPEG.
    let image: Data
}

/// Where on a page to do something: on a PDF, which of its pages (from
/// 0, or nil for the one in view), and what to put it beside.
struct PalPlace {
    var pageIndex: Int?
    /// Something circled to put it beside, in page points.
    var near: CGRect?
}

/// One page open in a window, which the study pal can see and work on.
/// Notebook pages and PDFs provide it. Every change goes through the
/// page's own undo. Coordinates are page points: x grows to the right, y
/// grows down (on a PDF, from the top-left of each of its pages).
@MainActor
protocol PalPage: AnyObject {
    /// This open page, for as long as it's open.
    var palPageID: UUID { get }
    /// What's open, the same every time it's opened: the notebook page's
    /// id, or the PDF's. So it keeps its short name (N1, P1) when you go
    /// back to it.
    var palStableID: UUID { get }
    /// The notebook or PDF, for what she remembers about it.
    var palItemID: UUID { get }
    var palKind: PalPageKind { get }
    /// The notebook's or the PDF's title.
    var palItemTitle: String { get }
    /// Where in it the student is: "page “Mendel” (2 of 5)", "page 12 of 40".
    var palWhere: String { get }
    /// Changes whenever the page does (or, in a PDF, when the student turns
    /// to another page), so she knows when to take a fresh look.
    var palVersion: Int { get }
    /// The window it's in.
    var palWindow: UIWindow? { get }
    /// Notebook pages take pictures; PDFs don't.
    var canAddImages: Bool { get }

    /// What's on screen, and the page's text.
    func palSnapshot() -> PalSnapshot
    /// The text around where the student is (no pictures, so it's quick),
    /// so speech-to-text knows the words of their subject.
    func palVocabularyText() -> String
    /// A sharp picture of one area (page points; nil for everything on the
    /// page), and the area it shows. On a PDF, of `pageIndex` (or the page
    /// in view). `labelHandwriting`: each handwritten word gets a numbered
    /// box, with ids she can erase or move.
    func palLook(at area: CGRect?, pageIndex: Int?, labelHandwriting: Bool) -> (image: Data, area: CGRect)?
    /// A JSON description of the page: the area on screen, typed notes,
    /// pictures and handwritten words with their ids and positions.
    func palItems(pageIndex: Int?) -> String
    /// Erases the student's handwritten words (ids from the last look or
    /// list), or every stroke mostly inside `region`.
    func palEraseHandwriting(ids: [String], region: CGRect?, pageIndex: Int?) -> (result: String, isError: Bool)
    /// Moves handwritten words, together, so their top-left is at `origin`.
    func palMoveHandwriting(ids: [String], to origin: CGPoint, pageIndex: Int?) -> (result: String, isError: Bool)
    /// Scrolls and zooms to show an area (nil: everything on the page).
    func palShowArea(_ area: CGRect?, pageIndex: Int?) -> String?
    /// Undoes or redoes the last change in this window, hers or the student's.
    func palUndo() -> Bool
    func palRedo() -> Bool
    /// Removes PDF highlights on a page whose text contains `text`.
    func palRemoveHighlights(_ text: String, pageIndex: Int?) -> String?
    /// The typed notes, top to bottom, so what she writes can follow them.
    func palNotes(pageIndex: Int?) -> String

    /// Adds a typed note, at `origin` or in free space beside `place.near`
    /// (or in view), in `color` (or the page's own). Returns its id.
    func palAddText(_ text: String, at origin: CGPoint?, color: UIColor?, in place: PalPlace) -> UUID?
    /// Adds a picture in free space beside `place.near`, or in view.
    func palAddImage(_ image: PreparedImage, in place: PalPlace) -> UUID?
    /// Writes by hand. Returns what happened, for her.
    func palWrite(_ text: String, at origin: CGPoint?, letterHeight: CGFloat?, color: UIColor?, in place: PalPlace) -> (result: String, isError: Bool)
    /// Draws a mark (a circle, underline, arrow…) on the page.
    func palMark(_ mark: PalInk.Mark, around rect: CGRect, to: CGPoint?, color: UIColor?, in place: PalPlace) -> String?
    func palMoveItem(_ id: UUID, to origin: CGPoint) -> String?
    func palResizeItem(_ id: UUID, width: CGFloat) -> String?
    func palEditText(_ id: UUID, text: String) -> String?
    func palDeleteItem(_ id: UUID) -> String?
    /// A typed note or picture with this id is on this page.
    func palHasItem(_ id: UUID) -> Bool
    /// Changes the color of typed notes (by id), and of ink: handwritten
    /// words by id, or every stroke mostly inside `region` (theirs or hers).
    func palRecolor(notes: [UUID], ink: [String], region: CGRect?, color: UIColor, pageIndex: Int?) -> (result: String, isError: Bool)

    /// The text of some of a PDF's pages (from 0). Nil on a notebook.
    func palReadPages(_ pages: ClosedRange<Int>) -> String?
    /// Highlights text on a PDF page. Returns why it couldn't, or nil.
    func palHighlight(_ text: String, pageIndex: Int?, color: HighlightColor) -> String?

    /// Turns on circling: the next loop the student draws goes to her.
    func palStartCircling()
    func palStopCircling()
}

extension PalPage {
    /// The title and the typed notes. (Handwriting isn't text, so it can't
    /// help.) PDFs add the text of the pages around the one in view.
    func palVocabularyText() -> String {
        [palItemTitle, palNotes(pageIndex: nil)].joined(separator: "\n")
    }
}

/// Page descriptions for the study pal, as JSON.
enum PalJSON {
    static func string(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Every page open in Memor, and which window the study pal is in. There's
/// one study pal for the whole app, and she sees every open page.
@MainActor
@Observable
final class PalWorkspace {
    static let shared = PalWorkspace()

    private struct Entry {
        weak var page: PalPage?
        /// What she calls it: "N1" for a notebook page, "P1" for a PDF.
        let shortID: String
    }

    private struct KnownWindow {
        weak var window: UIWindow?
    }

    @ObservationIgnored private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var counters: [PalPageKind: Int] = [:]
    /// Short names by `palStableID`, so a notebook page or PDF keeps its
    /// name ("N1") when you leave it and come back, and what she did on it
    /// earlier in the talk still points at it.
    @ObservationIgnored private var names: [UUID: String] = [:]
    /// Memor's windows that have her overlay.
    @ObservationIgnored private var windows: [ObjectIdentifier: KnownWindow] = [:]
    /// The window you used last.
    @ObservationIgnored private var lastUsed: ObjectIdentifier?
    /// Where she sits: the window you used last, if it's on screen, or
    /// else another of Memor's windows that is.
    private(set) var activeWindow: ObjectIdentifier?
    /// Goes up when pages open or close, or another window comes forward.
    private(set) var changes = 0

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        // Only which window or scene it was crosses over, not the notification.
        observers.append(center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as AnyObject?, window is UIWindow else { return }
            let id = ObjectIdentifier(window)
            MainActor.assumeIsolated { self?.used(id) }
        })
        // A window coming to the front (like going back to the library) is
        // being used, even when it was already its scene's key window.
        observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] note in
            guard let scene = note.object as AnyObject?, scene is UIScene else { return }
            let id = ObjectIdentifier(scene)
            MainActor.assumeIsolated { self?.sceneActivated(id) }
        })
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification, UIScene.didDisconnectNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    // MARK: Pages

    func register(_ page: PalPage) {
        prune()
        guard entries[page.palPageID] == nil else { return }
        let stableID = page.palStableID
        // The same page, opened again before the old one closed: the new one
        // is the one on screen.
        entries = entries.filter { $0.value.page?.palStableID != stableID }
        let shortID: String
        if let known = names[stableID] {
            shortID = known
        } else {
            let prefix = page.palKind == .notebook ? "N" : "P"
            let number = (counters[page.palKind] ?? 0) + 1
            counters[page.palKind] = number
            shortID = "\(prefix)\(number)"
            names[stableID] = shortID
        }
        entries[page.palPageID] = Entry(page: page, shortID: shortID)
        changes += 1
    }

    func unregister(_ page: PalPage) {
        entries[page.palPageID] = nil
        prune()
        changes += 1
    }

    /// The page in the window you're using, if it shows one.
    var focusedPage: PalPage? {
        let pages = openPages
        if let activeWindow, let page = pages.first(where: { page in page.palWindow.map { ObjectIdentifier($0) } == activeWindow }) {
            return page
        }
        return nil
    }

    /// Pages in windows on screen now: the one you're using first.
    var visiblePages: [PalPage] {
        let focused = focusedPage
        var pages = openPages.filter { page in
            guard let scene = page.palWindow?.windowScene else { return false }
            return scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
        }
        if let focused {
            pages.removeAll { $0 === focused }
            pages.insert(focused, at: 0)
        }
        return pages
    }

    /// Every open page, in windows on screen or not.
    var openPages: [PalPage] {
        // Read so views update when pages open or close.
        _ = changes
        return entries.values.compactMap(\.page).sorted { shortID(of: $0) < shortID(of: $1) }
    }

    func shortID(of page: PalPage) -> String {
        entries[page.palPageID]?.shortID ?? "?"
    }

    func page(shortID: String) -> PalPage? {
        let wanted = shortID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return entries.values.first { $0.shortID == wanted }?.page
    }

    func page(id: UUID) -> PalPage? {
        entries[id]?.page
    }

    private func prune() {
        entries = entries.filter { $0.value.page != nil }
    }

    // MARK: Windows

    /// A window's overlay found its window.
    func windowAppeared(_ window: UIWindow) {
        let id = ObjectIdentifier(window)
        windows[id] = KnownWindow(window: window)
        if lastUsed == nil || window.isKeyWindow { lastUsed = id }
        refresh()
    }

    /// You used one of Memor's windows (other windows don't count).
    private func used(_ id: ObjectIdentifier) {
        guard windows[id]?.window != nil else { return }
        lastUsed = id
        refresh()
    }

    /// A scene came to the front: its window is the one you're using.
    private func sceneActivated(_ sceneID: ObjectIdentifier) {
        let inScene = windows.filter { entry in
            entry.value.window?.windowScene.map { ObjectIdentifier($0) } == sceneID
        }
        let pick = inScene.first { $0.value.window?.isKeyWindow == true } ?? inScene.first
        if let pick { used(pick.key) } else { refresh() }
    }

    /// Works out where she sits: the window you used last while it's on
    /// screen, or else any of Memor's windows on screen.
    private func refresh() {
        windows = windows.filter { $0.value.window != nil }
        func onScreen(_ window: UIWindow?) -> Bool {
            guard let state = window?.windowScene?.activationState else { return false }
            return state == .foregroundActive || state == .foregroundInactive
        }
        var pick: ObjectIdentifier?
        if let lastUsed, onScreen(windows[lastUsed]?.window) {
            pick = lastUsed
        } else {
            pick = windows.first { $0.value.window?.windowScene?.activationState == .foregroundActive }?.key
                ?? windows.first { onScreen($0.value.window) }?.key
        }
        guard pick != activeWindow else { return }
        activeWindow = pick
        changes += 1
    }
}
