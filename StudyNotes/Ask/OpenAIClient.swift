import Foundation

/// Talks to OpenAI straight from the iPad, with the user's own key, for
/// two things: the study pal's speaking voice and the images Claude draws.
/// Claude stays the one who thinks and answers; OpenAI only speaks Claude's
/// words and draws what Claude describes.
///
/// Locked down like `ClaudeClient`: an ephemeral session (no cache, cookies
/// or stored credentials), no redirects, TLS 1.2 or newer, and the key read
/// from the Keychain per request and never logged.
@MainActor
enum OpenAIClient {
    /// Speaks text it's given (the replacement OpenAI names for its old
    /// text-to-speech models).
    static let voiceModel = "gpt-realtime-2.1-mini"
    /// Fast, everyday image generation.
    static let imageModel = "gpt-image-2.6-flare"

    private static let modelsURL = URL(string: "https://api.openai.com/v1/models")!
    private static let imagesURL = URL(string: "https://api.openai.com/v1/images/generations")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        // Images can take a minute or two.
        configuration.timeoutIntervalForRequest = 180
        return URLSession(configuration: configuration, delegate: OpenAIRefuseRedirects(), delegateQueue: nil)
    }()

    /// Checks a key with a free request (listing models) before it's saved.
    static func validate(key: String) async throws {
        var request = URLRequest(url: modelsURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform { try await session.data(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OpenAIError(status: status, body: data) }
    }

    /// Draws a square picture for the page and returns it as PNG data.
    static func generateImage(prompt: String, transparent: Bool) async throws -> Data {
        guard let key = OpenAIKeyStore.read() else { throw OpenAIError.noKey }
        let body: [String: Any] = [
            "model": imageModel,
            "prompt": prompt,
            "size": "1024x1024",
            "quality": "medium",
            "background": transparent ? "transparent" : "auto",
            "output_format": "png",
            "n": 1,
        ]
        var request = URLRequest(url: imagesURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform { try await session.data(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OpenAIError(status: status, body: data) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first,
              let base64 = first["b64_json"] as? String,
              let image = Data(base64Encoded: base64) else {
            throw OpenAIError.other("OpenAI didn't send back an image.")
        }
        return image
    }

    /// A connection to the realtime voice, not yet started.
    static func voiceSocket() throws -> URLSessionWebSocketTask {
        guard let key = OpenAIKeyStore.read() else { throw OpenAIError.noKey }
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: voiceModel)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return session.webSocketTask(with: request)
    }

    /// A short, text-only request to the realtime model on a connection of
    /// its own, like writing down what the study pal remembers after a call.
    @MainActor
    static func writeText(instructions: String, input: String) async throws -> String {
        let socket = try voiceSocket()
        socket.resume()
        // Never wait forever.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(45))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }
        let session: [String: Any] = ["type": "realtime", "output_modalities": ["text"], "instructions": instructions]
        let item: [String: Any] = ["type": "message", "role": "user", "content": [["type": "input_text", "text": input]]]
        let events: [[String: Any]] = [
            ["type": "session.update", "session": session],
            ["type": "conversation.item.create", "item": item],
            ["type": "response.create"],
        ]
        for event in events {
            let data = try JSONSerialization.data(withJSONObject: event)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        }
        var text = ""
        while true {
            let message = try await socket.receive()
            guard case .string(let raw) = message,
                  let event = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "response.output_text.delta", "response.text.delta":
                text += event["delta"] as? String ?? ""
            case "response.done":
                let response = event["response"] as? [String: Any]
                if text.isEmpty { text = outputText(of: response) }
                if text.isEmpty,
                   let details = response?["status_details"] as? [String: Any],
                   let error = details["error"] as? [String: Any] {
                    throw OpenAIError(status: 0, message: error["message"] as? String ?? "", code: error["code"] as? String)
                }
                return text
            case "error":
                let error = event["error"] as? [String: Any]
                throw OpenAIError(status: 0, message: error?["message"] as? String ?? "", code: error?["code"] as? String)
            default:
                continue
            }
        }
    }

    /// The text of a finished realtime response: what it wrote, or the
    /// transcript of what it said.
    static func outputText(of response: [String: Any]?) -> String {
        var pieces: [String] = []
        let items = response?["output"] as? [[String: Any]] ?? []
        for item in items where item["type"] as? String == "message" {
            let parts = item["content"] as? [[String: Any]] ?? []
            for part in parts {
                if let text = part["text"] as? String {
                    pieces.append(text)
                } else if let transcript = part["transcript"] as? String {
                    pieces.append(transcript)
                }
            }
        }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns network failures into a readable error.
    private static func perform<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw OpenAIError.network(error.localizedDescription)
        }
    }
}

/// Never follow a redirect: the request carries the API key.
private final class OpenAIRefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum OpenAIError: LocalizedError {
    case noKey
    case invalidKey
    case needsVerification
    case noCredits
    case rateLimited
    case network(String)
    case other(String)

    init(status: Int, body: Data) {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        self.init(status: status, message: error?["message"] as? String ?? "", code: error?["code"] as? String)
    }

    init(status: Int, message: String, code: String?) {
        if status == 401 || code == "invalid_api_key" {
            self = .invalidKey
        } else if message.localizedCaseInsensitiveContains("verif") {
            self = .needsVerification
        } else if code == "insufficient_quota" || message.localizedCaseInsensitiveContains("quota")
                    || message.localizedCaseInsensitiveContains("billing") {
            self = .noCredits
        } else if status == 429 {
            self = .rateLimited
        } else {
            self = .other(message.isEmpty ? "Something went wrong with OpenAI (\(status))." : message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .noKey: "Add an OpenAI API key in Settings first."
        case .invalidKey: "OpenAI didn't accept this API key. Check it or create a new one at platform.openai.com."
        case .needsVerification: "OpenAI needs your organization verified before it draws images. Do it at platform.openai.com → Settings → Organization."
        case .noCredits: "Your OpenAI account is out of credits. Add some at platform.openai.com → Billing."
        case .rateLimited: "OpenAI is getting too many requests right now. Wait a moment and try again."
        case .network(let description): "Couldn't reach OpenAI: \(description)"
        case .other(let message): message
        }
    }
}
