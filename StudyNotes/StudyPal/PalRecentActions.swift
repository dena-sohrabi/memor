import Foundation

/// What the study pal did lately: on pages (what she added, wrote, marked,
/// moved, colored, with ids and places) and in the library. Kept across
/// talks while Memor runs, and listed at the top of each message, so when
/// you say "make it green" a while later, after working on the page
/// yourself, she still knows what "it" is.
@MainActor
final class PalRecentActions {
    static let shared = PalRecentActions()

    private struct Entry {
        let date: Date
        let text: String
    }

    private var entries: [Entry] = []

    /// Older than this, it's no longer "lately".
    private static let keepFor: TimeInterval = 3 * 60 * 60
    /// How many go with each message.
    private static let shown = 10

    private init() {}

    func record(_ text: String) {
        entries.append(Entry(date: .now, text: text))
        prune()
    }

    /// The latest, oldest first, for the top of a message. Empty if none.
    func summary(now: Date = .now) -> String {
        prune()
        let latest = entries.suffix(Self.shown)
        guard !latest.isEmpty else { return "" }
        let lines = latest.map { "- \(Self.ago($0.date, now: now)): \($0.text)" }
        let heading = "What you did lately, oldest first. Ids stay the same when they move or edit things themselves; get_page_items shows where things are now. When they say “it” or “that” about something you made, they most likely mean the last of these:"
        return ([heading] + lines).joined(separator: "\n")
    }

    private func prune() {
        let cutoff = Date.now.addingTimeInterval(-Self.keepFor)
        entries.removeAll { $0.date < cutoff }
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "just now"
        case 1: return "a minute ago"
        case ..<60: return "\(minutes) minutes ago"
        default: return "\(minutes / 60) h \(minutes % 60) min ago"
        }
    }
}
