import CoreGraphics
import Foundation

/// What Claude can do on the page it's helping with. Notebook pages and
/// PDFs both provide this; every change goes through the page's own undo.
///
/// Coordinates are page points: x grows to the right, y grows down.
/// Ink (handwriting) is never moved or changed; only typed text and images.
@MainActor
protocol AskPageActions: AnyObject {
    /// Notebook pages take images; PDFs don't.
    var canAddImages: Bool { get }

    /// Changes whenever the page does (or, in a PDF, when you turn to
    /// another page), so the study pal knows when to take a fresh look.
    var askPageVersion: Int { get }

    /// A JSON description of the page: the visible area and every text box
    /// and image with its id, position and size.
    func askPageItems() -> String

    /// The typed notes on the page, top to bottom, so what Claude writes
    /// can follow how they're written. Empty when there are none.
    func askPageNotes() -> String

    /// Adds a text box near what was circled, or in view, in the page's
    /// own text style. Returns its id.
    func askAddText(_ text: String) -> UUID?
    /// Adds an image near what was circled, or in view. Returns its id.
    func askAddImage(_ image: PreparedImage) -> UUID?

    // Each returns nil on success, or a short reason it couldn't.
    func askMoveItem(_ id: UUID, to origin: CGPoint) -> String?
    func askResizeItem(_ id: UUID, width: CGFloat) -> String?
    func askEditText(_ id: UUID, text: String) -> String?
    func askDeleteItem(_ id: UUID) -> String?
}

extension AskPageActions {
    /// Turns a page description into the JSON Claude reads.
    func askJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
