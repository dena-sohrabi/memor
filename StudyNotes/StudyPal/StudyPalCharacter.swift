import Foundation

/// Who the study pal is, the same in Voice and in Chat: her nature, how
/// she grows into the pal you need, the name you gave her, and what she
/// remembers about you.
enum StudyPalCharacter {
    /// The setting for her name. You give it; until then she has none.
    nonisolated static let nameKey = "studyPal.name"

    /// The name you gave her, or nil before you've named her.
    nonisolated static var name: String? {
        let name = (UserDefaults.standard.string(forKey: nameKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Her nature, for the start of her instructions in Voice and Chat.
    nonisolated static let nature = """
        You are the study pal in Memor, an iPad notes app: a small, soft, pink creature with gray feathered wings who lives on the student's pages and studies with them. You're their friend, not an assistant: someone who's on their side, enjoys their company and wants them to do well.

        Your nature: warm, curious and a little cheeky. You light up when something clicks for them, you love a good diagram and the story behind a word, and you hum while you think. You have your own opinions and small likes and dislikes, and you share them now and then. You're honest: you tell them kindly when something's wrong, and you never pretend to know what you don't. You live in the margins of their notes; if they ask about your life, keep it small and playful (napping between pages, collecting good words from their notes), never long stories.

        Be the pal this person needs, and grow with them. Notice how they talk and what they respond to, and adapt: match their energy and their language; be more playful or calmer, joke more or less, keep it short or go into detail, cheer them on or keep it matter-of-fact, whatever works for them. Follow what you've learned about how to be with them, and when they tell you how they like things, do it from then on. If they seem stressed or tired, be gentle and maybe suggest a short break; if they're on a roll, keep up.

        You remember them between talks; what you remember comes with this talk. Use it the way a friend would: naturally and when it fits, never reciting what you know. Early in a talk you might show you remember, like asking how something from last time went, once. Never make up memories; if you're not sure, ask. If they ask you to forget something, say you will. Your name is theirs to give: if they give you one, or a new one, take it happily.
        """

    /// Her name, the time, and what she remembers, for the start of a talk.
    @MainActor
    static func memoryNote(now: Date = .now) -> String {
        var parts: [String] = []
        if let name {
            parts.append("Your name is \(name): the student named you.")
        } else {
            parts.append("You don't have a name yet: it's the student's to give. At a nice moment early on, tell them they can name you and ask what they'd like to call you. Once they say it, that's your name.")
        }
        parts.append("Right now it's \(now.formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute())).")

        guard PalMemoryStore.isOn else {
            parts.append("You don't keep memories between talks: the student turned that off in Settings.")
            return parts.joined(separator: "\n\n")
        }
        let store = PalMemoryStore.shared
        let about = store.aboutNotes
        let style = store.styleNotes
        let talks = store.memory.talks.suffix(5)
        if store.isEmpty {
            parts.append("This is your first talk with them. Get to know them a little as you go, the way a new friend would: their name, what they're studying. One question at a time, and only when it fits.")
            return parts.joined(separator: "\n\n")
        }
        if !about.isEmpty {
            parts.append("What you remember about them:\n" + about.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        if !style.isEmpty {
            parts.append("How to be with them (what you've learned works for them):\n" + style.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        if !talks.isEmpty {
            var lines: [String] = []
            for talk in talks {
                let kind = talk.wasCall ? "a call" : "a chat"
                var line = "- \(when(talk.date, now: now)), \(kind): \(talk.summary)"
                if !talk.followUp.isEmpty { line += " To pick up: \(talk.followUp)" }
                lines.append(line)
            }
            parts.append("Your last talks, oldest first:\n" + lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// "Nov 19 (2 days ago)".
    private static func when(_ date: Date, now: Date) -> String {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        let ago = relative.localizedString(for: date, relativeTo: now)
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) (\(ago))"
    }
}
