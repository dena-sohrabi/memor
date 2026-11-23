import Foundation
import os

/// What the study pal remembers between talks, in three layers, so she
/// knows what she needs and nothing that would get in the way:
/// - About you, and how to be with you: your name, what you study, your
///   exams, what helps you. Small, and part of every talk.
/// - Each notebook and PDF: what you're working on in it, what was hard,
///   what's left. Part of a talk only while that notebook or PDF is open.
/// - Your past talks: a line or two each. Never part of a talk on their
///   own; she looks them up (`recall`) when something calls for it.
///
/// Kept on the iPad and in your iCloud key-value storage, so it's the same
/// on all your iPads and comes back after a reinstall. Settings → Memory
/// shows all of it, and can forget any of it or turn remembering off.
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

    /// One talk, summed up.
    struct Talk: Codable, Equatable, Identifiable {
        var id: UUID
        var date: Date
        var summary: String
        /// Something to ask about or pick up next time.
        var followUp: String
        /// The notebooks and PDFs it was about.
        var items: [UUID] = []

        init(id: UUID, date: Date, summary: String, followUp: String, items: [UUID]) {
            self.id = id
            self.date = date
            self.summary = summary
            self.followUp = followUp
            self.items = items
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            date = try container.decode(Date.self, forKey: .date)
            summary = try container.decode(String.self, forKey: .summary)
            followUp = try container.decodeIfPresent(String.self, forKey: .followUp) ?? ""
            items = try container.decodeIfPresent([UUID].self, forKey: .items) ?? []
        }
    }

    /// What she knows about one notebook or PDF.
    struct Item: Codable, Equatable {
        struct Note: Codable, Equatable, Identifiable {
            var id = UUID()
            var text: String
            var date: Date
        }

        var title: String
        var notes: [Note] = []
        var lastStudied: Date?
    }

    var notes: [Note] = []
    var talks: [Talk] = []
    /// By the notebook's or PDF's id.
    var items: [UUID: Item] = [:]

    static let maxNotes = 60
    static let maxTalks = 200
    static let maxItemNotes = 12

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notes = try container.decodeIfPresent([Note].self, forKey: .notes) ?? []
        talks = try container.decodeIfPresent([Talk].self, forKey: .talks) ?? []
        items = try container.decodeIfPresent([UUID: Item].self, forKey: .items) ?? [:]
    }
}

/// One line of a talk, for writing down what to remember.
struct PalLine: Equatable {
    let isStudent: Bool
    let text: String
}

/// The study pal's memory, saved in a file in the app's own storage and in
/// iCloud key-value storage. The newest save, from any iPad, wins.
@MainActor
@Observable
final class PalMemoryStore {
    static let shared = PalMemoryStore()

    /// The setting for remembering talks; on unless turned off.
    nonisolated static let isOnKey = "studyPal.remembers"

    /// Her memory's key in iCloud key-value storage.
    nonisolated static let cloudKey = "studyPal.memory"

    nonisolated static var isOn: Bool {
        UserDefaults.standard.object(forKey: isOnKey) as? Bool ?? true
    }

    private(set) var memory: PalMemory

