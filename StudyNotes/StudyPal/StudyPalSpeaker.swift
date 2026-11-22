import AVFAudio
import Foundation
import os

/// The study pal's speaking voice, from OpenAI's realtime model. It only
/// reads out what she wrote (`begin(answering:)`, then `feed` as her reply
/// streams in), starting at the first natural break, so she sounds quick.
/// It also says short samples, for trying voices out in Settings.
///
/// Needs an OpenAI key, and Settings can turn it off (`isEnabledKey`) and
/// pick her voice (`voiceKey`).
@MainActor
@Observable
final class StudyPalSpeaker {
    /// The setting for speaking replies to voice messages; on unless turned off.
    nonisolated static let isEnabledKey = "studyPal.speaks"
    /// The setting for which voice she uses.
    nonisolated static let voiceKey = "studyPal.voice"
    nonisolated static let defaultVoice = "marin"
    /// The realtime voices. OpenAI recommends marin and cedar for quality.
    nonisolated static let voices = ["marin", "cedar", "coral", "sage", "shimmer", "ballad", "alloy", "ash", "echo", "verse"]
    nonisolated static let recommendedVoices: Set<String> = ["marin", "cedar"]

    /// A voice to use instead of the chosen one (Settings, trying voices out).
    @ObservationIgnored var voiceOverride: String?
    /// The voice the open connection speaks with. A voice can't change once
    /// a connection has spoken, so a different one means a new connection.
    @ObservationIgnored private var connectedVoice: String?
    /// This is an answer, not a voice sample: finishing it counts.
    @ObservationIgnored private var countsAsAnswer = false

    private var voice: String {
        voiceOverride ?? UserDefaults.standard.string(forKey: Self.voiceKey) ?? Self.defaultVoice
    }

    // How long each step takes, in the log (durations only, never text),
    // so the wait can be measured.
    private static let log = Logger(subsystem: "com.denasohrabi.memor", category: "voice")
    @ObservationIgnored private var askedAt: ContinuousClock.Instant?
    @ObservationIgnored private var loggedFirstText = false
    @ObservationIgnored private var loggedFirstAudio = false
    /// How she speaks. The realtime model is a talker, so it's told plainly
    /// to read, not to answer.
    private static let style = """
        You are the voice of a small, soft, friendly creature: a study pal. You never decide what to say. \
        Say exactly the text you're given, word for word, in the language it's written in. \
        Don't add, skip, answer or comment on anything. \
        Speak softly and warmly, gently and a little playfully, at a relaxed pace, \
        like a kind friend sitting next to someone who's studying.
        """

    /// From her first word of an answer until she's said all of it (or
    /// was stopped), pauses between sentences included.
    private(set) var isTalking = false
    /// Goes up each time she finishes saying a whole answer.
    private(set) var finishedAnswers = 0
    /// Why she couldn't speak the last answer, if something went wrong.
    private(set) var problem: String?

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    /// The voice is set up and ready for text.
    @ObservationIgnored private var isReady = false
    /// A piece of the answer is being turned into speech.
    @ObservationIgnored private var isResponding = false
    /// Finished sentences waiting for her to say them.
    @ObservationIgnored private var waiting = ""
    /// How much of the answer (its Markdown) she's been handed.
    @ObservationIgnored private var handed = 0
    @ObservationIgnored private var isOnAnswer = false
    @ObservationIgnored private var answerIsComplete = false

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var isEngineSetUp = false
    @ObservationIgnored private let buffers = PendingBuffers()
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    /// 16-bit mono at 24 kHz comes in; the player takes floats.
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    /// Whether she'll speak: there's an OpenAI key and it's turned on.
    var isAvailable: Bool { Self.isTurnedOn }

    nonisolated static var isTurnedOn: Bool {
        OpenAIKeyStore.hasKey && (UserDefaults.standard.object(forKey: isEnabledKey) as? Bool ?? true)
    }

    /// Connects ahead of time (as you start talking), so she can answer the
    /// moment her first sentence is ready.
    func warmUp() {
        guard isAvailable else { return }
        connect()
        // If no answer comes to say, the connection goes again.
        if !isOnAnswer { closeWhenIdle() }
    }

