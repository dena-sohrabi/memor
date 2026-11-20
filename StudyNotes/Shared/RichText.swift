import UIKit

/// Stores styled text from a text box as `Data`.
///
/// A keyed archive keeps fonts and styles exactly. RTF would turn the system
/// font into Times on the way back.
enum RichText {
    static func encode(_ text: NSAttributedString) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: text, requiringSecureCoding: false)
    }

    static func decode(_ data: Data) -> NSAttributedString? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString
    }
}