    private init() {
        let fromCloud = NSUbiquitousKeyValueStore.default.data(forKey: Self.cloudKey).flatMap(Self.decode)
        memory = fromCloud ?? Self.loadFile() ?? PalMemory()
        // Memory from before iCloud goes up the first time.
        if fromCloud == nil, memory != PalMemory() { save() }

        // Saved on another iPad, or iCloud's first download on this one.
        _ = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWithCloud() }
        }
    }

    var aboutNotes: [PalMemory.Note] { memory.notes.filter { $0.kind == .about } }
    var styleNotes: [PalMemory.Note] { memory.notes.filter { $0.kind == .style } }
    /// Newest first.
    var recentTalks: [PalMemory.Talk] { memory.talks.reversed() }
    var isEmpty: Bool { memory.notes.isEmpty && memory.talks.isEmpty && !memory.items.values.contains { !$0.notes.isEmpty } }

    /// Notebooks and PDFs she has notes about, most recently studied first.
    var itemsWithNotes: [(id: UUID, item: PalMemory.Item)] {
        memory.items.filter { !$0.value.notes.isEmpty }
            .map { (id: $0.key, item: $0.value) }
            .sorted { ($0.item.lastStudied ?? .distantPast) > ($1.item.lastStudied ?? .distantPast) }
    }

    func item(_ id: UUID) -> PalMemory.Item? { memory.items[id] }

    func deleteNote(_ id: PalMemory.Note.ID) {
        memory.notes.removeAll { $0.id == id }
        save()
    }

    func deleteTalk(_ id: PalMemory.Talk.ID) {
        memory.talks.removeAll { $0.id == id }
        save()
    }

    func deleteItemNote(_ noteID: PalMemory.Item.Note.ID, from itemID: UUID) {
        memory.items[itemID]?.notes.removeAll { $0.id == noteID }
        save()
    }

    func forgetEverything() {
        memory = PalMemory()
        save()
    }

    /// Something she was asked to remember, or decided to, in the middle
    /// of a talk. About an item when `itemID` is set.
    func remember(_ text: String, kind: PalMemory.Note.Kind, itemID: UUID?, itemTitle: String?, at date: Date = .now) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PalMemoryStore.isOn, !text.isEmpty else { return }
        if let itemID {
            addItemNote(text, to: itemID, title: itemTitle, at: date)
        } else if !memory.notes.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            memory.notes.append(PalMemory.Note(kind: kind, text: text, date: date))
            trimNotes()
        }
        save()
    }

    /// Notes the student studied an item now, so it sorts first.
    func studied(_ itemID: UUID, title: String, at date: Date = .now) {
        guard PalMemoryStore.isOn else { return }
        var item = memory.items[itemID] ?? PalMemory.Item(title: title)
        item.title = title
        item.lastStudied = date
        memory.items[itemID] = item
        save()
    }

    /// Talks and notes that match what she's looking for, best first.
    func recall(_ query: String, limit: Int = 6) -> [String] {
        let words = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        func score(_ text: String) -> Int {
            let lowered = text.lowercased()
            return words.reduce(0) { $0 + (lowered.contains($1) ? 1 : 0) }
        }
        var found: [(score: Int, date: Date, text: String)] = []
        for talk in memory.talks {
            let titles = talk.items.compactMap { memory.items[$0]?.title }.joined(separator: ", ")
            let text = talk.summary + (talk.followUp.isEmpty ? "" : " To pick up: \(talk.followUp)") + (titles.isEmpty ? "" : " (in \(titles))")
            let points = words.isEmpty ? 1 : score(text)
            if points > 0 { found.append((points, talk.date, "Talk on \(talk.date.formatted(date: .abbreviated, time: .shortened)): \(text)")) }
        }
        for (_, item) in memory.items {
            for note in item.notes {
                let text = "About “\(item.title)”: \(note.text)"
                let points = words.isEmpty ? 0 : score(text)
                if points > 0 { found.append((points, note.date, text)) }
            }
        }
        return found.sorted { ($0.score, $0.date) > ($1.score, $1.date) }.prefix(limit).map(\.text)
    }

    /// Adds what she learned from a talk. A talk that's already remembered
    /// (one that went on) gets its summary replaced.
    func apply(_ update: PalMemoryUpdate, keys: PalMemoryKeys, talkID: UUID, at date: Date) {
        let removed = Set(update.removed.compactMap { keys.notes[$0] })
        memory.notes.removeAll { removed.contains($0.id) }
        for change in update.updated {
            guard let id = keys.notes[change.key], let index = memory.notes.firstIndex(where: { $0.id == id }) else { continue }
            memory.notes[index].text = change.text
            memory.notes[index].date = date
        }
        for note in update.added where !memory.notes.contains(where: { $0.text.caseInsensitiveCompare(note.text) == .orderedSame }) {
            memory.notes.append(PalMemory.Note(kind: note.kind, text: note.text, date: date))
        }
        trimNotes()

        for key in update.removedItemNotes {
            guard let found = keys.itemNotes[key] else { continue }
            memory.items[found.0]?.notes.removeAll { $0.id == found.1 }
        }
        for change in update.updatedItemNotes {
            guard let found = keys.itemNotes[change.key],
                  let index = memory.items[found.0]?.notes.firstIndex(where: { $0.id == found.1 }) else { continue }
            memory.items[found.0]?.notes[index].text = change.text
            memory.items[found.0]?.notes[index].date = date
        }
        for note in update.addedItemNotes {
            guard let item = keys.items[note.item] else { continue }
            addItemNote(note.text, to: item.id, title: item.title, at: date)
        }

        if !update.summary.isEmpty {
            let talk = PalMemory.Talk(id: talkID, date: date, summary: update.summary, followUp: update.followUp, items: keys.items.values.map { $0.id })
            memory.talks.removeAll { $0.id == talkID }
            memory.talks.append(talk)
            if memory.talks.count > PalMemory.maxTalks {
                memory.talks.removeFirst(memory.talks.count - PalMemory.maxTalks)
            }
        }
        save()
    }

    private func addItemNote(_ text: String, to itemID: UUID, title: String?, at date: Date) {
        var item = memory.items[itemID] ?? PalMemory.Item(title: title ?? "Untitled")
        if let title { item.title = title }
        guard !item.notes.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { return }
        item.notes.append(PalMemory.Item.Note(text: text, date: date))
        if item.notes.count > PalMemory.maxItemNotes {
            item.notes.removeFirst(item.notes.count - PalMemory.maxItemNotes)
        }
        memory.items[itemID] = item
    }

    private func trimNotes() {
        if memory.notes.count > PalMemory.maxNotes {
            memory.notes.removeFirst(memory.notes.count - PalMemory.maxNotes)
        }
    }

    // MARK: File

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "StudyPal/memory.json")
    }

    /// iCloud key-value storage holds 1 MB in all, and the settings need a
    /// little of it.
    private static let cloudLimit = 900_000

    private nonisolated static func decode(_ data: Data) -> PalMemory? {
        try? JSONDecoder().decode(PalMemory.self, from: data)
    }

    private static func loadFile() -> PalMemory? {
        (try? Data(contentsOf: fileURL)).flatMap(decode)
    }

    private func syncWithCloud() {
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: Self.cloudKey), let fromCloud = Self.decode(data) {
            guard fromCloud != memory else { return }
            memory = fromCloud
            writeFile(data)
        } else if memory != PalMemory() {
            // iCloud has none: iCloud drops what's saved before its first
            // download on an iPad, so save it again.
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(memory) else {
            PalMemoryWriter.log.error("Couldn't save the study pal's memory.")
            return
        }
        writeFile(data)
        if data.count <= Self.cloudLimit {
            NSUbiquitousKeyValueStore.default.set(data, forKey: Self.cloudKey)
        } else {
            PalMemoryWriter.log.error("The study pal's memory is too big for iCloud, so it's saved only on this iPad.")
        }
    }

    private func writeFile(_ data: Data) {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            PalMemoryWriter.log.error("Couldn't save the study pal's memory.")
        }
    }
}

