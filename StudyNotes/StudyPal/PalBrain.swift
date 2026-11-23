import UIKit

/// Which model is the study pal's mind. Chosen in Settings; a talk keeps
/// the mind it started with.
enum PalMind: String, CaseIterable, Identifiable {
    /// Claude Opus 5.5, with your Anthropic key.
    case claude
    /// GPT-6.2 Sol, with your OpenAI key.
    case openAI = "openai"

    nonisolated static let settingKey = "studyPal.mind"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Opus 5.5"
        case .openAI: "GPT-6.2 Sol"
        }
    }

    var hasKey: Bool {
        switch self {
        case .claude: APIKeyStore.hasKey
        case .openAI: OpenAIKeyStore.hasKey
        }
    }

    /// The mind chosen in Settings (Claude unless changed), or the other
    /// one when only its key is there. Nil without any key.
    static var current: PalMind? {
        let chosen = PalMind(rawValue: UserDefaults.standard.string(forKey: settingKey) ?? "") ?? .claude
        if chosen.hasKey { return chosen }
        let other: PalMind = chosen == .claude ? .openAI : .claude
        return other.hasKey ? other : nil
    }
}

/// The study pal's mind: one conversation for the whole app, whether you
/// type to her or talk, in any window, with Claude Opus 5.5 or GPT-6.2 Sol.
///
/// Every message you send starts with what's on your screen right then:
/// the notebooks and PDFs open in your windows, pictures of what's on
/// screen (when a page changed since she last saw it), their text, what
/// you selected or circled, and what she remembers about them. So she
/// always answers about what you're doing now, and the conversation itself
/// is there for continuity. After half an hour without a message, a new
/// talk starts; what mattered in the old one goes into her memory.
///
/// A talk's instructions and tools are fixed when it starts, and its
/// history is only ever added to, kept exactly as it came back (thinking
/// and tool calls included), as both APIs need.
@MainActor
@Observable
final class PalBrain {
    struct Message: Identifiable, Equatable {
        enum Role { case student, pal }
        let id = UUID()
        let role: Role
        var text: String
        /// What was circled with it (JPEG).
        var circled: Data?
        var wasSpoken = false
    }

    private(set) var messages: [Message] = []
    private(set) var isWorking = false
    /// What she's doing with a tool right now ("Creating an image…").
    private(set) var status: PalActivity?
    private(set) var errorText: String?
    private(set) var canRetry = false
    /// Goes up each time she changes a page, so she can be pleased.
    private(set) var pageChanges = 0
    /// Goes up each time she finishes a reply.
    private(set) var finishedReplies = 0
    /// Options waiting for you to pick one.
    private(set) var pendingChoice: PalChoice?

    /// She's writing her reply, rather than thinking or using a tool.
    var isAnswering: Bool {
        guard isWorking, status == nil, let last = messages.last, last.role == .pal else { return false }
        return !last.text.isEmpty
    }

    /// Her reply so far as it streams in, and whether it's complete.
    @ObservationIgnored var onReply: ((_ text: String, _ isComplete: Bool) -> Void)?
    /// She stopped writing to use her tools, with her reply so far, so a
    /// line like "Drawing it now." can be said before the tools run.
    @ObservationIgnored var onPause: ((_ text: String) -> Void)?

    /// What stays the same for a whole talk.
    private struct Talk {
        var id = UUID()
        var mind: PalMind?
        var instructions = ""
        /// In the mind's own format.
        var tools: [[String: Any]] = []
        /// The notebooks and PDFs it was about, for her memory.
        var items: [UUID: String] = [:]
        /// How many messages you've sent in it.
        var userTurns = 0
        /// Which version of each page she last saw a picture of, and in
        /// which of your messages.
        var seen: [UUID: (version: Int, turn: Int)] = [:]
    }

    /// A message to send again with Try Again.
    private struct Retry {
        let text: String
        let circle: PalCircle?
        let spoken: Bool
    }

    /// A tool she called.
    private struct Call {
        let id: String
        let name: String
        let arguments: String
        /// Arguments that weren't valid JSON, to tell her so.
        var invalid: String?
    }

    /// One response: what goes into the history, the tools to run, and
    /// whether to carry on without them (a paused web search).
    private struct Round {
        var items: [[String: Any]]
        var calls: [Call]
        var note: String?
        var goOn = false
    }

