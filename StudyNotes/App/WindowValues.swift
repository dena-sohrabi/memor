import Foundation

/// The value a document window is opened with. SwiftUI saves it for state
/// restoration, so open windows come back after a relaunch.
enum OpenTarget: Codable, Hashable, Sendable {
    case notebook(UUID)
    case pdf(UUID)
}

/// The library window's fixed value (see `StudyNotesApp`).
enum LibraryWindow: String, Codable, Hashable, Sendable {
    case main
}

enum WindowID {
    static let library = "library"
    static let item = "item"
}