/// The short keys the memory model points at ("n3", "m2", "i1"), and what
/// they stand for.
struct PalMemoryKeys {
    var notes: [String: PalMemory.Note.ID] = [:]
    var itemNotes: [String: (UUID, PalMemory.Item.Note.ID)] = [:]
    var items: [String: (id: UUID, title: String)] = [:]
}

/// What she learned from one talk, as the model wrote it.
struct PalMemoryUpdate {
    var added: [(kind: PalMemory.Note.Kind, text: String)] = []
    /// Changed notes, by their key in the memory she was shown ("n3").
    var updated: [(key: String, text: String)] = []
    var removed: [String] = []
    var addedItemNotes: [(item: String, text: String)] = []
    var updatedItemNotes: [(key: String, text: String)] = []
    var removedItemNotes: [String] = []
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
        for item in object["add_item_notes"] as? [[String: Any]] ?? [] {
            let text = clean(item["text"])
            guard let key = item["item"] as? String, !text.isEmpty else { continue }
            addedItemNotes.append((item: key, text: text))
        }
        for item in object["update_item_notes"] as? [[String: Any]] ?? [] {
            let text = clean(item["text"])
            guard let key = item["id"] as? String, !text.isEmpty else { continue }
            updatedItemNotes.append((key: key, text: text))
        }
        removedItemNotes = object["remove_item_notes"] as? [String] ?? []
        summary = clean(object["summary"])
        followUp = clean(object["follow_up"])
        newName = String(clean(object["new_name"]).prefix(30))
    }
}

/// After a talk, writes down what's worth remembering, in the background,
/// with a quick model from the same company as her mind: Claude Haiku 5.5
/// or GPT-6 Luna.
@MainActor
enum PalMemoryWriter {
    /// Durations and outcomes only, never what was said.
    static let log = Logger(subsystem: "com.denasohrabi.memor", category: "memory")

