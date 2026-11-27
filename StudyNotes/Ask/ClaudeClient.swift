import Foundation

/// Talks to the Claude API straight from the iPad, with the user's own key.
/// There is no Memor server in between.
///
/// Raw HTTP, because there is no official Anthropic SDK for Swift. The
/// connection is locked down so the key can't end up anywhere but
/// api.anthropic.com:
/// - an ephemeral session: no disk cache, no cookies, no stored credentials;
/// - redirects are refused, so the key header is never sent to another host;
/// - TLS 1.2 or newer (App Transport Security also requires HTTPS);
/// - the key is read from the Keychain per request and never logged or
///   included in error messages.
@MainActor
enum ClaudeClient {
    /// The study pal's mind, when it's Claude, unless another Claude model
    /// is picked in Settings (`PalBrainModel`).
    static let model = "claude-opus-5-5"
    /// Quick, cheap jobs in the background (her memory).
    static let choresModel = "claude-haiku-5-5"
    private static let apiVersion = "2026-10-21"
    /// Opt-in server-side fallback (if a safety classifier declines, the API
    /// retries on a fallback model within the same request), and the
    /// controls that let a reply's thinking be dropped rather than fail the
    /// request if the history ever doesn't match.
    private static let betas = "server-side-fallback-2026-07-01,thinking-binding-controls-2026-08-01"
    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let modelsURL = URL(string: "https://api.anthropic.com/v1/models")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = 120
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    /// Checks a key with a free request (listing models) before it's saved.
    static func validate(key: String) async throws {
        var request = URLRequest(url: modelsURL)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await perform { try await session.data(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ClaudeError(status: status, body: data) }
    }

    /// Sends a Messages request with `stream: true` and hands each server
    /// event (a parsed JSON object) to `onEvent` as it arrives. The tokens
    /// it used go into the usage log as `purpose`, with `turn`: the message
    /// it answers.
    static func stream(body: [String: Any], for purpose: AIPurpose, turn: UUID? = nil, onEvent: ([String: Any]) -> Void) async throws {
        var body = body
        body["stream"] = true
        let meter = ClaudeUsageMeter(model: body["model"] as? String ?? Self.model, purpose: purpose, turn: turn)
        try await stream(body: JSONSerialization.data(withJSONObject: body), meter: meter, onEvent: onEvent)
    }

    private static func stream(body: Data, meter: ClaudeUsageMeter, onEvent: ([String: Any]) -> Void) async throws {
        guard let key = APIKeyStore.read() else { throw ClaudeError.noKey }
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(betas, forHTTPHeaderField: "anthropic-beta")

        let (bytes, response) = try await perform { try await session.bytes(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw ClaudeError(status: status, body: data)
        }
        // What it used so far is billed even if it's stopped or fails.
        defer { meter.finish() }
        // Stopping in the middle is a cancellation, not a network error.
        try await perform {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if event["type"] as? String == "error" {
                    throw ClaudeError(eventError: event["error"] as? [String: Any])
                }
                meter.read(event)
                onEvent(event)
            }
        }
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
            throw ClaudeError.network(error.localizedDescription)
        }
    }
}

/// Never follow a redirect: the request carries the API key.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
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

enum ClaudeError: LocalizedError {
    case noKey
    case invalidKey
    case noCredits
    case rateLimited
    case overloaded
    case network(String)
    case other(String)

    init(status: Int, body: Data) {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        self.init(status: status, error: error)
    }

    init(eventError: [String: Any]?) {
        self.init(status: 0, error: eventError)
    }

    private init(status: Int, error: [String: Any]?) {
        let type = error?["type"] as? String
        let message = error?["message"] as? String ?? ""
        if status == 401 || type == "authentication_error" {
            self = .invalidKey
        } else if message.localizedCaseInsensitiveContains("credit balance") {
            self = .noCredits
        } else if status == 429 || type == "rate_limit_error" {
            self = .rateLimited
        } else if status == 529 || status == 503 || type == "overloaded_error" {
            self = .overloaded
        } else {
            self = .other(message.isEmpty ? "Something went wrong (\(status))." : message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .noKey: "Add your Claude API key first."
        case .invalidKey: "Anthropic didn't accept this API key. Check it or create a new one at platform.claude.com."
        case .noCredits: "Your Anthropic account is out of credits. Add some at platform.claude.com → Billing."
        case .rateLimited: "Too many requests right now. Wait a moment and try again."
        case .overloaded: "Claude is busy right now. Try again in a moment."
        case .network(let description): "Couldn't reach Anthropic: \(description)"
        case .other(let message): message
        }
    }
}