    /// Gets ready to say her answer to what you just said. (While she
    /// thinks, she hums; see `StudyPalSceneView`.)
    func begin(answering question: String) {
        stop()
        guard isAvailable else { return }
        problem = nil
        isOnAnswer = true
        answerIsComplete = false
        handed = 0
        waiting = ""
        askedAt = .now
        loggedFirstText = false
        loggedFirstAudio = false
        countsAsAnswer = true
        connect()
    }

    /// Says `text` in the current voice, to try a voice out.
    func preview(_ text: String) {
        stop()
        countsAsAnswer = false
        problem = nil
        isOnAnswer = true
        answerIsComplete = true
        handed = 0
        waiting = text
        askedAt = nil
        connect()
        sayWhatsWaiting()
        watchPlayback()
    }

    /// Hands her the answer so far. She starts at its first natural break,
    /// then says each sentence once it's complete, and the rest once the
    /// answer is.
    func feed(_ markdown: String, isComplete: Bool) {
        guard isOnAnswer else { return }
        if !loggedFirstText, !markdown.isEmpty, let askedAt {
            loggedFirstText = true
            Self.log.notice("First answer text after \(Self.seconds(since: askedAt), privacy: .public)s")
        }
        if markdown.count > handed {
            let rest = markdown.dropFirst(handed)
            let soonest = handed == 0 ? Self.firstBreak(in: rest) : nil
            if let end = isComplete ? rest.endIndex : Self.lastSentenceEnd(in: rest) ?? soonest, end > rest.startIndex {
                let chunk = String(rest[..<end])
                handed += chunk.count
                let text = Self.spoken(chunk)
                if !text.isEmpty { waiting += waiting.isEmpty ? text : " " + text }
            }
        }
        if isComplete { answerIsComplete = true }
        sayWhatsWaiting()
        watchPlayback()
    }

    /// Stops talking now: you interrupted her, or closed her.
    func stop() {
        isOnAnswer = false
        waiting = ""
        if isResponding {
            send(["type": "response.cancel"])
            isResponding = false
        }
        if isEngineSetUp { player.stop() }
        buffers.reset()
        watchTask?.cancel()
        isTalking = false
    }

    // MARK: Speaking

