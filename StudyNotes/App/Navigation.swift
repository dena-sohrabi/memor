import Foundation
import Observation

/// A notebook or PDF to show.
enum OpenTarget: Codable, Hashable, Sendable {
    case notebook(UUID)
    case pdf(UUID)
}

/// Where Memor's one window is: the library, or a notebook or PDF opened
/// on top of it. Tapping a card, the study pal and "Open in Memor" all go
/// through here. What's open is kept on this iPad, so it comes back after
/// Memor is closed (by you, a crash, or iPadOS when memory runs low).
@MainActor
@Observable
final class AppNavigator {
    static let shared = AppNavigator()

    /// The library's navigation stack: empty for the library, or the one
    /// notebook or PDF that's open.
    var path: [OpenTarget] {
        didSet { save() }
    }

    private static let key = "navigation.open"

    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.key)
        path = saved.flatMap { try? JSONDecoder().decode([OpenTarget].self, from: $0) } ?? []
    }

    /// Shows a notebook or PDF in place of whatever is open. If it's
    /// already open, it stays as it is (on the page you were on).
    func open(_ target: OpenTarget) {
        guard path != [target] else { return }
        path = [target]
    }

    /// Back to the library.
    func showLibrary() {
        path = []
    }

    private func save() {
        if path.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(path) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