    @ObservationIgnored private var history: [[String: Any]] = []
    @ObservationIgnored private var talk = Talk()
    @ObservationIgnored private var lastMessageAt = Date.distantPast
    /// How many messages were in the talk when she last wrote it down.
    @ObservationIgnored private var rememberedCount = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The turn that's running. A turn whose id is no longer this one
    /// (stopped, or a new topic) leaves everything alone.
    @ObservationIgnored private var turnID = UUID()
    @ObservationIgnored private var pendingRetry: Retry?
    @ObservationIgnored private var choiceAnswer: CheckedContinuation<String, Never>?

    private static let maxToolRounds = 20
    private static let newTalkAfter: TimeInterval = 30 * 60
    /// With GPT, pictures stay in the last this many of your messages.
    private static let turnsWithPictures = 2

    // MARK: Talking

    /// Sends what you said or typed, with what you circled. `spoken`: you
    /// said it out loud, so she answers the way she would out loud.
    func send(_ text: String, circle: PalCircle? = nil, spoken: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || circle != nil else { return }
        if pendingChoice != nil, circle == nil {
            answerChoice(saying: text)
            return
        }
        guard !isWorking else { return }
        if !history.isEmpty, Date.now.timeIntervalSince(lastMessageAt) > Self.newTalkAfter {
            startNewTalk()
        }
        if history.isEmpty { beginTalk() }
        errorText = nil
        canRetry = false
        pendingRetry = nil
        guard let mind = talk.mind else {
            errorText = "I need an API key to think. Add one in Settings."
            return
        }
        lastMessageAt = .now

        messages.append(Message(role: .student, text: text, circled: circle?.image, wasSpoken: spoken))
        let before = talk
        talk.userTurns += 1
        let parts = content(for: text, circle: circle, spoken: spoken)
        let historyCount = history.count
        history.append(Self.userMessage(parts, for: mind))
        messages.append(Message(role: .pal, text: "", wasSpoken: spoken))
        let replyID = messages[messages.count - 1].id
        isWorking = true
        let token = UUID()
        turnID = token
        // Claude keeps one effort for the whole talk, so its cache stays warm.
        let effort = mind == .claude ? "medium" : (spoken ? "medium" : "high")
        let retry = Retry(text: text, circle: circle, spoken: spoken)
        task = Task { [weak self] in
            await self?.runTurn(token: token, replyID: replyID, historyCount: historyCount, before: before, retry: retry, effort: effort, circle: circle)
        }
    }

    /// Stops her answer.
    func cancel() {
        resolveChoice("They stopped you before choosing.")
        task?.cancel()
    }

    func retry() {
        guard let pendingRetry, !isWorking else { return }
        self.pendingRetry = nil
        // The message that failed is still showing; it's sent again.
        if let index = messages.lastIndex(where: { $0.role == .student }) {
            messages.remove(at: index)
        }
        send(pendingRetry.text, circle: pendingRetry.circle, spoken: pendingRetry.spoken)
    }

    /// The message Try Again would send, so its reply can be read aloud.
    var retryIsSpoken: Bool { pendingRetry?.spoken ?? false }

    /// Starts afresh: what mattered goes into her memory, and the next
    /// message begins a new talk.
    func startNewTalk() {
        rememberTalk()
        resolveChoice("They started a new topic.")
        task?.cancel()
        task = nil
        turnID = UUID()
        history = []
        messages = []
        talk = Talk()
        rememberedCount = 0
        errorText = nil
        canRetry = false
        pendingRetry = nil
        isWorking = false
        status = nil
    }

    /// Fixes the mind, instructions and tools for a new talk.
    private func beginTalk() {
        let mind = PalMind.current
        let canDraw = OpenAIKeyStore.hasKey
        let definitions = PalTools.definitions(canDraw: canDraw)
        talk.mind = mind
        talk.instructions = StudyPalCharacter.instructions(canDraw: canDraw)
        talk.tools = mind == .claude ? Self.claudeTools(definitions) : definitions
    }

    /// Writes down what's worth remembering from the talk so far (in the
    /// background), if there's anything new since last time.
    func rememberTalk() {
        guard messages.count > rememberedCount, messages.contains(where: { $0.role == .student }) else { return }
        rememberedCount = messages.count
        let lines = messages.compactMap { message -> PalLine? in
            var text = message.text
            if message.circled != nil { text = "(circled part of a page) " + text }
            guard !text.isEmpty else { return nil }
            return PalLine(isStudent: message.role == .student, text: text)
        }
        PalMemoryWriter.remember(lines, talkID: talk.id, items: talk.items, mind: talk.mind ?? PalMind.current ?? .openAI)
    }

