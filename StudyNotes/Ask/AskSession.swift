import Foundation
import UIKit

/// The page a chat is about, so Claude sees everything on it, not just the
/// circled part.
struct PageContext {
    /// A picture of the whole page (JPEG).
    var imageData: Data?
    /// The page's typed text and PDF text.
    var text: String
}

/// Where a chat happens, which decides what Claude can do there.
enum AskSurface {
    /// A notebook page: Claude can add, move, resize, edit and delete text
    /// boxes and images.
    case notebook
    /// A PDF: Claude can do the same with typed notes on the page.
    case pdf
}

/// One Ask Claude conversation: optionally a circled area, Claude's answers,
/// and follow-up questions. Claude can search the web and, when you ask,
/// work on your page like a study pal: add things, move them around,
/// resize, edit or delete them.
///
/// The history sent to the API is append-only (earlier turns are never
/// edited) and assistant turns are sent back exactly as they arrived,
/// thinking and tool blocks included, as Claude Opus 5.5 requires.
@MainActor
@Observable
final class AskSession: Identifiable {
    struct Message: Identifiable {
        enum Role: String, Codable { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    private struct StoredMessage: Codable {
        let role: Message.Role
        let text: String
    }

    let id = UUID()
    let image: UIImage?
    /// The saved chat this session writes to, if it's a circled one.
    let thread: AskThread?
    private(set) var messages: [Message] = []
    private(set) var isWorking = false
    /// What Claude is doing right now ("Searching the web…"), while working.
    private(set) var status: String?
    private(set) var errorText: String?
    private(set) var canRetry = false
    /// Goes up each time Claude changes the page, so the study pal can react.
    private(set) var pageChanges = 0
    /// The answer being turned into a note for the page (Add to Page), if any.
    private(set) var addingToPageID: Message.ID?

    /// Claude is writing its answer, rather than thinking or using a tool.
    var isAnswering: Bool {
        guard isWorking, status == nil, let last = messages.last, last.role == .assistant else { return false }
        return !last.text.isEmpty
    }

    /// The page Claude works on. Weak: the page owns the chat, not the
    /// other way around.
    @ObservationIgnored weak var actions: AskPageActions?
    /// Called after each answer is saved into `thread`.
    @ObservationIgnored var onSaved: (() -> Void)?

    @ObservationIgnored private let surface: AskSurface
    /// Sent with the first message of a new chat.
    @ObservationIgnored var pageContext: PageContext?
    /// A chat you started by talking to the study pal, who says the answers
    /// out loud: it runs on the faster model with no thinking up front, at
    /// low effort, for its whole length. (Changing the model or effort in
    /// the middle of a chat would throw away its cache.)
    @ObservationIgnored var isVoiceChat = false
    @ObservationIgnored private var history: [[String: Any]] = []
    @ObservationIgnored private var pendingRetry: (content: [[String: Any]], displayText: String?)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Questions asked since the chat opened, or since she last remembered it.
    @ObservationIgnored private var newTurns = 0

    private static let maxToolRounds = 12

    // MARK: Memory

    /// You asked something since the chat opened, so there's something new
    /// for her to remember.
    var hasNewTurns: Bool { newTurns > 0 }

    /// The talk this chat is in her memory: its saved thread, if it has
    /// one, so a reopened chat updates the same memory.
    var memoryID: UUID { thread?.id ?? id }

    /// The whole chat, for her to remember.
    var memoryLines: [PalLine] {
        var lines: [PalLine] = []
        if image != nil {
            lines.append(PalLine(isStudent: true, text: "(Circled part of their page and asked about it.)"))
        }
        for message in messages where !message.text.isEmpty {
            lines.append(PalLine(isStudent: message.role == .user, text: message.text))
        }
        return lines
    }

    func markRemembered() {
        newTurns = 0
    }

    /// A new chat. With an image, it's about a circled area.
    init(image: UIImage?, thread: AskThread?, surface: AskSurface) {
        self.image = image
        self.thread = thread
        self.surface = surface
    }

    /// Reopens a saved chat.
    convenience init(thread: AskThread, surface: AskSurface) {
        self.init(image: thread.imageData.flatMap(UIImage.init(data:)), thread: thread, surface: surface)
        if let data = thread.historyData,
           let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            history = saved
        }
        if let data = thread.transcriptData,
           let saved = try? JSONDecoder().decode([StoredMessage].self, from: data) {
            messages = saved.map { Message(role: $0.role, text: $0.text) }
        }
    }

