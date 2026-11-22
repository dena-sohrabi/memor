import Foundation
import os

/// What the study pal remembers about you between talks, so she can be a
/// real friend:
/// - About you: your name, what you study, your exams, what's hard for you.
/// - How to be with you: the tone, humor and detail that work for you.
/// - Your last talks: what each was about, and what to pick up next time.
///
/// Kept only on this iPad. Settings → Memory shows all of it, and can
/// forget any of it or turn remembering off.
struct PalMemory: Codable, Equatable {
    struct Note: Codable, Equatable, Identifiable {
        enum Kind: String, Codable {
            /// Something about you.
            case about
            /// How to be with you.
            case style
        }

        var id = UUID()
        var kind: Kind
        var text: String
        var date: Date
    }

    /// One talk: a call in Voice mode, or a chat.
    struct Talk: Codable, Equatable, Identifiable {
        var id: UUID
        var date: Date
        var wasCall: Bool
        var summary: String
        /// Something to ask about or pick up next time.
        var followUp: String
    }

    var notes: [Note] = []
    var talks: [Talk] = []

    static let maxNotes = 60
    static let maxTalks = 40
}

/// One line of a talk, for writing down what to remember.
struct PalLine: Equatable {
    let isStudent: Bool
    let text: String
}

/// The study pal's memory, saved in a file in the app's own storage.
@MainActor
@Observable
final class PalMemoryStore {
    static let shared = PalMemoryStore()

    /// The setting for remembering talks; on unless turned off.
    nonisolated static let isOnKey = "studyPal.remembers"

    nonisolated static var isOn: Bool {
        UserDefaults.standard.object(forKey: isOnKey) as? Bool ?? true
    }

    private(set) var memory: PalMemory

    private init() {
        memory = Self.load()
    }

    var aboutNotes: [PalMemory.Note] { memory.notes.filter { $0.kind == .about } }
    var styleNotes: [PalMemory.Note] { memory.notes.filter { $0.kind == .style } }
    /// Newest first.
    var recentTalks: [PalMemory.Talk] { memory.talks.reversed() }
    var isEmpty: Bool { memory.notes.isEmpty && memory.talks.isEmpty }

    func deleteNote(_ id: PalMemory.Note.ID) {
        memory.notes.removeAll { $0.id == id }
        save()
    }

    func deleteTalk(_ id: PalMemory.Talk.ID) {
        memory.talks.removeAll { $0.id == id }
        save()
    }

    func forgetEverything() {
        memory = PalMemory()
        save()
    }

    /// Adds what she learned from a talk. A talk that's already remembered
    /// (a chat you reopened) gets its summary replaced.
    func apply(_ update: PalMemoryUpdate, keys: [String: PalMemory.Note.ID], talkID: UUID, wasCall: Bool, at date: Date) {
        let removed = Set(update.removed.compactMap { keys[$0] })
        memory.notes.removeAll { removed.contains($0.id) }
        for change in update.updated {
            guard let id = keys[change.key], let index = memory.notes.firstIndex(where: { $0.id == id }) else { continue }
            memory.notes[index].text = change.text
            memory.notes[index].date = date
        }
        for note in update.added {
            let isNew = !memory.notes.contains { $0.text.caseInsensitiveCompare(note.text) == .orderedSame }
            if isNew { memory.notes.append(PalMemory.Note(kind: note.kind, text: note.text, date: date)) }
        }
        if memory.notes.count > PalMemory.maxNotes {
            memory.notes.removeFirst(memory.notes.count - PalMemory.maxNotes)
        }

        if !update.summary.isEmpty {
            let talk = PalMemory.Talk(id: talkID, date: date, wasCall: wasCall, summary: update.summary, followUp: update.followUp)
            memory.talks.removeAll { $0.id == talkID }
            memory.talks.append(talk)
            if memory.talks.count > PalMemory.maxTalks {
                memory.talks.removeFirst(memory.talks.count - PalMemory.maxTalks)
            }
        }
        save()
    }

    // MARK: File

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "StudyPal/memory.json")
    }

    private static func load() -> PalMemory {
        guard let data = try? Data(contentsOf: fileURL),
              let memory = try? JSONDecoder().decode(PalMemory.self, from: data) else { return PalMemory() }
        return memory
    }

    private func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(memory)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            PalMemoryWriter.log.error("Couldn't save the study pal's memory.")
        }
    }
}

/// What she learned from one talk, as the model wrote it.
struct PalMemoryUpdate {
    var added: [(kind: PalMemory.Note.Kind, text: String)] = []
    /// Changed notes, by their key in the memory she was shown ("n3").
    var updated: [(key: String, text: String)] = []
    var removed: [String] = []
    var summary = ""
    var followUp = ""
    var newName = ""