    // MARK: Choices

    func choose(_ option: PalChoice.Option) {
        resolveChoice("They chose option \(option.id + 1): \(option.label)")
    }

    func answerChoice(saying text: String) {
        resolveChoice("Instead of choosing, they said: \(text)")
    }

    func dismissChoice() {
        resolveChoice("They closed the options without choosing.")
    }

    private func resolveChoice(_ answer: String) {
        guard let choiceAnswer else { return }
        self.choiceAnswer = nil
        pendingChoice = nil
        choiceAnswer.resume(returning: answer)
    }

    private func offerChoices(question: String, options: [PalChoice.Option]) async -> String {
        guard !Task.isCancelled else { return "They stopped you before choosing." }
        resolveChoice("They closed the options without choosing.")
        return await withCheckedContinuation { continuation in
            choiceAnswer = continuation
            pendingChoice = PalChoice(question: question, options: options)
        }
    }

    // MARK: What's on screen

    private enum Part {
        case text(String)
        case image(Data, detail: String)
    }

    /// Your message, after what's on your screen right now.
    private func content(for text: String, circle: PalCircle?, spoken: Bool) -> [Part] {
        let workspace = PalWorkspace.shared
        let pages = Array(workspace.visiblePages.prefix(3))
        let focused = workspace.focusedPage
        var parts: [Part] = []
        var overview = ["What's on their screen at \(Date.now.formatted(date: .omitted, time: .shortened)):"]

        if pages.isEmpty {
            overview.append("No notebook or PDF page is open: they're in the library, or a notebook's page grid.")
            let library = PalLibrary.overview()
            if !library.isEmpty { overview.append(library) }
        } else {
            if focused == nil { overview.append("They're in another window right now (the library or a page grid).") }
            for page in pages {
                let role = page === focused ? "the window they're using" : "another window on screen"
                let kind = page.palKind == .notebook ? "notebook" : "PDF"
                overview.append("- \(workspace.shortID(of: page)), \(role): \(kind) “\(page.palItemTitle)” (item_id \(page.palItemID.uuidString)), \(page.palWhere).")
                talk.items[page.palItemID] = page.palItemTitle
            }
            if let focused { PalMemoryStore.shared.studied(focused.palItemID, title: focused.palItemTitle) }
        }
        parts.append(.text(overview.joined(separator: "\n")))

        for page in pages {
            let name = workspace.shortID(of: page)
            let isFocused = page === focused || (focused == nil && page === pages.first)
            let snapshot = page.palSnapshot()
            var notes: [String] = []
            if hasSeen(page) {
                notes.append("\(name) looks the same as when you last saw it.")
            } else {
                talk.seen[page.palPageID] = (page.palVersion, talk.userTurns)
                if let image = snapshot.image {
                    let area = snapshot.area
                    notes.append("\(name) on screen: the picture below shows page points x \(Int(area.minX))–\(Int(area.maxX)), y \(Int(area.minY))–\(Int(area.maxY)) (\(Int(snapshot.imageSize.width))×\(Int(snapshot.imageSize.height)) pixels).")
                    parts.append(.text(notes.joined(separator: "\n")))
                    parts.append(.image(image, detail: isFocused ? "high" : "auto"))
                    notes = []
                } else {
                    notes.append("\(name) is empty on screen.")
                }
                let text = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let limit = isFocused ? 8_000 : 2_500
                    notes.append("Text on \(name):\n" + String(text.prefix(limit)))
                }
            }
            if let selection = snapshot.selection?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty {
                notes.append("Text they selected on \(name): “\(String(selection.prefix(3_000)))”")
            }
            if PalMemoryStore.isOn, let item = PalMemoryStore.shared.item(page.palItemID), !item.notes.isEmpty {
                notes.append("What you remember about “\(page.palItemTitle)”:\n" + item.notes.map { "- \($0.text)" }.joined(separator: "\n"))
            }
            if !notes.isEmpty { parts.append(.text(notes.joined(separator: "\n\n"))) }
        }