    /// Remembers a talk in the background. Does nothing when remembering
    /// is off or the student didn't say anything. `items` are the
    /// notebooks and PDFs it was about, by id, with their titles.
    static func remember(_ lines: [PalLine], talkID: UUID, items: [UUID: String], mind: PalMind) {
        guard PalMemoryStore.isOn, mind.hasKey, lines.contains(where: \.isStudent) else { return }
        let date = Date.now
        let (input, keys) = request(for: lines, items: items, at: date)
        Task {
            let started = ContinuousClock.now
            do {
                let reply: String
                switch mind {
                case .claude:
                    reply = try await askClaude(input)
                case .openAI:
                    reply = try await OpenAIClient.respond(body: [
                        "model": OpenAIClient.choresModel,
                        "instructions": prompt,
                        "input": input,
                        "reasoning": ["effort": "low"],
                        "max_output_tokens": 4_000,
                        "store": false,
                    ])
                }
                guard let update = PalMemoryUpdate(reply: reply) else {
                    log.error("The memory reply wasn't JSON.")
                    return
                }
                PalMemoryStore.shared.apply(update, keys: keys, talkID: talkID, at: date)
                if !update.newName.isEmpty {
                    UserDefaults.standard.set(update.newName, forKey: StudyPalCharacter.nameKey)
                }
                let elapsed = ContinuousClock.now - started
                log.notice("Remembered a talk in \(elapsed.components.seconds, privacy: .public)s: \(update.added.count + update.addedItemNotes.count, privacy: .public) new, \(update.updated.count + update.updatedItemNotes.count, privacy: .public) changed")
            } catch {
                log.error("Couldn't remember a talk: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// What she remembers now (each note with a short key the model can
    /// point at), the notebooks and PDFs the talk was about, and the talk,
    /// newest part kept if it's long.
    private static func request(for lines: [PalLine], items: [UUID: String], at date: Date) -> (String, PalMemoryKeys) {
        let store = PalMemoryStore.shared
        var keys = PalMemoryKeys()
        var remembered: [String] = []
        for (index, note) in store.memory.notes.enumerated() {
            let key = "n\(index + 1)"
            keys.notes[key] = note.id
            remembered.append("[\(key)] (\(note.kind.rawValue)) \(note.text)")
        }
        var itemLines: [String] = []
        var noteNumber = 0
        for (index, entry) in items.sorted(by: { $0.value < $1.value }).enumerated() {
            let key = "i\(index + 1)"
            keys.items[key] = (id: entry.key, title: entry.value)
            itemLines.append("[\(key)] “\(entry.value)”")
            for note in store.item(entry.key)?.notes ?? [] {
                noteNumber += 1
                let noteKey = "m\(noteNumber)"
                keys.itemNotes[noteKey] = (entry.key, note.id)
                itemLines.append("    [\(noteKey)] \(note.text)")
            }
        }
        let name = StudyPalCharacter.name ?? "The study pal"
        var talk: [String] = []
        var length = 0
        for line in lines.reversed() {
            let text = String(line.text.prefix(1_500))
            let entry = "\(line.isStudent ? "Student" : name): \(text)"
            length += entry.count
            if length > 16_000 { break }
            talk.append(entry)
        }
        let input = """
            Today is \(date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())).

            What she remembers about the student:
            \(remembered.isEmpty ? "(nothing yet)" : remembered.joined(separator: "\n"))

            The notebooks and PDFs this talk was about, with what she remembers about each:
            \(itemLines.isEmpty ? "(none: the student was in the library)" : itemLines.joined(separator: "\n"))

            The talk:
            \(talk.reversed().joined(separator: "\n"))
            """
        return (input, keys)
    }

    private static func askClaude(_ input: String) async throws -> String {
        var reply = ""
        try await ClaudeClient.stream(body: [
            "model": ClaudeClient.choresModel,
            "max_tokens": 8_000,
            "output_config": ["effort": "low"],
            "system": prompt,
            "messages": [["role": "user", "content": input]],
        ]) { event in
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            reply += text
        }
        return reply
    }

    private static let prompt = """
        You keep the memory of a study pal: a small creature in the Memor notes app who studies with a student and is their friend. You get what she remembers now, the notebooks and PDFs the talk was about, and the talk. Write down what will help her be a better friend and study pal to this person later.

        Reply with JSON only, no other text:
        {"add": [{"kind": "about", "text": "..."}], "update": [{"id": "n2", "text": "..."}], "remove": ["n5"], "add_item_notes": [{"item": "i1", "text": "..."}], "update_item_notes": [{"id": "m1", "text": "..."}], "remove_item_notes": ["m3"], "summary": "...", "follow_up": "...", "new_name": ""}

        - "about" notes: what a good friend would remember about the person, whatever they're studying: their name, what and where they study, upcoming exams and deadlines (with real dates, worked out from today's date), their goals, what they shared about their life, running jokes.
        - "style" notes: how to be the best pal for them: the tone and humor they enjoy, how much detail they want, how they like things explained, how they like to be encouraged or corrected, and their language. Only what this talk showed, or what they asked for.
        - Item notes ("add_item_notes", by the item's key): what she should know next time that notebook or PDF is open: what it covers, where the student is in it, what they found hard or got wrong, what they still want to do. Facts about one subject go here, not in "about" notes.
        - Each note is one short sentence in the third person ("Studies biology at university.", "Gets dominant and recessive alleles mixed up.").
        - Don't add what's already remembered. Update a note that changed or got more precise, using its id. Remove notes that turned out wrong, that they asked her to forget, or that no longer matter. When something is past, update it ("Had a biology exam on November 20.").
        - Never keep passwords, account or ID numbers, addresses, or anything they asked her not to remember. For sensitive things like health or family troubles, keep only what a caring friend would, in gentle words.
        - "summary": one or two sentences on what this talk was about, starting with the subject ("Genetics: went over Mendel's laws; dominance finally clicked."). Empty if they didn't really talk.
        - "follow_up": one thing she could pick up next time, or empty.
        - "new_name": the name they gave her in this talk, if they named or renamed her; otherwise empty.
        - If nothing is worth remembering, use empty lists and strings.
        """
}