    /// Reads the JSON reply, ignoring anything around it.
    init?(reply: String) {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func clean(_ value: Any?) -> String {
            String((value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        }
        for item in object["add"] as? [[String: Any]] ?? [] {
            let text = clean(item["text"])
            guard !text.isEmpty else { continue }
            let kind: PalMemory.Note.Kind = item["kind"] as? String == "style" ? .style : .about
            added.append((kind: kind, text: text))
        }
        for item in object["update"] as? [[String: Any]] ?? [] {
            let text = clean(item["text"])
            guard let key = item["id"] as? String, !text.isEmpty else { continue }
            updated.append((key: key, text: text))
        }
        removed = object["remove"] as? [String] ?? []
        summary = clean(object["summary"])
        followUp = clean(object["follow_up"])
        newName = String(clean(object["new_name"]).prefix(30))
    }
}

/// After a talk, writes down what's worth remembering: in Voice mode with
/// OpenAI's realtime model (as text), in Chat mode with Claude, so each
/// mode sends your talk only to the service you were already talking with.
@MainActor
enum PalMemoryWriter {
    /// Durations and outcomes only, never what was said.
    static let log = Logger(subsystem: "com.denasohrabi.memor", category: "memory")

    enum Service {
        case openAI, claude
    }

    /// Remembers a talk in the background. Does nothing when remembering
    /// is off or the student didn't say anything.
    static func remember(_ lines: [PalLine], talkID: UUID, wasCall: Bool, with service: Service) {
        guard PalMemoryStore.isOn, lines.contains(where: \.isStudent) else { return }
        switch service {
        case .openAI: guard OpenAIKeyStore.hasKey else { return }
        case .claude: guard APIKeyStore.hasKey else { return }
        }
        let date = Date.now
        let (input, keys) = request(for: lines, wasCall: wasCall, at: date)
        Task {
            let started = ContinuousClock.now
            do {
                let reply: String
                switch service {
                case .openAI: reply = try await OpenAIClient.writeText(instructions: prompt, input: input)
                case .claude: reply = try await askClaude(input)
                }
                guard let update = PalMemoryUpdate(reply: reply) else {
                    log.error("The memory reply wasn't JSON.")
                    return
                }
                PalMemoryStore.shared.apply(update, keys: keys, talkID: talkID, wasCall: wasCall, at: date)
                if !update.newName.isEmpty {
                    UserDefaults.standard.set(update.newName, forKey: StudyPalCharacter.nameKey)
                }
                let elapsed = ContinuousClock.now - started
                log.notice("Remembered a talk in \(elapsed.components.seconds, privacy: .public)s: \(update.added.count, privacy: .public) new, \(update.updated.count, privacy: .public) changed, \(update.removed.count, privacy: .public) removed")
                #if DEBUG
                print("[memory] remembered a talk in \(elapsed.components.seconds)s: \(update.added.count) new, \(update.updated.count) changed, \(update.removed.count) removed")
                #endif
            } catch {
                log.error("Couldn't remember a talk: \(error.localizedDescription, privacy: .public)")
                #if DEBUG
                print("[memory] couldn't remember a talk: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// What she remembers now (each note with a short key the model can
    /// point at) and the talk, newest part kept if it's long.
    private static func request(for lines: [PalLine], wasCall: Bool, at date: Date) -> (String, [String: PalMemory.Note.ID]) {
        let store = PalMemoryStore.shared
        var keys: [String: PalMemory.Note.ID] = [:]
        var remembered: [String] = []
        for (index, note) in store.memory.notes.enumerated() {
            let key = "n\(index + 1)"
            keys[key] = note.id
            remembered.append("[\(key)] (\(note.kind.rawValue)) \(note.text)")
        }
        let name = StudyPalCharacter.name ?? "The study pal"
        var talk: [String] = []
        var length = 0
        for line in lines.reversed() {
            let text = String(line.text.prefix(1_500))
            let entry = "\(line.isStudent ? "Student" : name): \(text)"
            length += entry.count
            if length > 14_000 { break }
            talk.append(entry)
        }
        let lastTalks = store.memory.talks.suffix(3).map { "- \($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.summary)" }
        let input = """
            Today is \(date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())).

            What she remembers now:
            \(remembered.isEmpty ? "(nothing yet)" : remembered.joined(separator: "\n"))

            Her last talks:
            \(lastTalks.isEmpty ? "(none yet)" : lastTalks.joined(separator: "\n"))

            The \(wasCall ? "voice call" : "chat") that just ended:
            \(talk.reversed().joined(separator: "\n"))
            """
        return (input, keys)
    }

    private static func askClaude(_ input: String) async throws -> String {
        let body: [String: Any] = [
            "model": ClaudeClient.voiceModel,
            "max_tokens": 2_048,
            "stream": true,
            "output_config": ["effort": "low"],
            "system": prompt,
            "messages": [["role": "user", "content": input]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        var reply = ""
        try await ClaudeClient.stream(body: data) { event in
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            reply += text
        }
        return reply
    }

    private static let prompt = """
        You keep the memory of a study pal: a small creature in the Memor notes app who studies with a student and is their friend. You get what she remembers now and the talk they just had. Write down what will help her be a better friend and study pal to this person next time.

        Reply with JSON only, no other text:
        {"add": [{"kind": "about", "text": "..."}], "update": [{"id": "n2", "text": "..."}], "remove": ["n5"], "summary": "...", "follow_up": "...", "new_name": ""}

        - "about" notes: what a good friend would remember: their name, what and where they study, upcoming exams and deadlines (with real dates, worked out from today's date), what they find hard or easy, their goals and interests, things they shared about their life, what she promised to help with, and running jokes.
        - "style" notes: how to be the best pal for them: the tone and humor they enjoy, how much detail they want, how they like things explained (examples first, step by step, analogies), how they like to be encouraged or corrected, and their language. Only what this talk showed, or what they asked for.
        - Each note is one short sentence in the third person ("Studies biology at university.", "Likes short answers with an example first.").
        - Don't add what's already remembered. Update a note that changed or got more precise, using its id. Remove notes that turned out wrong, that they asked her to forget, or that no longer matter. When something is past, update it ("Had a biology exam on November 20.") rather than keeping it as upcoming.
        - Never keep passwords, account or ID numbers, addresses, or anything they asked her not to remember. For sensitive things like health or family troubles, keep only what a caring friend would, in gentle words.
        - "summary": one or two sentences on what this talk was about and how it went, starting with the subject ("Biology: went over meiosis; crossing over finally clicked."). Empty if they didn't really talk.
        - "follow_up": one thing she could ask about or pick up next time, or empty.
        - "new_name": the name they gave her in this talk, if they named or renamed her; otherwise empty.
        - If nothing is worth remembering, use empty lists and strings.
        """
}