    // MARK: Add to Page

    /// Writes the key points of an answer on the page, as a short note,
    /// in free space beside what was circled or in view. If Claude can't
    /// make the note, the whole answer goes on the page instead.
    func addToPage(_ message: Message) {
        guard addingToPageID == nil, message.role == .assistant else { return }
        addingToPageID = message.id
        Task {
            defer { addingToPageID = nil }
            let note: String
            do {
                note = try await keyPoints(of: message)
            } catch is CancellationError {
                return
            } catch {
                note = MarkdownText.plainText(message.text)
            }
            if actions?.askAddText(note) != nil { pageChanges += 1 }
        }
    }

    /// A separate, small request: it isn't part of the chat.
    private func keyPoints(of message: Message) async throws -> String {
        let index = messages.firstIndex { $0.id == message.id } ?? messages.endIndex
        let question = messages[..<index].last { $0.role == .user }?.text
        let asked = question.map { "The student asked: \($0)" }
            ?? "The student circled part of their notes and asked about it."
        // Their own notes, so the note is written the way they write.
        let notes = String((actions?.askPageNotes() ?? "").prefix(2_000))
        let style = notes.isEmpty ? "" : "\n\nTheir typed notes on this page, to match in style:\n\n\(notes)"
        let body: [String: Any] = [
            "model": ClaudeClient.model,
            "max_tokens": 1_024,
            "stream": true,
            "output_config": ["effort": "low"],
            "system": Self.keyPointsPrompt,
            "messages": [["role": "user", "content": "\(asked)\n\nThe answer:\n\n\(message.text)\(style)"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        var note = ""
        try await ClaudeClient.stream(body: data) { event in
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            note += text
        }
        // The note comes as Markdown; the page gets plain text with bullets.
        let plain = MarkdownText.plainText(note).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { throw ClaudeError.other("Claude didn't write a note.") }
        return plain
    }

    private static let keyPointsPrompt = """
    You turn an answer from a study chat into a short note the student keeps on their notes page. Keep only what matters for what they asked: the key facts, definitions, formulas, dates or steps. Leave out greetings, how you worked it out, side remarks, offers of help and follow-up questions.

    Write a short title as a Markdown heading, then 2 to 6 bullet points of a line or two each. For a solved problem, give the key steps and the result. Write math in plain text with Unicode symbols (×, ÷, ², √, π, ≤, →), not LaTeX. Use the language of the answer. If their own notes are included, write it the way they write: their language, their kind of headings and bullets, their abbreviations and how short they keep things. Reply with the note only.
    """

    /// Asks about the circled area right away.
    func start(spoken: Bool = false) {
        guard let data = image?.jpegData(compressionQuality: 0.85) else { return }
        var content = contextBlocks() + [Self.imageBlock(data), ["type": "text", "text": "Here's the part I circled."]]
        if spoken { content.append(["type": "text", "text": Self.spokenNote]) }
        send(content: content, displayText: nil)
    }

    /// Asks a question. A `spoken` one was said out loud and will be read
    /// out loud, so Claude answers shorter and warmer.
    func ask(_ question: String, spoken: Bool = false) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        var content = contextBlocks() + [["type": "text", "text": question]]
        if spoken { content.append(["type": "text", "text": Self.spokenNote]) }
        send(content: content, displayText: question)
    }

    /// Goes with a spoken question. It's part of the message rather than the
    /// system prompt, so the cached start of the chat stays the same.
    private static let spokenNote = """
        (I said this out loud, and your answer will be read out loud to me as you write it; \
        I don't see any text, so it's like we're on a call. Answer like you're talking to me: \
        one to three short, warm sentences, no lists, headings, tables or symbols, unless I ask \
        for more. If more detail would help, give the gist and offer to put it on my page. If I \
        should pick between options, use offer_choices to show them.)
        """

    /// Her name and what she remembers about you, and the whole page, for
    /// the first message of a chat only. (Not in the system prompt: a saved
    /// chat keeps what she knew when it started, so its history stays valid.)
    private func contextBlocks() -> [[String: Any]] {
        guard history.isEmpty else { return [] }
        var blocks: [[String: Any]] = [["type": "text", "text": StudyPalCharacter.memoryNote()]]
        guard let pageContext else { return blocks }
        var note = "For context, this is the whole page the user is working on"
        if let data = pageContext.imageData {
            blocks.append(Self.imageBlock(data))
            note += " (the image above)"
        }
        note += "."
        let text = pageContext.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            note += "\n\nText on the page:\n\(text)"
        }
        blocks.append(["type": "text", "text": note])
        return blocks
    }

    private static func imageBlock(_ jpeg: Data) -> [String: Any] {
        [
            "type": "image",
            "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
        ]
    }

    func retry() {
        guard let pendingRetry else { return }
        self.pendingRetry = nil
        send(content: pendingRetry.content, displayText: pendingRetry.displayText)
    }

    func cancel() {
        resolveChoice("The user closed the options without choosing.")
        task?.cancel()
        task = nil
    }

    // MARK: Choices

    /// A few options Claude asked the user to pick from, as buttons or
    /// pictures: the one time a voice chat shows anything on screen.
    struct Choice: Identifiable {
        struct Option: Identifiable {
            let id: Int
            let label: String
            let imageURL: URL?
        }

        let id = UUID()
        let question: String
        let options: [Option]

        var hasPictures: Bool { options.contains { $0.imageURL != nil } }
    }

    /// Options waiting for the user to pick one.
    private(set) var pendingChoice: Choice?
    @ObservationIgnored private var choiceAnswer: CheckedContinuation<String, Never>?

    /// The user tapped an option.
    func choose(_ option: Choice.Option) {
        resolveChoice("The user chose option \(option.id + 1): \(option.label)")
    }

    /// The user answered out loud while the options were showing.
    func answerChoice(saying text: String) {
        resolveChoice("The user said: \(text)")
    }

    func dismissChoice() {
        resolveChoice("The user closed the options without choosing.")
    }

    private func resolveChoice(_ answer: String) {
        guard let choiceAnswer else { return }
        self.choiceAnswer = nil
        pendingChoice = nil
        choiceAnswer.resume(returning: answer)
    }

    private func offerChoices(_ input: [String: Any]) async -> (text: String, isError: Bool) {
        let question = input["question"] as? String ?? ""
        let options = (input["options"] as? [[String: Any]] ?? []).enumerated().compactMap { index, option -> Choice.Option? in
            guard let label = option["label"] as? String, !label.isEmpty else { return nil }
            let link = (option["image_url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let url = URL(string: link).flatMap { $0.scheme == "https" ? $0 : nil }
            return Choice.Option(id: index, label: label, imageURL: url)
        }
        guard options.count >= 2 else { return ("Give at least two options.", true) }
        resolveChoice("The user closed the options without choosing.")
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            choiceAnswer = continuation
            pendingChoice = Choice(question: question, options: options)
        }
        return (answer, false)
    }

    // MARK: Sending

    private func send(content: [[String: Any]], displayText: String?) {
        guard !isWorking else { return }
        newTurns += 1
        errorText = nil
        canRetry = false
        let historyCount = history.count
        if let displayText {
            messages.append(Message(role: .user, text: displayText))
        }
        history.append(["role": "user", "content": content])
        messages.append(Message(role: .assistant, text: ""))
        let replyIndex = messages.count - 1
        isWorking = true
        task = Task { [weak self] in
            await self?.runTurn(replyIndex: replyIndex, historyCount: historyCount, content: content, displayText: displayText)
        }
    }

    /// One turn: stream Claude's answer, run any tools it calls, and loop
    /// until it's done.
    private func runTurn(replyIndex: Int, historyCount: Int, content: [[String: Any]], displayText: String?) async {
        defer {
            isWorking = false
            status = nil
        }
        var earlierText = ""
        var rounds = 0
        while true {
            let blocks: [[String: Any]]
            let stopReason: String?
            do {
                (blocks, stopReason) = try await streamOnce { [weak self] text in
                    guard let self, replyIndex < self.messages.count else { return }
                    self.messages[replyIndex].text = [earlierText, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                }
            } catch is CancellationError {
                rollBack(to: historyCount, replyIndex: replyIndex, displayText: displayText)
                return
            } catch {
                fail(error.localizedDescription, historyCount: historyCount, replyIndex: replyIndex, content: content, displayText: displayText)
                return
            }

            if stopReason == "refusal" {
                fail("Claude can't help with this one.", historyCount: historyCount, replyIndex: replyIndex, content: nil, displayText: displayText)
                return
            }
            history.append(["role": "assistant", "content": Self.echoable(blocks)])
            if replyIndex < messages.count {
                earlierText = messages[replyIndex].text
            }

            rounds += 1
            switch stopReason {
            case "tool_use" where rounds <= Self.maxToolRounds:
                let results = await runTools(in: blocks)
                if Task.isCancelled {
                    rollBack(to: historyCount, replyIndex: replyIndex, displayText: displayText)
                    return
                }
                history.append(["role": "user", "content": results])
                continue
            case "tool_use":
                // Too many steps for one answer. Every tool call still gets a
                // result, so the next question starts from a valid history.
                history.append(["role": "user", "content": Self.skippedResults(for: blocks)])
                if replyIndex < messages.count {
                    messages[replyIndex].text += "\n\n(Stopped after too many steps. Ask again to continue.)"
                }
            case "pause_turn" where rounds <= Self.maxToolRounds:
                // A long web search paused; sending the history again resumes it.
                continue
            case "max_tokens":
                if replyIndex < messages.count {
                    messages[replyIndex].text += "\n\n(The answer was cut off.)"
                }
            default:
                break
            }
            break
        }
        save()
    }

    /// Streams one response. Returns its content blocks and stop reason.
    private func streamOnce(onText: (String) -> Void) async throws -> ([[String: Any]], String?) {
        let body = try JSONSerialization.data(withJSONObject: requestBody())
        var blocks: [Int: [String: Any]] = [:]
        var partialInputs: [Int: String] = [:]
        var stopReason: String?
        // Where the time goes, for the debug console: durations and block
        // kinds only, never what anyone wrote.
        let sentAt = ContinuousClock.now
        var sawEvent = false
        var sawText = false
        func mark(_ what: String) {
            #if DEBUG
            let elapsed = ContinuousClock.now - sentAt
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print("[claude] \(what) after \(String(format: "%.2f", seconds))s")
            #endif
        }

        try await ClaudeClient.stream(body: body) { event in
            if !sawEvent {
                sawEvent = true
                mark("first event (\(isVoiceChat ? ClaudeClient.voiceModel : ClaudeClient.model))")
            }
            switch event["type"] as? String {
            case "content_block_start":
                guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { return }
                blocks[index] = block
                showStatus(for: block)
                mark("\(block["type"] as? String ?? "block") \(block["name"] as? String ?? "") starts")
            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      var block = blocks[index] else { return }
                switch delta["type"] as? String {
                case "text_delta":
                    if !sawText {
                        sawText = true
                        mark("first text")
                    }
                    block["text"] = (block["text"] as? String ?? "") + (delta["text"] as? String ?? "")
                    blocks[index] = block
                    onText(Self.visibleText(of: blocks))
                case "thinking_delta":
                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                    blocks[index] = block
                case "signature_delta":
                    block["signature"] = delta["signature"] as? String ?? ""
                    blocks[index] = block
                case "input_json_delta":
                    partialInputs[index, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break
                }
            case "content_block_stop":
                // Tool inputs arrive as JSON fragments; parse them once complete.
                guard let index = event["index"] as? Int, let json = partialInputs.removeValue(forKey: index) else { return }
                if let data = json.data(using: .utf8),
                   let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    blocks[index]?["input"] = input
                } else {
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
        return (blocks.sorted { $0.key < $1.key }.map(\.value), stopReason)
    }

    private func showStatus(for block: [String: Any]) {
        let name = block["name"] as? String
        switch (block["type"] as? String, name) {
        case ("server_tool_use", "web_search"): status = "Searching the web…"
        case ("server_tool_use", "web_fetch"): status = "Reading a web page…"
        case ("tool_use", "add_image_to_page"): status = "Adding an image to your page…"
        case ("tool_use", "generate_image"): status = "Drawing a picture for your page…"
        case ("tool_use", "offer_choices"): status = "Waiting for you to choose…"
        case ("tool_use", "add_text_to_page"): status = "Writing on your page…"
        case ("tool_use", "get_page_items"): status = "Looking at your page…"
        case ("tool_use", "move_item"): status = "Moving things around…"
        case ("tool_use", "resize_item"): status = "Resizing…"
        case ("tool_use", "edit_text"): status = "Editing text…"
        case ("tool_use", "delete_item"): status = "Removing something…"
        case ("text", _): status = nil
        default: break
        }
    }

    // MARK: Tools

    private func runTools(in blocks: [[String: Any]]) async -> [[String: Any]] {
        var results: [[String: Any]] = []
        for block in blocks where block["type"] as? String == "tool_use" {
            let id = block["id"] as? String ?? ""
            let outcome: (text: String, isError: Bool)
            if let invalid = block["_invalidInput"] as? String {
                let payload = (try? JSONSerialization.data(withJSONObject: ["INVALID_JSON": invalid])).flatMap { String(data: $0, encoding: .utf8) }
                outcome = (payload ?? "Invalid input.", true)
            } else {
                let name = block["name"] as? String ?? ""
                outcome = await runTool(named: name, input: block["input"] as? [String: Any] ?? [:])
                if !outcome.isError, name != "get_page_items" { pageChanges += 1 }
            }
            results.append(["type": "tool_result", "tool_use_id": id, "content": outcome.text, "is_error": outcome.isError])
        }
        return results
    }

    private static func skippedResults(for blocks: [[String: Any]]) -> [[String: Any]] {
        blocks.filter { $0["type"] as? String == "tool_use" }.map { block in
            [
                "type": "tool_result",
                "tool_use_id": block["id"] as? String ?? "",
                "content": "Not run: this answer took too many steps. Tell the user what you did so far.",
                "is_error": true,
            ] as [String: Any]
        }
    }

    private func runTool(named name: String, input: [String: Any]) async -> (text: String, isError: Bool) {
        // Downloading takes a while, so the image tool looks the page up again
        // after it instead of holding on to it.
        if name == "add_image_to_page" { return await addImage(input) }
        if name == "generate_image" { return await drawImage(input) }
        if name == "offer_choices" { return await offerChoices(input) }
        guard let actions else { return ("The page isn't open anymore.", true) }
        switch name {
        case "get_page_items":
            return (actions.askPageItems(), false)

        case "add_text_to_page":
            guard let text = input["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("`text` must be a non-empty string.", true)
            }
            guard let id = actions.askAddText(text) else {
                return ("Couldn't add text here. The page has to be on screen.", true)
            }
            return ("Added a text box with id \(id.uuidString).", false)

        case "move_item":
            guard let id = Self.itemID(input), let x = Self.number(input["x"]), let y = Self.number(input["y"]) else {
                return ("`id` must be an item id, and `x` and `y` numbers.", true)
            }
            return Self.outcome(actions.askMoveItem(id, to: CGPoint(x: x, y: y)), success: "Moved it.")

        case "resize_item":
            guard let id = Self.itemID(input), let width = Self.number(input["width"]), width > 0 else {
                return ("`id` must be an item id, and `width` a positive number.", true)
            }
            return Self.outcome(actions.askResizeItem(id, width: width), success: "Resized it.")

        case "edit_text":
            guard let id = Self.itemID(input), let text = input["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("`id` must be a text box id, and `text` a non-empty string.", true)
            }
            return Self.outcome(actions.askEditText(id, text: text), success: "Replaced the text.")

        case "delete_item":
            guard let id = Self.itemID(input) else { return ("`id` must be an item id.", true) }
            return Self.outcome(actions.askDeleteItem(id), success: "Deleted it. The user can undo this.")

        default:
            return ("Unknown tool \(name).", true)
        }
    }

    private func addImage(_ input: [String: Any]) async -> (text: String, isError: Bool) {
        guard actions?.canAddImages == true else { return ("Images can only be added to notebook pages.", true) }
        guard let link = input["image_url"] as? String, let url = URL(string: link) else {
            return ("`image_url` must be a URL.", true)
        }
        do {
            let data = try await ImageDownloader.fetch(url)
            let prepared = await Task.detached(priority: .userInitiated) { ImageImport.prepare(data) }.value
            guard let prepared else { return ("That link isn't an image Memor can read. Try another image.", true) }
            guard let id = actions?.askAddImage(prepared) else {
                return ("Couldn't add the image. The page may have closed.", true)
            }
            return ("Added an image with id \(id.uuidString).", false)
        } catch {
            return ("\(error.localizedDescription) Try another image link.", true)
        }
    }

    /// Has OpenAI draw a picture, then puts it on the page.
    private func drawImage(_ input: [String: Any]) async -> (text: String, isError: Bool) {
        guard actions?.canAddImages == true else { return ("Pictures can only be added to notebook pages.", true) }
        guard let prompt = input["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("`prompt` must be a non-empty string.", true)
        }
        let transparent = input["transparent_background"] as? Bool ?? false
        do {
            let data = try await OpenAIClient.generateImage(prompt: prompt, transparent: transparent)
            let prepared = await Task.detached(priority: .userInitiated) { ImageImport.prepare(data) }.value
            guard let prepared else { return ("The picture came back in a form Memor can't read. Try again.", true) }
            guard let id = actions?.askAddImage(prepared) else {
                return ("Couldn't add the picture. The page may have closed.", true)
            }
            return ("Drew a picture and added it with id \(id.uuidString).", false)
        } catch is CancellationError {
            return ("Stopped.", true)
        } catch {
            return ("Couldn't draw it: \(error.localizedDescription)", true)
        }
    }

    private static func itemID(_ input: [String: Any]) -> UUID? {
        (input["id"] as? String).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func number(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return CGFloat(number.doubleValue)
    }

    private static func outcome(_ problem: String?, success: String) -> (text: String, isError: Bool) {
        problem.map { ($0, true) } ?? (success, false)
    }

    // MARK: Request

    private func requestBody() -> [String: Any] {
        // Drawing needs an OpenAI key, and a notebook page to draw on.
        let canDraw = surface == .notebook && OpenAIKeyStore.hasKey
        var body: [String: Any] = [
            "model": isVoiceChat ? ClaudeClient.voiceModel : ClaudeClient.model,
            "max_tokens": 32_000,
            "stream": true,
            "system": Self.systemPrompt(for: surface, canDraw: canDraw),
            "tools": Self.tools(for: surface, canDraw: canDraw),
            "output_config": ["effort": isVoiceChat ? "low" : "medium"],
            // Follow-up questions reuse the cached image instead of paying for it again.
            "cache_control": ["type": "ephemeral"],
            "messages": history,
        ]
        if isVoiceChat {
            // No thinking before the answer, so the first words come sooner.
            // Thinking can still happen between tool calls.
            body["thinking"] = ["type": "between_tools"]
        } else {
            // On a safety-classifier decline, retry on a fallback model in
            // the same call. (Not with `between_tools`: other models reject it.)
            body["fallbacks"] = "default"
        }
        return body
    }

    private static func systemPrompt(for surface: AskSurface, canDraw: Bool) -> String {
        let notebook = surface == .notebook
        let drawing = canDraw
            ? " You can also draw a new picture with generate_image: use it when they ask you to draw, make, create or generate one, or when a simple illustration or diagram you design would explain something better than a photo. For real photos and existing images, use add_image_to_page."
            : ""
        let place = notebook ? "their handwritten notes" : "a PDF (lecture slides, readings, past exams)"
        let items = notebook ? "typed text box and image" : "typed note"
        let adding = notebook ? "add_text_to_page and add_image_to_page add new ones" : "add_text_to_page adds a new note"
        let fixed = notebook
            ? "Handwriting can't be moved or changed, and neither can locked images."
            : "The PDF itself, handwriting and highlights can't be changed, and images can't be added to PDFs."
        return """
        \(StudyPalCharacter.nature)

        You're chatting with them in Memor's chat panel. Sometimes they circle part of \(place) and it arrives as an image; sometimes they just ask a question.

        You know their page: the first message brings a picture of the whole page and its typed text. Work out what subject they're studying and where they are in it, and tie your answers to their notes: refer to what they wrote, use their terms and notation, gently point out mistakes you notice, and suggest what to look at next when it helps. Read handwriting carefully; if something is unreadable, say which part.

        If the circled part contains a question, exercise or problem, answer or solve it, showing the key steps. Otherwise, explain briefly what it shows and how it fits the topic, then invite a follow-up question.

        You can search the web when it helps.

        You can also work on the user's page with them. get_page_items lists every \(items) on it with its id, position and size, in page points (x grows to the right, y grows down), plus the area on screen. \(adding); move_item, resize_item, edit_text and delete_item change what's there. \(fixed) The user can undo anything you do.

        Only change the page when the user asks you to. Before moving, resizing, editing or deleting, call get_page_items for current ids and positions; don't guess them. When you arrange things, keep them from overlapping, line them up and leave some space between them. Afterwards, say in a sentence what you changed. To add a picture, find a direct link to an image file (Wikimedia Commons and other sources that allow reuse are best), then call add_image_to_page with it; if it fails, try another image.\(drawing)

        When you write on their page, write the way their notes are written: the same language, about as short, and the same kind of headings, bullets, numbering and abbreviations they use. Memor puts it in free space and matches the font and color of their page.

        Questions they say out loud arrive as text, so allow for small speech-recognition slips. When they should pick between options, like which picture to add, call offer_choices: it shows them on screen and gives you their pick.

        Your answer appears in a narrow side panel, so keep it short and well organized: short paragraphs and simple lists, no tables. Write math in plain text with Unicode symbols (×, ÷, ², √, π, ≤, →) instead of LaTeX. Answer in the language the user writes in, or else the language of the circled material.
        """
    }

    private static func tools(for surface: AskSurface, canDraw: Bool) -> [[String: Any]] {
        var tools: [[String: Any]] = [
            ["type": "web_search_20260209", "name": "web_search", "max_uses": 5],
            ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 5],
            [
                "name": "add_text_to_page",
                "description": "Write text onto the user's page as a typed text box. Memor puts it in free space beside what they circled, or near the middle of their screen, without covering anything. Call this when the user asks you to write, add, paste or put notes, a summary, an answer or any other text on their page. Use plain text with simple line breaks.",
                "strict": true,
                "eager_input_streaming": true,
                "input_schema": [
                    "type": "object",
                    "properties": ["text": ["type": "string", "description": "The text to put on the page."]],
                    "required": ["text"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
        ]
        tools += pageTools(for: surface)
        tools.append([
            "name": "offer_choices",
            "description": "Show the user a few options on screen to pick from, as buttons or pictures, and wait for their pick. Use it whenever the choice is theirs: which of several pictures to add, which of a few ways to go, which topic next. For picture options, give each a direct https link to an image file (and use it for pictures rather than describing them). Don't read the options out one by one; say briefly what you're showing, then call this. Returns which option they chose, or what they said instead.",
            "strict": true,
            "eager_input_streaming": true,
            "input_schema": [
                "type": "object",
                "properties": [
                    "question": ["type": "string", "description": "A short question shown above the options, e.g. \"Which picture should I add?\""],
                    "options": [
                        "type": "array",
                        "description": "Two to six options.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "label": ["type": "string", "description": "A short label for the option."],
                                "image_url": ["type": "string", "description": "A direct https link to a picture for this option, or an empty string."],
                            ],
                            "required": ["label", "image_url"],
                            "additionalProperties": false,
                        ] as [String: Any],
                    ] as [String: Any],
                ],
                "required": ["question", "options"],
                "additionalProperties": false,
            ] as [String: Any],
        ])
        if surface == .notebook {
            tools.append([
                "name": "add_image_to_page",
                "description": "Put an image from the web onto the user's notebook page. Memor puts it in free space beside what they circled, or near the middle of their screen, without covering anything. Call this when the user asks you to find, show, add, insert or paste a picture, photo, diagram or image on their page. First find a direct https link to an image file (.jpg, .jpeg, .png, .gif or .webp), for example from Wikimedia Commons. If it fails, try a different image link.",
                "strict": true,
                "eager_input_streaming": true,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "image_url": ["type": "string", "description": "Direct https link to the image file."],
                        "description": ["type": "string", "description": "What the image shows, e.g. \"Portrait of Gregor Mendel\"."],
                    ],
                    "required": ["image_url", "description"],
                    "additionalProperties": false,
                ] as [String: Any],
            ])
        }
        if canDraw {
            tools.append([
                "name": "generate_image",
                "description": "Draw a new picture with an image model and put it on the user's notebook page, in free space beside what they circled or near the middle of their screen. Use it when the user asks you to draw, make, create or generate a picture, illustration or diagram, or when a simple illustration you design would explain something better than a photo. Write a detailed prompt: the subject, the style, the colors, and any labels (keep labels few and short, and spell them out exactly). For illustrations and diagrams that sit on their notes, ask for a clean, simple style and set transparent_background to true. Drawing takes up to a minute.",
                "strict": true,
                "eager_input_streaming": true,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "prompt": ["type": "string", "description": "What to draw, in detail."],
                        "description": ["type": "string", "description": "A short description of the picture, e.g. \"Diagram of a plant cell\"."],
                        "transparent_background": ["type": "boolean", "description": "True for a cut-out picture with no background, to sit on the page."],
                    ],
                    "required": ["prompt", "description", "transparent_background"],
                    "additionalProperties": false,
                ] as [String: Any],
            ])
        }
        return tools
    }

    /// Tools for seeing and rearranging what's on the page.
    private static func pageTools(for surface: AskSurface) -> [[String: Any]] {
        let things = surface == .notebook ? "text boxes and images" : "the user's typed notes"
        let id: [String: Any] = ["type": "string", "description": "The item's id from get_page_items."]
        func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
            if !properties.isEmpty { schema["required"] = properties.keys.sorted() }
            return ["name": name, "description": description, "strict": true, "eager_input_streaming": true, "input_schema": schema]
        }
        return [
            tool("get_page_items",
                 "List what's on the user's page right now: \(things), each with its id, kind, x, y, width and height in page points (x grows to the right, y grows down), plus the area on screen and where the user circled. Call this before moving, resizing, editing or deleting anything.",
                 [:]),
            tool("move_item",
                 "Move a text box or image so its top-left corner is at (x, y) in page points. Use it when the user asks to move, arrange, line up, group or tidy things on their page.",
                 ["id": id,
                  "x": ["type": "number", "description": "New left edge, in page points."],
                  "y": ["type": "number", "description": "New top edge, in page points."]]),
            tool("resize_item",
                 "Change the width of a text box or image, in page points. Images keep their shape; text boxes rewrap their text.",
                 ["id": id, "width": ["type": "number", "description": "New width, in page points."]]),
            tool("edit_text",
                 "Replace all the text in one text box, for example to fix a mistake, rewrite, shorten or translate it. Use plain text with simple line breaks.",
                 ["id": id, "text": ["type": "string", "description": "The box's new text, in full."]]),
            tool("delete_item",
                 "Delete a text box or image from the page. Only when the user asks you to remove, clear or delete something.",
                 ["id": id]),
        ]
    }

    // MARK: Saving and failures

    /// Writes the chat into its saved thread, if it has one.
    private func save() {
        guard let thread, thread.modelContext != nil, !thread.isDeleted else { return }
        thread.historyData = try? JSONSerialization.data(withJSONObject: history)
        thread.transcriptData = try? JSONEncoder().encode(messages.map { StoredMessage(role: $0.role, text: $0.text) })
        thread.updatedAt = .now
        onSaved?()
    }

    /// Takes back the turn that didn't finish: the history returns to how
    /// it was before it (a trailing cut, which keeps earlier turns valid).
    private func rollBack(to historyCount: Int, replyIndex: Int, displayText: String?) {
        if history.count > historyCount {
            history.removeSubrange(historyCount...)
        }
        if replyIndex < messages.count {
            messages.removeSubrange(replyIndex...)
        }
        if displayText != nil, messages.last?.role == .user {
            messages.removeLast()
        }
    }

    private func fail(_ message: String, historyCount: Int, replyIndex: Int, content: [[String: Any]]?, displayText: String?) {
        rollBack(to: historyCount, replyIndex: replyIndex, displayText: displayText)
        errorText = message
        if let content {
            pendingRetry = (content, displayText)
            canRetry = true
        }
    }

    private static func visibleText(of blocks: [Int: [String: Any]]) -> String {
        blocks.sorted { $0.key < $1.key }
            .compactMap { $0.value["type"] as? String == "text" ? $0.value["text"] as? String : nil }
            .joined()
    }

    /// Prepares an assistant turn to be sent back: drops our private
    /// marker, and after a mid-answer fallback leaves out model-internal
    /// blocks (thinking, tool calls) from before the last `fallback` block.
    private static func echoable(_ blocks: [[String: Any]]) -> [[String: Any]] {
        let cleaned = blocks.map { block -> [String: Any] in
            var block = block
            block.removeValue(forKey: "_invalidInput")
            return block
        }
        guard let boundary = cleaned.lastIndex(where: { $0["type"] as? String == "fallback" }) else { return cleaned }
        return cleaned.enumerated().compactMap { index, block in
            if index >= boundary { return block }
            let type = block["type"] as? String
            return type == "text" || type == "fallback" ? block : nil
        }
    }
}

/// Downloads an image Claude found, carefully: HTTPS only, no cookies or
/// cache, at most 15 MB, and only if the server says it's an image.
enum ImageDownloader {
    private static let maxBytes = 15_000_000

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    static func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw ClaudeError.other("Only https image links can be used.")
        }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClaudeError.other("The image link didn't work.")
        }
        guard (http.mimeType ?? "").hasPrefix("image/") else {
            throw ClaudeError.other("That link isn't an image file.")
        }
        guard data.count <= maxBytes else {
            throw ClaudeError.other("That image is too large.")
        }
        return data
    }
}
