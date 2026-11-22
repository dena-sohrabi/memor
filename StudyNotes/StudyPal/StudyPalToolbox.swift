import CoreGraphics
import Foundation

/// What the study pal can do on your page during a call, as tools for the
/// realtime model that talks with you: write a note, draw a picture, show
/// you options to pick from, and move, resize, edit or delete typed notes
/// and pictures. Your handwriting is never changed, and Undo takes back
/// anything she does.
@MainActor
@Observable
final class StudyPalToolbox {
    /// Options waiting for you to pick one (on screen in a card).
    private(set) var pendingChoice: AskSession.Choice?
    /// A tool is running (drawing a picture takes a while).
    private(set) var isBusy = false
    /// Goes up each time she changes the page, so she can be pleased.
    private(set) var pageChanges = 0

    @ObservationIgnored weak var actions: AskPageActions?
    @ObservationIgnored private var choiceAnswer: CheckedContinuation<String, Never>?

    /// The tools, in the realtime model's function format.
    func definitions() -> [[String: Any]] {
        let id: [String: Any] = ["type": "string", "description": "The item's id from get_page_items."]
        let number: [String: Any] = ["type": "number"]
        var tools = [
            function("get_page_items",
                     "List the typed notes and pictures on the user's page: each one's id, kind, position and size in page points (x grows right, y grows down), and its text. Call it before moving, resizing, editing or deleting anything.",
                     [:]),
            function("add_note",
                     "Write a typed note on the user's page. It goes in free space beside what they circled or near the middle of their screen, in their page's font and color. Write it the way their notes are written. Use it when they ask you to write, add or put something on their page.",
                     ["text": ["type": "string", "description": "The note, in plain text with simple line breaks."]]),
            function("offer_choices",
                     "Show the user a few options on screen and wait for their pick. Use it when the choice is theirs, like which of a few ways to go or which topic next. Say briefly what you're showing first. Returns what they picked or said.",
                     ["question": ["type": "string", "description": "A short question shown above the options."],
                      "options": ["type": "array", "items": ["type": "string"], "description": "Two to six short options."] as [String: Any]]),
            function("move_item", "Move a typed note or picture so its top-left corner is at (x, y), in page points.",
                     ["id": id, "x": number, "y": number]),
            function("resize_item", "Change a typed note's or picture's width, in page points.",
                     ["id": id, "width": number]),
            function("edit_text", "Replace the text of a typed note.",
                     ["id": id, "text": ["type": "string"]]),
            function("delete_item", "Delete a typed note or picture. The user can undo it.",
                     ["id": id]),
        ]
        if actions?.canAddImages == true {
            tools.append(function(
                "draw_picture",
                "Draw a new picture and put it on the user's page: an illustration or diagram you design. Write a detailed prompt: the subject, the style, the colors, and any labels (few and short, spelled out exactly). For pictures that sit on their notes, ask for a clean, simple style with a transparent background. It takes up to a minute, so tell them you're drawing first.",
                ["prompt": ["type": "string", "description": "What to draw, in detail."],
                 "transparent_background": ["type": "boolean", "description": "True for a cut-out picture with no background."]]
            ))
        }
        return tools
    }

    private func function(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": properties.keys.sorted(),
            ] as [String: Any],
        ]
    }

    /// Runs a tool the model called, with its JSON arguments, and returns
    /// what to tell the model.
    func run(name: String, arguments: String) async -> String {
        let input = arguments.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        isBusy = true
        defer { isBusy = false }
        switch name {
        case "offer_choices": return await offerChoices(input)
        case "draw_picture": return await draw(input)
        default: break
        }
        guard let actions else { return "The page isn't open anymore." }
        switch name {
        case "get_page_items":
            return actions.askPageItems()
        case "add_note":
            guard let text = input["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "`text` must be a non-empty string."
            }
            guard actions.askAddText(text) != nil else { return "Couldn't add the note. The page has to be on screen." }
            pageChanges += 1
            return "Added the note to the page."
        case "move_item":
            guard let id = Self.id(input), let x = Self.number(input["x"]), let y = Self.number(input["y"]) else {
                return "`id` must be an item id, and `x` and `y` numbers."
            }
            return changed(actions.askMoveItem(id, to: CGPoint(x: x, y: y)), "Moved it.")
        case "resize_item":
            guard let id = Self.id(input), let width = Self.number(input["width"]), width > 0 else {
                return "`id` must be an item id, and `width` a positive number."
            }
            return changed(actions.askResizeItem(id, width: width), "Resized it.")
        case "edit_text":
            guard let id = Self.id(input), let text = input["text"] as? String, !text.isEmpty else {
                return "`id` must be a note's id, and `text` a non-empty string."
            }
            return changed(actions.askEditText(id, text: text), "Replaced the text.")
        case "delete_item":
            guard let id = Self.id(input) else { return "`id` must be an item id." }
            return changed(actions.askDeleteItem(id), "Deleted it. The user can undo this.")
        default:
            return "There's no tool called \(name)."
        }
    }

    private func changed(_ problem: String?, _ success: String) -> String {
        if let problem { return problem }
        pageChanges += 1
        return success
    }

    private func draw(_ input: [String: Any]) async -> String {
        guard actions?.canAddImages == true else { return "Pictures can only be added to notebook pages." }
        guard let prompt = input["prompt"] as? String, !prompt.isEmpty else { return "`prompt` must be a non-empty string." }
        let transparent = input["transparent_background"] as? Bool ?? false
        do {
            let data = try await OpenAIClient.generateImage(prompt: prompt, transparent: transparent)
            let prepared = await Task.detached(priority: .userInitiated) { ImageImport.prepare(data) }.value
            guard let prepared else { return "The picture came back in a form Memor can't read." }
            guard actions?.askAddImage(prepared) != nil else { return "Couldn't add the picture. The page may have closed." }
            pageChanges += 1
            return "Drew the picture and put it on the page."
        } catch {
            return "Couldn't draw it: \(error.localizedDescription)"
        }
    }

    // MARK: Choices

    private func offerChoices(_ input: [String: Any]) async -> String {
        let question = input["question"] as? String ?? ""
        let labels = (input["options"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard labels.count >= 2 else { return "Give at least two options." }
        resolve("The user closed the options without choosing.")
        let options = labels.enumerated().map { AskSession.Choice.Option(id: $0.offset, label: $0.element, imageURL: nil) }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            choiceAnswer = continuation
            pendingChoice = AskSession.Choice(question: question, options: options)
        }
    }

    func choose(_ option: AskSession.Choice.Option) {
        resolve("The user chose: \(option.label)")
    }

    func answerChoice(saying text: String) {
        resolve("The user said: \(text)")
    }

    func dismissChoice() {
        resolve("The user closed the options without choosing.")
    }

    /// Anything still waiting gets an answer (the call ended, say).
    func cancel() {
        resolve("The user closed the options without choosing.")
    }

    private func resolve(_ answer: String) {
        guard let choiceAnswer else { return }
        self.choiceAnswer = nil
        pendingChoice = nil
        choiceAnswer.resume(returning: answer)
    }

    private static func id(_ input: [String: Any]) -> UUID? {
        (input["id"] as? String).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func number(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return CGFloat(number.doubleValue)
    }
}
