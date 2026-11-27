import Foundation
import Observation
import SwiftUI

/// A notebook or PDF to show.
enum OpenTarget: Codable, Hashable, Sendable {
    case notebook(UUID)
    case pdf(UUID)
}

/// Memor's two kinds of windows.
enum WindowID {
    /// The main window: the library, with a notebook or PDF on top of it.
    static let main = "main"
    /// A notebook or PDF in a window of its own.
    static let item = "item"
}

/// The main window's value. It's always the same, so asking for the main
/// window again brings it forward instead of opening a second one.
enum MainWindow: String, Codable, Hashable, Sendable {
    case main
}

extension EnvironmentValues {
    /// The view is in a notebook's or PDF's own window, not the main one.
    @Entry var isInItemWindow = false
}

/// Where things open. Tapping a card, the study pal and "Open in Memor" all
/// go through here.
///
/// The main window shows the library, or a notebook or PDF on top of it
/// (`path`). Open in New Window puts a notebook or PDF in a window of its
/// own instead. Each is in one place at a time: opening one that has its
/// own window brings that window forward, and the main window lets go of
/// one that moves to its own window.
///
/// What's open in the main window is kept on this iPad, so it comes back
/// after Memor is closed (by you, a crash, or iPadOS when memory runs low).
/// iPadOS brings back the other windows itself.
@MainActor
@Observable
final class AppNavigator {
    static let shared = AppNavigator()

    /// The main window's navigation stack: empty for the library, or the one
    /// notebook or PDF that's open.
    var path: [OpenTarget] {
        didSet { save() }
    }

    /// Notebooks and PDFs open in windows of their own.
    @ObservationIgnored private var windowTargets: Set<OpenTarget> = []
    /// Opens windows. Set by whichever window appeared last; any window's
    /// action can open any of Memor's windows.
    @ObservationIgnored var openWindow: OpenWindowAction?
    /// Closes windows, set along with `openWindow`.
    @ObservationIgnored var dismissWindow: DismissWindowAction?

    private static let key = "navigation.open"

    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.key)
        path = saved.flatMap { try? JSONDecoder().decode([OpenTarget].self, from: $0) } ?? []
    }

    /// Shows a notebook or PDF: its own window, if it has one; otherwise the
    /// main window, in place of whatever is open there. If it's already
    /// open, it stays as it is (on the page you were on).
    /// `showingMainWindow`: also bring the main window forward, for when
    /// the request comes from another window (the study pal in a PDF's
    /// window, say).
    func open(_ target: OpenTarget, showingMainWindow: Bool = false) {
        if windowTargets.contains(target), let openWindow {
            openWindow(id: WindowID.item, value: target)
            return
        }
        if path != [target] { path = [target] }
        if showingMainWindow { showMainWindow() }
    }

    /// Opens a notebook or PDF in a window of its own, or brings its window
    /// forward. The main window goes back to the library if it was showing it.
    func openInNewWindow(_ target: OpenTarget) {
        if path.contains(target) { path = [] }
        openWindow?(id: WindowID.item, value: target)
    }

    /// Back to the library, in the main window.
    func showLibrary() {
        path = []
    }

    /// How `close` closed something.
    enum Closed {
        /// Its own window closed.
        case window
        /// The main window went back to the library.
        case mainWindow
        /// It wasn't open.
        case notOpen
    }

    /// Closes a notebook or PDF (for the study pal): its own window, if it
    /// has one; in the main window, it goes back to the library.
    func close(_ target: OpenTarget) -> Closed {
        if windowTargets.contains(target), let dismissWindow {
            dismissWindow(id: WindowID.item, value: target)
            return .window
        }
        if path.contains(target) {
            path = []
            return .mainWindow
        }
        return .notOpen
    }

    /// Brings the main window forward (or opens it again, if it was closed).
    func showMainWindow() {
        openWindow?(id: WindowID.main, value: MainWindow.main)
    }

    /// A notebook's or PDF's own window appeared. If the main window had it
    /// open too (a window iPadOS brought back), the main window lets go.
    func itemWindowAppeared(_ target: OpenTarget) {
        windowTargets.insert(target)
        if path.contains(target) { path = [] }
    }

    func itemWindowDisappeared(_ target: OpenTarget) {
        windowTargets.remove(target)
    }

    private func save() {
        if path.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(path) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
