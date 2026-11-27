import SwiftUI

/// Where live calls with the study pal go: your Memor Live server, the small
/// relay in `Server/live-relay` that you run on your own Cloudflare account.
/// It holds the OpenAI key calls are billed to, so the iPad only needs the
/// server's address and a token.
///
/// The address is a plain setting on this iPad; the token is a secret, kept
/// in the Keychain like the API keys (this device only, never in backups).
enum LiveServerStore {
    static let addressKey = "studyPal.liveServer"
    private static let token = KeychainKey(service: "com.denasohrabi.memor.live", account: "live-relay-token")

    /// The address as typed, like "memor-live-relay.you.workers.dev".
    static var address: String { UserDefaults.standard.string(forKey: addressKey) ?? "" }
    static var hasToken: Bool { token.hasKey }

    /// Both an address and a token are saved: tapping her starts a call.
    static var isSetUp: Bool { socketURL(for: address) != nil && hasToken }

    /// The server's call address: `wss://<host>/live`. Typed with or
    /// without https://; anything but https is refused, since the token
    /// goes with it.
    static func socketURL(for address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let host = components.host, !host.isEmpty,
              ["https", "wss"].contains(components.scheme?.lowercased() ?? "") else { return nil }
        components.scheme = "wss"
        if components.path.isEmpty || components.path == "/" { components.path = "/live" }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func save(address: String, token newToken: String?) -> Bool {
        UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: addressKey)
        if let newToken {
            return token.save(newToken.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return true
    }

    static func remove() {
        UserDefaults.standard.removeObject(forKey: addressKey)
        token.delete()
    }

    /// A connection to the server for one call, not yet started.
    static func socket() throws -> URLSessionWebSocketTask {
        guard let url = socketURL(for: address), let secret = token.read() else {
            throw OpenAIError.other("Set up your Live server in Settings › Live Calls first.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return session.webSocketTask(with: request)
    }

    /// Locked down like OpenAI's: nothing cached or stored, no redirects
    /// (the token goes with every request), TLS 1.2 or newer.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration, delegate: LiveServerRefuseRedirects(), delegateQueue: nil)
    }()
}

/// Never follow a redirect: the request carries the token.
private final class LiveServerRefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
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

/// Settings › Live Calls: your Memor Live server's address and token.
struct LiveCallsPage: View {
    @State private var address = LiveServerStore.address
    @State private var token = ""
    @State private var hasToken = LiveServerStore.hasToken
    @State private var isSetUp = LiveServerStore.isSetUp
    @State private var problem: String?
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("memor-live-relay.you.workers.dev", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(hasToken ? "Token (saved; type to replace it)" : "Token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Your Memor Live Server")
            } footer: {
                Text("The server is the relay in Memor's Server/live-relay folder, run on your own Cloudflare account; its README says how to set it up. It holds the OpenAI key calls are billed to. Enter its address and the token you gave it.")
            }

            Section {
                Button("Save", action: save)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || (!hasToken && token.isEmpty))
                if isSetUp || hasToken {
                    Button("Turn Off Live Calls", role: .destructive, action: remove)
                }
            } footer: {
                if let problem {
                    Text(problem).foregroundStyle(.red)
                } else if saved {
                    Text("Saved. Tap her in Voice mode to call her.")
                }
            }

            Section {
                Text("With live calls on, tapping her in Voice mode calls her. Just talk: she hears when you've finished and answers right away, and anything about your pages goes to her mind, which works on them as usual. Tap her again to hang up; she also hangs up after 30 seconds of quiet. A call costs $0.05 a minute while it's open (OpenAI GPT-Live), plus her mind as usual. Without live calls, tapping her records a voice message.")
            } header: {
                Text("How Calls Work")
            }
        }
        .navigationTitle("Live Calls")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        problem = nil
        saved = false
        guard LiveServerStore.socketURL(for: address) != nil else {
            problem = "That doesn't look like a server address. Use the https address wrangler printed, like memor-live-relay.you.workers.dev."
            return
        }
        guard LiveServerStore.save(address: address, token: token.isEmpty ? nil : token) else {
            problem = "The token couldn't be saved in the Keychain. Try again."
            return
        }
        token = ""
        hasToken = LiveServerStore.hasToken
        isSetUp = LiveServerStore.isSetUp
        saved = true
        Pal.shared.keyChanged()
    }

    private func remove() {
        LiveServerStore.remove()
        Pal.shared.endCall()
        address = ""
        token = ""
        hasToken = false
        isSetUp = false
        saved = false
        Pal.shared.keyChanged()
    }
}