    private func sayWhatsWaiting() {
        guard isReady, !isResponding, !waiting.isEmpty else { return }
        let text = waiting
        waiting = ""
        isResponding = true
        isTalking = true
        // Out of band and with no context: each piece is read on its own,
        // and nothing builds up in a conversation on OpenAI's side.
        send([
            "type": "response.create",
            "response": [
                "conversation": "none",
                "output_modalities": ["audio"],
                "input": [] as [Any],
                "instructions": Self.style + "\n\nThe text to say:\n\n" + text,
            ] as [String: Any],
        ])
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "session.updated":
            isReady = true
            sayWhatsWaiting()
        case "response.output_audio.delta":
            if isOnAnswer, let delta = event["delta"] as? String {
                isTalking = true
                play(delta)
            }
        case "response.done":
            isResponding = false
            sayWhatsWaiting()
            watchPlayback()
        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? ""
            // Cancelling when there's nothing to cancel isn't a problem.
            guard (error?["code"] as? String) != "response_cancel_not_active" else { return }
            problem = OpenAIError(status: 0, message: message, code: error?["code"] as? String).localizedDescription
            isResponding = false
            sayWhatsWaiting()
            watchPlayback()
        default:
            break
        }
    }

    // MARK: Audio

    private func play(_ base64: String) {
        guard let data = Data(base64Encoded: base64), data.count >= 2 else { return }
        let frames = data.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                channel[i] = Float(sample) / 32_768
            }
        }
        guard startAudio() else { return }
        if !loggedFirstAudio, let askedAt {
            loggedFirstAudio = true
            Self.log.notice("First audio after \(Self.seconds(since: askedAt), privacy: .public)s")
        }
        buffers.add()
        // Called on the audio thread: it only counts down.
        let buffers = self.buffers
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
            buffers.finish()
        }
        if !player.isPlaying { player.play() }
    }

    private func startAudio() -> Bool {
        if !isEngineSetUp {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.format)
            isEngineSetUp = true
        }
        if engine.isRunning { return true }
        do {
            // Through the speaker, with other audio ducked; the same setup
            // she listens with, so going back and forth doesn't glitch.
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try audio.setActive(true, options: [])
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// Notices when she's said everything, and then lets the audio and the
    /// connection go after a while.
    private func watchPlayback() {
        guard watchTask == nil || watchTask?.isCancelled == true else { return }
        watchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                let quiet = !isResponding && waiting.isEmpty && buffers.isEmpty
                if quiet, answerIsComplete || !isOnAnswer {
                    if isOnAnswer, countsAsAnswer { finishedAnswers += 1 }
                    isTalking = false
                    isOnAnswer = false
                    watchTask = nil
                    closeWhenIdle()
                    return
                }
            }
        }
    }

    private func closeWhenIdle() {
        closeTask?.cancel()
        closeTask = Task {
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, !isTalking else { return }
            disconnect()
            if engine.isRunning { engine.stop() }
        }
    }

    // MARK: Connection

    private func connect() {
        closeTask?.cancel()
        // A connection speaks in one voice; for another, start afresh.
        if socket != nil, connectedVoice != voice { disconnect() }
        guard socket == nil else { return }
        let socket: URLSessionWebSocketTask
        do {
            socket = try OpenAIClient.voiceSocket()
        } catch {
            problem = error.localizedDescription
            return
        }
        self.socket = socket
        connectedVoice = voice
        isReady = false
        socket.resume()
        let session: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "instructions": Self.style,
            "audio": [
                // No turn detection: she only reads out what she's given.
                "input": ["turn_detection": NSNull()],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24_000] as [String: Any],
                    "voice": voice,
                ] as [String: Any],
            ] as [String: Any],
        ]
        send(["type": "session.update", "session": session])
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await socket.receive()
                } catch {
                    self?.connectionLost(socket)
                    return
                }
                guard case .string(let text) = message,
                      let data = text.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                self?.handle(event)
            }
        }
    }

    private func connectionLost(_ lost: URLSessionWebSocketTask) {
        guard lost === socket else { return }
        socket = nil
        isReady = false
        isResponding = false
        if isOnAnswer, !waiting.isEmpty {
            problem = "I lost my voice for a moment. My answer is in the chat."
        }
    }

    private func disconnect() {
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isReady = false
        isResponding = false
    }

    private func send(_ event: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        // Called on URLSession's queue; it has nothing to do.
        socket.send(.string(text)) { @Sendable _ in }
    }

    // MARK: Text

    /// The answer as she'd say it: plain words, no Markdown or bullets.
    private static func spoken(_ markdown: String) -> String {
        MarkdownText.plainText(markdown)
            .replacingOccurrences(of: "•", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the last finished sentence in `text` ends: after ".", "!",
    /// "?" or "…" followed by a space, or at a line break.
    private static func lastSentenceEnd(in text: Substring) -> Substring.Index? {
        var end: Substring.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\n" {
                end = next
            } else if ".!?…".contains(character), next < text.endIndex, text[next] == " " || text[next] == "\n" {
                end = next
            }
            index = next
        }
        return end
    }

    /// The first natural break, so she can start before a whole sentence is
    /// in: after a comma, semicolon, colon or dash followed by a space,
    /// once there are at least five words to say.
    private static func firstBreak(in text: Substring) -> Substring.Index? {
        var words = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == " " { words += 1 }
            if words >= 5, ",;:—–".contains(character), next < text.endIndex, text[next] == " " {
                return next
            }
            index = next
        }
        return nil
    }

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        return String(format: "%.2f", milliseconds / 1_000)
    }
}

/// Counts audio buffers still to be played. The player reports each one
/// done on its own thread, so the count is behind a lock.
private final class PendingBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count <= 0
    }

    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func finish() {
        lock.lock()
        count -= 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}
