import Foundation

/// Talks to OpenAI straight from the iPad, with the user's own key. There
/// is no Memor server in between. OpenAI does everything for the study pal:
/// - her mind: GPT-6.2 Sol, through the Responses API (`streamResponse`);
/// - small chores, like writing down what she remembers: GPT-6 Luna;
/// - her speaking voice: the realtime model, reading out what she wrote;
/// - the pictures she draws.
///
/// Raw HTTP, locked down so the key can't end up anywhere but
/// api.openai.com: an ephemeral session (no cache, cookies or stored
/// credentials), no redirects, TLS 1.2 or newer, and the key read from the
/// Keychain per request and never logged.
@MainActor
enum OpenAIClient {
    /// Her mind: OpenAI's go-to model for agents, which reads pages and
    /// handwriting and uses many tools well.
    static let brainModel = "gpt-6.2-sol"
    /// Quick, cheap jobs in the background (her memory).
    static let choresModel = "gpt-6-luna"
    /// Speaks text it's given (the replacement OpenAI names for its old
    /// text-to-speech models).
    static let voiceModel = "gpt-realtime-2.1-mini"
    /// Fast, everyday image generation.
    static let imageModel = "gpt-image-2.6-flare"

    private static let modelsURL = URL(string: "https://api.openai.com/v1/models")!
    private static let imagesURL = URL(string: "https://api.openai.com/v1/images/generations")!
    private static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!

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

    // MARK: Responses

    /// Sends a Responses request with `stream: true` and hands each server
    /// event (a parsed JSON object) to `onEvent` as it arrives. A failed or
    /// errored response throws.
    static func streamResponse(body: [String: Any], onEvent: ([String: Any]) -> Void) async throws {
        var body = body
        body["stream"] = true
        let request = try responsesRequest(body: body)
        let (bytes, response) = try await perform { try await session.bytes(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw OpenAIError(status: status, body: data)
        }
        // Stopping in the middle is a cancellation, not a network error.
        try await perform {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]",
                      let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "error":
                    let error = event["error"] as? [String: Any] ?? event
                    throw OpenAIError(status: 0, message: error["message"] as? String ?? "", code: error["code"] as? String)
                case "response.failed":
                    let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
                    throw OpenAIError(status: 0, message: error?["message"] as? String ?? "", code: error?["code"] as? String)
                default:
                    onEvent(event)
                }
            }
        }
    }

    /// A short request that isn't streamed, for chores in the background.
    /// Returns the text it wrote.
    static func respond(body: [String: Any]) async throws -> String {
        var body = body
        body["stream"] = false
        let request = try responsesRequest(body: body)
        let (data, response) = try await perform { try await session.data(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OpenAIError(status: status, body: data) }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return outputText(of: json)
    }

    private static func responsesRequest(body: [String: Any]) throws -> URLRequest {
        guard let key = OpenAIKeyStore.read() else { throw OpenAIError.noKey }
        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The text of a finished response: the text parts of its messages.
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
        return pieces.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// The talk grew longer than the model can read at once.
    case tooLong
    case network(String)
    case other(String)

    init(status: Int, body: Data) {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        self.init(status: status, message: error?["message"] as? String ?? "", code: error?["code"] as? String)
    }

    init(status: Int, message: String, code: String?) {
        if status == 401 || code == "invalid_api_key" {
            self = .invalidKey
        } else if code == "context_length_exceeded" {
            self = .tooLong
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
        case .tooLong: "We've talked so much that I lost track. Tap New Topic and ask me again."
        case .network(let description): "Couldn't reach OpenAI: \(description)"
        case .other(let message): message
        }
    }
}