        if let circle {
            let page = workspace.page(id: circle.pageID)
            let name = page.map { workspace.shortID(of: $0) } ?? "their page"
            let onPage = circle.pageIndex.map { ", PDF page \($0 + 1)" } ?? ""
            let rect = circle.rect
            parts.append(.text("They circled this on \(name)\(onPage), at page points x \(Int(rect.minX)), y \(Int(rect.minY)), width \(Int(rect.width)), height \(Int(rect.height)):"))
            parts.append(.image(circle.image, detail: "high"))
        }

        var said = text.isEmpty ? "(They circled this without saying anything.)" : text
        if spoken { said = "(said out loud) " + said }
        parts.append(.text("Their message: " + said))
        return parts
    }

    /// She saw this version of the page, and the picture is still in what
    /// she reads (with GPT, older pictures are left out).
    private func hasSeen(_ page: PalPage) -> Bool {
        guard let seen = talk.seen[page.palPageID], seen.version == page.palVersion else { return false }
        if talk.mind == .openAI, talk.userTurns - seen.turn >= Self.turnsWithPictures { return false }
        return true
    }

    // MARK: A turn

    /// One answer: stream her reply, run any tools she calls, and go on
    /// until she's done.
    private func runTurn(token: UUID, replyID: Message.ID, historyCount: Int, before: Talk, retry: Retry, effort: String, circle: PalCircle?) async {
        defer {
            if turnID == token {
                isWorking = false
                status = nil
                task = nil
            }
        }
        let context = PalTools.Context(circle: circle) { [weak self] question, options in
            await self?.offerChoices(question: question, options: options) ?? "They closed the options."
        }
        var earlier = ""
        var rounds = 0
        /// Where the history is complete: after your message, or after the
        /// last tool results.
        var settled = historyCount
        while true {
            let round: Round
            do {
                round = try await respond(effort: effort) { [weak self] text in
                    self?.setReply(Self.joined(earlier, text), id: replyID)
                }
            } catch {
                guard turnID == token else { return }
                if Task.isCancelled || error is CancellationError {
                    stop(replyID: replyID, settled: settled, historyCount: historyCount, before: before)
                } else {
                    fail(error.localizedDescription, replyID: replyID, settled: settled, historyCount: historyCount, before: before, retry: retry)
                }
                return
            }
            guard turnID == token else { return }
            if Task.isCancelled {
                stop(replyID: replyID, settled: settled, historyCount: historyCount, before: before)
                return
            }
            history.append(contentsOf: round.items)
            earlier = reply(replyID)
            if let note = round.note {
                setReply(Self.joined(earlier, note), id: replyID)
                earlier = reply(replyID)
            }

            if round.calls.isEmpty {
                if round.goOn, rounds < Self.maxToolRounds {
                    rounds += 1
                    settled = history.count
                    continue
                }
                break
            }
            rounds += 1
            var outputs: [(call: Call, outcome: PalTools.Outcome)] = []
            if rounds > Self.maxToolRounds {
                // Every call still gets an answer, so the history stays valid.
                outputs = round.calls.map { (call: $0, outcome: PalTools.Outcome.text("Not run: this answer took too many steps. Tell them what you did so far.", isError: true)) }
                history.append(contentsOf: toolResults(outputs))
                setReply(Self.joined(earlier, "(That took me too many steps. Ask me to go on.)"), id: replyID)
                break
            }
            for call in round.calls {
                if Task.isCancelled {
                    stop(replyID: replyID, settled: settled, historyCount: historyCount, before: before)
                    return
                }
                status = PalTools.status(for: call.name)
                let outcome: PalTools.Outcome
                if let invalid = call.invalid {
                    outcome = .text("INVALID_JSON: \(invalid.prefix(500)). Send the call again with valid JSON.", isError: true)
                } else {
                    outcome = await PalTools.run(name: call.name, arguments: call.arguments, context: context)
                }
                guard turnID == token else { return }
                if outcome.changedPage { pageChanges += 1 }
                outputs.append((call: call, outcome: outcome))
            }
            history.append(contentsOf: toolResults(outputs))
            settled = history.count
            status = nil
            if Task.isCancelled {
                stop(replyID: replyID, settled: settled, historyCount: historyCount, before: before)
                return
            }
        }
        finishedReplies += 1
        onReply?(reply(replyID), true)
        if messages.count - rememberedCount >= 12 { rememberTalk() }
    }

    /// Streams one response from the talk's mind.
    private func respond(effort: String, onText: (String) -> Void) async throws -> Round {
        switch talk.mind {
        case .claude: try await respondWithClaude(effort: effort, onText: onText)
        case .openAI, nil: try await respondWithGPT(effort: effort, onText: onText)
        }
    }

    // MARK: GPT

    private func respondWithGPT(effort: String, onText: (String) -> Void) async throws -> Round {
        let body: [String: Any] = [
            "model": OpenAIClient.brainModel,
            "instructions": talk.instructions,
            "input": prunedHistory(),
            "tools": talk.tools,
            "tool_choice": "auto",
            "reasoning": ["effort": effort],
            "max_output_tokens": 32_000,
            "store": false,
            "include": ["reasoning.encrypted_content"],
        ]
        var items: [Int: [String: Any]] = [:]
        var final: [String: Any]?
        var text = ""
        try await OpenAIClient.streamResponse(body: body) { [weak self] event in
            switch event["type"] as? String {
            case "response.output_item.added":
                guard let item = event["item"] as? [String: Any] else { return }
                switch item["type"] as? String {
                case "function_call":
                    self?.status = PalTools.status(for: item["name"] as? String ?? "")
                    self?.pausedForTools()
                case "web_search_call":
                    self?.status = PalTools.status(for: "web_search")
                    self?.pausedForTools()
                case "message":
                    // A second message in the same response starts a new paragraph.
                    if !text.isEmpty { text += "\n\n" }
                    self?.status = nil
                default: break
                }
            case "response.output_text.delta":
                guard let delta = event["delta"] as? String else { return }
                text += delta
                self?.status = nil
                onText(text)
            case "response.output_item.done":
                if let index = event["output_index"] as? Int, let item = event["item"] as? [String: Any] {
                    items[index] = item
                }
            case "response.completed", "response.incomplete":
                final = event["response"] as? [String: Any]
            default:
                break
            }
        }
        let output = (final?["output"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 }
            ?? items.sorted { $0.key < $1.key }.map(\.value)
        let calls = output.filter { $0["type"] as? String == "function_call" }.map { item in
            Call(id: item["call_id"] as? String ?? "", name: item["name"] as? String ?? "", arguments: item["arguments"] as? String ?? "{}")
        }
        var note: String?
        if final?["status"] as? String == "incomplete", calls.isEmpty {
            let reason = (final?["incomplete_details"] as? [String: Any])?["reason"] as? String
            note = reason == "content_filter" ? "(I can't help with that one.)" : "(My answer got cut off. Ask me to go on.)"
        }
        return Round(items: output, calls: calls, note: note)
    }

    /// The history to send to GPT: as it is, except that pictures in all
    /// but your last few messages (and the looks that went with them) are
    /// left out, so a long talk stays small.
    private func prunedHistory() -> [[String: Any]] {
        let userTurns = history.indices.filter { history[$0]["role"] as? String == "user" }
        guard userTurns.count > Self.turnsWithPictures else { return history }
        let keepFrom = userTurns[userTurns.count - Self.turnsWithPictures]
        return history.enumerated().map { index, item in
            guard index < keepFrom else { return item }
            var item = item
            if let content = item["content"] as? [[String: Any]] {
                item["content"] = Self.withoutPictures(content)
            } else if item["type"] as? String == "function_call_output", let output = item["output"] as? [[String: Any]] {
                item["output"] = Self.withoutPictures(output)
            }
            return item
        }
    }

    private static func withoutPictures(_ parts: [[String: Any]]) -> [[String: Any]] {
        parts.map { part in
            part["type"] as? String == "input_image" ? ["type": "input_text", "text": "(A picture you saw then; it's no longer shown.)"] : part
        }
    }

    // MARK: Claude

    private func respondWithClaude(effort: String, onText: (String) -> Void) async throws -> Round {
        let body: [String: Any] = [
            "model": ClaudeClient.model,
            "max_tokens": 64_000,
            "system": talk.instructions,
            "tools": talk.tools,
            "tool_choice": ["type": "auto"],
            // If the history ever doesn't match what a thinking block was
            // made with, that block is left out rather than the request failing.
            "thinking": ["type": "adaptive", "block_binding": ["prefix_mismatch_behavior": "drop_block"]] as [String: Any],
            "output_config": ["effort": effort],
            // Follow-up messages reuse the cached talk instead of paying for it again.
            "cache_control": ["type": "ephemeral"],
            // On a safety-classifier decline, retry on a fallback model in the same call.
            "fallbacks": "default",
            "messages": history,
        ]
        var blocks: [Int: [String: Any]] = [:]
        var partialInputs: [Int: String] = [:]
        var stopReason: String?
        try await ClaudeClient.stream(body: body) { [weak self] event in
            switch event["type"] as? String {
            case "content_block_start":
                guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { return }
                blocks[index] = block
                switch block["type"] as? String {
                case "tool_use", "server_tool_use":
                    self?.status = PalTools.status(for: block["name"] as? String ?? "")
                    self?.pausedForTools()
                case "text": self?.status = nil
                default: break
                }
            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      var block = blocks[index] else { return }
                switch delta["type"] as? String {
                case "text_delta":
                    block["text"] = (block["text"] as? String ?? "") + (delta["text"] as? String ?? "")
                    blocks[index] = block
                    self?.status = nil
                    onText(Self.visibleText(of: blocks))
                case "thinking_delta":
                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                    blocks[index] = block
                case "signature_delta":
                    block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                    blocks[index] = block
                case "citations_delta":
                    if let citation = delta["citation"] {
                        block["citations"] = (block["citations"] as? [Any] ?? []) + [citation]
                        blocks[index] = block
                    }
                case "input_json_delta":
                    partialInputs[index, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break
                }
            case "content_block_stop":
                // Tool inputs arrive as JSON fragments; parse them once complete.
                guard let index = event["index"] as? Int, let json = partialInputs.removeValue(forKey: index) else { return }
                if let input = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] {
                    blocks[index]?["input"] = input
                } else if !json.trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks[index]?["input"] = [String: Any]()
                    blocks[index]?["_invalidInput"] = json
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
            default:
                break
            }
        }
        let content = Self.echoable(blocks.sorted { $0.key < $1.key }.map(\.value))
        var round = Round(items: [], calls: [])
        let calls = content.filter { $0["type"] as? String == "tool_use" }.map { block -> Call in
            let input = block["input"] as? [String: Any] ?? [:]
            let arguments = (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return Call(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "", arguments: arguments, invalid: block["_invalidInput"] as? String)
        }
        let echoed = content.map { block -> [String: Any] in
            var block = block
            block.removeValue(forKey: "_invalidInput")
            return block
        }
        if !echoed.isEmpty { round.items = [["role": "assistant", "content": echoed]] }
        switch stopReason {
        case "tool_use":
            round.calls = calls
        case "pause_turn":
            // A long web search paused; sending the history again resumes it.
            round.goOn = true
        case "refusal":
            round.note = "(I can't help with that one.)"
        case "max_tokens":
            round.note = "(My answer got cut off. Ask me to go on.)"
        default:
            break
        }
        return round
    }

    private static func visibleText(of blocks: [Int: [String: Any]]) -> String {
        blocks.sorted { $0.key < $1.key }
            .compactMap { $0.value["type"] as? String == "text" ? $0.value["text"] as? String : nil }
            .joined()
    }

    /// An answer as it's sent back. After a mid-answer fallback, the
    /// model-internal blocks from before the last `fallback` block are left
    /// out (thinking, tool calls, and server tool calls without their
    /// results), as the API asks; the `fallback` block stays where it was.
    private static func echoable(_ blocks: [[String: Any]]) -> [[String: Any]] {
        guard let boundary = blocks.lastIndex(where: { $0["type"] as? String == "fallback" }) else { return blocks }
        let answeredServerCalls = Set(blocks.compactMap { $0["tool_use_id"] as? String })
        return blocks.enumerated().compactMap { index, block in
            if index >= boundary { return block }
            switch block["type"] as? String {
            case "thinking", "redacted_thinking", "tool_use":
                return nil
            case "server_tool_use":
                return answeredServerCalls.contains(block["id"] as? String ?? "") ? block : nil
            default:
                return block
            }
        }
    }

    /// Claude's tools: hers as Claude tools, plus web search and web fetch.
    private static func claudeTools(_ definitions: [[String: Any]]) -> [[String: Any]] {
        var tools: [[String: Any]] = [
            ["type": "web_search_20260209", "name": "web_search", "max_uses": 5],
            ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 5],
        ]
        for tool in definitions where tool["type"] as? String == "function" {
            guard let name = tool["name"] as? String, let parameters = tool["parameters"] else { continue }
            tools.append([
                "name": name,
                "description": tool["description"] as? String ?? "",
                "input_schema": parameters,
                "eager_input_streaming": true,
            ])
        }
        return tools
    }

    // MARK: History items

    private static func userMessage(_ parts: [Part], for mind: PalMind) -> [String: Any] {
        let content: [[String: Any]] = parts.map { part in
            switch (part, mind) {
            case (.text(let text), .openAI): ["type": "input_text", "text": text]
            case (.image(let jpeg, let detail), .openAI): ["type": "input_image", "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString(), "detail": detail]
            case (.text(let text), .claude): ["type": "text", "text": text]
            case (.image(let jpeg, _), .claude): ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
            }
        }
        return ["role": "user", "content": content]
    }

    /// The results of the tools she called, in the talk's format: one item
    /// per call for GPT, one message with every result for Claude.
    private func toolResults(_ outputs: [(call: Call, outcome: PalTools.Outcome)]) -> [[String: Any]] {
        switch talk.mind {
        case .claude:
            let results: [[String: Any]] = outputs.map { call, outcome in
                ["type": "tool_result", "tool_use_id": call.id, "content": Self.claudeContent(outcome.output), "is_error": outcome.isError]
            }
            return results.isEmpty ? [] : [["role": "user", "content": results]]
        case .openAI, nil:
            return outputs.map { call, outcome in
                ["type": "function_call_output", "call_id": call.id, "output": outcome.output]
            }
        }
    }

    /// A tool's output (text, or `input_text` and `input_image` parts) as
    /// Claude tool-result content.
    private static func claudeContent(_ output: Any) -> Any {
        guard let parts = output as? [[String: Any]] else { return output as? String ?? "" }
        return parts.compactMap { part -> [String: Any]? in
            switch part["type"] as? String {
            case "input_text":
                return ["type": "text", "text": part["text"] as? String ?? ""]
            case "input_image":
                let url = part["image_url"] as? String ?? ""
                guard let comma = url.firstIndex(of: ",") else { return nil }
                let data = String(url[url.index(after: comma)...])
                return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data]]
            default:
                return nil
            }
        }
    }

    // MARK: The reply

    private func reply(_ id: Message.ID) -> String {
        messages.first { $0.id == id }?.text ?? ""
    }

    private func setReply(_ text: String, id: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
        onReply?(text, false)
    }

    /// She stopped writing to use a tool: what she wrote so far can be
    /// said now, rather than after the tool, which can take a minute.
    private func pausedForTools() {
        guard isWorking, let last = messages.last, last.role == .pal else { return }
        onPause?(last.text)
    }

    private static func joined(_ earlier: String, _ text: String) -> String {
        [earlier, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// You stopped her: the history keeps what she finished (your message
    /// and any tools she'd run), and what she'd said so far stays on screen.
    private func stop(replyID: Message.ID, settled: Int, historyCount: Int, before: Talk) {
        if history.count > settled { history.removeSubrange(settled...) }
        if settled == historyCount {
            // Nothing she did is kept: your message goes too.
            if history.count > historyCount { history.removeSubrange(historyCount...) }
            talk.seen = before.seen
            talk.userTurns = before.userTurns
        }
        if let index = messages.firstIndex(where: { $0.id == replyID }) {
            if messages[index].text.isEmpty {
                messages.remove(at: index)
            } else {
                messages[index].text += " …"
            }
        }
        onReply?(reply(replyID), true)
    }

    /// Something went wrong. If she hadn't done anything yet, Try Again
    /// sends your message again; if she had, what she did is kept and you
    /// can ask her to go on (so nothing is done twice).
    private func fail(_ message: String, replyID: Message.ID, settled: Int, historyCount: Int, before: Talk, retry: Retry) {
        if history.count > settled { history.removeSubrange(settled...) }
        if settled == historyCount {
            if history.count > historyCount { history.removeSubrange(historyCount...) }
            talk.seen = before.seen
            talk.userTurns = before.userTurns
            messages.removeAll { $0.id == replyID }
            errorText = message
            pendingRetry = retry
            canRetry = true
        } else {
            if let index = messages.firstIndex(where: { $0.id == replyID }), messages[index].text.isEmpty {
                messages.remove(at: index)
            }
            errorText = message + " What I'd done so far is kept; ask me to go on."
        }
        onReply?("", true)
    }
}
