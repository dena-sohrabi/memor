import Foundation
import UIKit

/// One "circle to ask" conversation: the circled image, Claude's answer, and
/// any follow-up questions.
///
/// The history sent to the API is append-only (earlier turns are never
/// edited) and assistant turns are sent back exactly as they arrived,
/// thinking blocks included, as Claude Opus 5.5 requires.
@MainActor
@Observable
final class AskSession: Identifiable {
    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    let id = UUID()
    let image: UIImage
    private(set) var messages: [Message] = []
    private(set) var isWorking = false
    private(set) var errorText: String?
    /// Whether the last request failed and can be sent again.
    private(set) var canRetry = false

    @ObservationIgnored private var history: [[String: Any]] = []
    @ObservationIgnored private var pendingRetry: (content: [[String: Any]], displayText: String?)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let imageData: Data

    private static let systemPrompt = """
    You are the study helper in Memor, an iPad note-taking app for students. The user circled part of a page from their handwritten notes or a PDF (lecture slides, readings, past exams), and it arrives as an image.

    If the circled part contains a question, exercise or problem, answer or solve it, showing the key steps. Otherwise, explain briefly what it shows and how it fits the topic, then invite a follow-up question. Read handwriting carefully; if something is unreadable, say which part.

    Your answer appears in a narrow side panel, so keep it short and well organized: short paragraphs and simple lists, no tables. Write math in plain text with Unicode symbols (×, ÷, ², √, π, ≤, →) instead of LaTeX. Answer in the language the user writes in, or else the language of the circled material.
    """

    init(image: UIImage) {
        self.image = image
        self.imageData = image.jpegData(compressionQuality: 0.85) ?? Data()
    }

    /// Asks about the circled area right away.
    func start() {
        let imageBlock: [String: Any] = [
            "type": "image",
            "source": ["type": "base64", "media_type": "image/jpeg", "data": imageData.base64EncodedString()],
        ]
        send(content: [imageBlock, ["type": "text", "text": "Here's the part I circled."]], displayText: nil)
    }

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        send(content: [["type": "text", "text": question]], displayText: question)
    }

    func retry() {
        guard let pendingRetry else { return }
        self.pendingRetry = nil
        send(content: pendingRetry.content, displayText: pendingRetry.displayText)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: Sending

    private func send(content: [[String: Any]], displayText: String?) {
        guard !isWorking else { return }
        errorText = nil
        canRetry = false
        if let displayText {
            messages.append(Message(role: .user, text: displayText))
        }
        history.append(["role": "user", "content": content])
        messages.append(Message(role: .assistant, text: ""))
        let replyIndex = messages.count - 1
        isWorking = true

        let body = try? JSONSerialization.data(withJSONObject: requestBody())
        task = Task { [weak self] in
            await self?.receive(body: body, replyIndex: replyIndex, content: content, displayText: displayText)
        }
    }

    private func requestBody() -> [String: Any] {
        [
            "model": ClaudeClient.model,
            "max_tokens": 32_000,
            "stream": true,
            "system": Self.systemPrompt,
            "output_config": ["effort": "medium"],
            // On a safety-classifier decline, retry on a fallback model in the same call.
            "fallbacks": "default",
            // Follow-up questions reuse the cached image instead of paying for it again.
            "cache_control": ["type": "ephemeral"],
            "messages": history,
        ]
    }

    private func receive(body: Data?, replyIndex: Int, content: [[String: Any]], displayText: String?) async {
        defer { isWorking = false }
        guard let body else {
            fail("Couldn't prepare the request.", replyIndex: replyIndex, content: content, displayText: displayText)
            return
        }

        var blocks: [Int: [String: Any]] = [:]
        var stopReason: String?
        do {
            try await ClaudeClient.stream(body: body) { event in
                switch event["type"] as? String {
                case "content_block_start":
                    if let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] {
                        blocks[index] = block
                    }
                case "content_block_delta":
                    guard let index = event["index"] as? Int,
                          let delta = event["delta"] as? [String: Any],
                          var block = blocks[index] else { return }
                    switch delta["type"] as? String {
                    case "text_delta":
                        block["text"] = (block["text"] as? String ?? "") + (delta["text"] as? String ?? "")
                    case "thinking_delta":
                        block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                    case "signature_delta":
                        block["signature"] = delta["signature"] as? String ?? ""
                    default:
                        break
                    }
                    blocks[index] = block
                    if replyIndex < messages.count {
                        messages[replyIndex].text = Self.visibleText(of: blocks)
                    }
                case "message_delta":
                    if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                        stopReason = reason
                    }
                default:
                    break
                }
            }
        } catch is CancellationError {
            return
        } catch {
            fail(error.localizedDescription, replyIndex: replyIndex, content: content, displayText: displayText)
            return
        }

        if stopReason == "refusal" {
            fail("Claude can't help with this one.", replyIndex: replyIndex, content: nil, displayText: displayText)
            return
        }
        let assistantContent = Self.echoable(blocks.sorted { $0.key < $1.key }.map(\.value))
        history.append(["role": "assistant", "content": assistantContent])
        if stopReason == "max_tokens", replyIndex < messages.count {
            messages[replyIndex].text += "\n\n(The answer was cut off.)"
        }
    }

    /// Undoes the turn that failed, so the history stays valid, and offers a retry.
    private func fail(_ message: String, replyIndex: Int, content: [[String: Any]]?, displayText: String?) {
        if history.last?["role"] as? String == "user" {
            history.removeLast()
        }
        if replyIndex < messages.count {
            messages.remove(at: replyIndex)
        }
        if displayText != nil, messages.last?.role == .user {
            messages.removeLast()
        }
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

    /// After a mid-answer fallback, the API wants model-internal blocks
    /// (like thinking) from before the last `fallback` block left out when
    /// the turn is sent back; text and the `fallback` block itself stay.
    private static func echoable(_ blocks: [[String: Any]]) -> [[String: Any]] {
        guard let boundary = blocks.lastIndex(where: { $0["type"] as? String == "fallback" }) else { return blocks }
        return blocks.enumerated().compactMap { index, block in
            if index >= boundary { return block }
            let type = block["type"] as? String
            return type == "text" || type == "fallback" ? block : nil
        }
    }
}
