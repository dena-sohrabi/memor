import AVFAudio
import Foundation
import os
import UIKit

/// A live voice call with the study pal, through OpenAI's GPT-Live and your
/// Memor Live server (`LiveServerStore`), which holds the OpenAI key.
///
/// Tap her in Voice mode and the call starts; just talk. GPT-Live listens
/// and speaks at once: it hears when you've finished and answers right
/// away, and stops when you talk over it. It's her voice and ears only.
/// Anything about your pages, or any real question, it hands to her mind
/// (`PalBrain`, Claude or GPT with all her tools) through `onDelegate`;
/// her mind's answer comes back with `answer(_:for:)`, and GPT-Live says
/// it in her voice. Tap her again to hang up; after 30 seconds with
/// nothing said by either of you, she hangs up herself, so a call is never
/// left running (it's billed by the minute while it's open).
///
/// The microphone and her voice share one audio engine with the iPad's
/// echo cancellation on, so she doesn't hear herself through the speaker.
@MainActor
@Observable
final class PalCall {
    enum State: Equatable {
        case idle
        /// Connecting to the server and starting the session.
        case connecting
        case live
        /// Hanging up: waiting a moment for the session's last word.
        case ending
    }

    /// The GPT-Live model.
    nonisolated static let model = "gpt-live-1.1"
    /// With nothing said by either of you for this long, she hangs up.
    private static let quietLimit: Duration = .seconds(30)
    /// While her mind works (or waits on a card for you), a quiet spell
    /// can be this long; past it, she hangs up anyway, so a call never runs
    /// on unattended.
    private static let workingLimit: Duration = .seconds(180)
    /// A call that hasn't started after this long gives up.
    private static let connectLimit: Duration = .seconds(15)

    private(set) var state = State.idle
    /// How loud you are right now, 0 to 1.
    private(set) var level: Float = 0
    /// Her voice is playing.
    private(set) var isTalking = false
    /// Why the last call couldn't start, or ended early.
    private(set) var problem: String?

    var isOn: Bool { state != .idle }

    /// She handed something to her mind: its id, and what you said since
    /// the last hand-off. Answer with `answer(_:for:)`.
    @ObservationIgnored var onDelegate: ((_ id: String, _ request: String) -> Void)?
    /// Her mind is working on something, so a quiet spell isn't the end.
    @ObservationIgnored var isMindWorking: () -> Bool = { false }
    /// The words on your open pages and what you're studying.
    @ObservationIgnored var context: () -> SpeechContext = { SpeechContext() }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var audio: PalCallAudio?
    /// Bumped each time a call starts or ends, so late events from an
    /// earlier call don't count.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var batch = Data()
    /// What you said before the session was ready, sent once it is.
    @ObservationIgnored private var early: [Data] = []
    @ObservationIgnored private var earlyBytes = 0
    /// What you've said since her last hand-off, as GPT-Live heard it.
    @ObservationIgnored private var heard = ""
    /// How far into the call (ms) the transcript of what you said reaches.
    @ObservationIgnored private var heardUpTo: Int?
    /// When the last of what you said arrived.
    @ObservationIgnored private var lastHeardAt: ContinuousClock.Instant?
    /// When the last piece of sound with her voice in it arrived.
    @ObservationIgnored private var lastAudibleAt: ContinuousClock.Instant?
    // For the log, every couple of seconds: how loud you were, and how many
    // pieces of her sound came, and how many had her voice in them.
    @ObservationIgnored private var micPeak: Float = 0
    @ObservationIgnored private var framesIn = 0
    @ObservationIgnored private var framesAudible = 0
    @ObservationIgnored private var lastSoundLog = ContinuousClock.now
    @ObservationIgnored private var lastActivity = ContinuousClock.now
    @ObservationIgnored private var connectedAt = ContinuousClock.now
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    /// The call's length so far, as OpenAI bills it.
    @ObservationIgnored private var reportedSeconds: Double?

    private static let log = Logger(subsystem: "com.denasohrabi.memor", category: "voice")
    private static let batchBytes = PalTranscriber.bytesPerSecond / 10

    // MARK: Starting and ending

    func start() {
        guard state == .idle else { return }
        problem = nil
        let socket: URLSessionWebSocketTask
        do {
            socket = try LiveServerStore.socket()
        } catch {
            problem = error.localizedDescription
            return
        }
        generation += 1
        let generation = generation
        state = .connecting
        heard = ""
        heardUpTo = nil
        lastHeardAt = nil
        lastAudibleAt = nil
        micPeak = 0
        framesIn = 0
        framesAudible = 0
        batch = Data()
        early = []
        earlyBytes = 0
        reportedSeconds = nil
        startedAt = nil
        lastActivity = .now
        connectedAt = .now
        self.socket = socket
        socket.resume()
        // Sent first; the audio that follows is handled after it, in order.
        send(sessionStart())
        receive(on: socket, generation: generation)
        watch(generation: generation)
        watchApp(generation: generation)
        Task {
            // The microphone starts while the call connects, so the first
            // words aren't lost.
            if let problem = await SpeechCapture.prepareMicrophone() {
                guard self.generation == generation else { return }
                finish(problem: problem)
                return
            }
            guard self.generation == generation, isOn else { return }
            let audio = PalCallAudio()
            // Unbounded: none of what you say may be dropped.
            let (events, sink) = AsyncStream.makeStream(of: SpeechEvent.self)
            do {
                try audio.start(events: sink)
            } catch {
                audio.stop()
                finish(problem: "The microphone didn't start. Try again.")
                return
            }
            self.audio = audio
            for await event in events {
                guard self.generation == generation else { return }
                switch event {
                case .audio(let data):
                    hear(data)
                case .level(let level):
                    micPeak = max(micPeak, level)
                    if abs(level - self.level) > 0.03 { self.level = level }
                }
            }
        }
    }

    /// Hangs up. `now`: without waiting for the session's last word (the
    /// app is going away, so the wait wouldn't run).
    func end(now: Bool = false, problem: String? = nil) {
        switch state {
        case .idle:
            return
        case .ending:
            if now { finish(problem: problem) }
        case .connecting:
            finish(problem: problem)
        case .live:
            state = .ending
            flush()
            // OpenAI answers with the call's final length, for the usage log.
            send(["type": "session.close"])
            if now {
                finish(problem: problem)
                return
            }
            if let problem { self.problem = problem }
            let generation = generation
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.generation == generation { finish(problem: nil) }
            }
        }
    }

    func clearProblem() {
        problem = nil
    }

    // MARK: Her mind

    /// Her mind's answer to a hand-off: GPT-Live says it, in her voice.
    func answer(_ markdown: String, for delegation: String) {
        guard state == .live else { return }
        lastActivity = .now
        for piece in Self.pieces(of: Self.spoken(markdown)) {
            send(["type": "session.commentary.append", "delegation_id": delegation, "content": piece])
        }
    }

    /// Something her mind is doing, for GPT-Live to know about without
    /// saying it.
    func note(_ markdown: String, for delegation: String) {
        guard state == .live else { return }
        let text = Self.spoken(markdown)
        guard !text.isEmpty else { return }
        send(["type": "session.thinking.append", "delegation_id": delegation, "content": String(text.prefix(Self.pieceLimit))])
    }

    /// An answer she wasn't asked for in the call (you circled something,
    /// or tapped Try Again): GPT-Live says it now.
    func say(_ markdown: String) {
        guard state == .live else { return }
        lastActivity = .now
        for piece in Self.pieces(of: Self.spoken(markdown)) {
            send([
                "type": "session.instructions.append",
                "delegation_id": NSNull(),
                "content": "Say this to them now, warmly and in your own voice, keeping its meaning and every term, name and number exactly: " + piece,
            ])
        }
    }

    // MARK: Sound

    /// What you're saying: once the session is ready, it streams 100 ms at
    /// a time; before then, the last few seconds wait for it.
    private func hear(_ data: Data) {
        guard state == .live else {
            guard state == .connecting else { return }
            early.append(data)
            earlyBytes += data.count
            while earlyBytes > PalTranscriber.bytesPerSecond * 5, !early.isEmpty {
                earlyBytes -= early.removeFirst().count
            }
            return
        }
        batch.append(data)
        if batch.count >= Self.batchBytes { flush() }
    }

    private func flush() {
        guard !batch.isEmpty else { return }
        send(["type": "session.input_audio.append", "audio": batch.base64EncodedString()])
        batch = Data()
    }

    /// Notices when her voice stops, gives up on a call that never starts,
    /// and hangs up after a quiet spell (a longer one while her mind works).
    private func watch(generation: Int) {
        watchTask?.cancel()
        watchTask = Task {
            while !Task.isCancelled, self.generation == generation {
                try? await Task.sleep(for: .milliseconds(200))
                guard self.generation == generation else { return }
                // GPT-Live sends sound all through the call, ten pieces a
                // second, silent ones too: she's talking only while pieces
                // with her voice in them are coming.
                let talking = lastAudibleAt.map { ContinuousClock.now - $0 < .milliseconds(400) } ?? false
                if isTalking != talking { isTalking = talking }
                logSound()
                switch state {
                case .connecting where ContinuousClock.now - connectedAt >= Self.connectLimit:
                    finish(problem: "The call didn't start: your Live server didn't answer in time. Tap me to try again.")
                case .live:
                    let limit = isMindWorking() ? Self.workingLimit : Self.quietLimit
                    if ContinuousClock.now - lastActivity >= limit {
                        Self.log.notice("Live call: hung up after a quiet spell")
                        end()
                    }
                default:
                    break
                }
            }
        }
    }

    /// Logs how the call's sound is doing, every couple of seconds: numbers
    /// only, never what was said.
    private func logSound() {
        guard ContinuousClock.now - lastSoundLog >= .seconds(2) else { return }
        lastSoundLog = .now
        let mic = String(format: "%.2f", micPeak)
        let engine = audio?.status ?? "no audio"
        Self.log.notice("Live call sound: mic peak \(mic, privacy: .public), her pieces \(self.framesIn, privacy: .public) (\(self.framesAudible, privacy: .public) with voice), \(engine, privacy: .public)")
        micPeak = 0
        framesIn = 0
        framesAudible = 0
    }

    /// Hangs up when Memor goes to the background (it can't keep a call
    /// going there), or when another app or a phone call takes the audio.
    private func watchApp(generation: Int) {
        stopWatchingApp()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard self.generation == generation else { return }
                self.end(now: true)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated {
                guard began, self.generation == generation else { return }
                self.end(now: true, problem: "The call ended: another app or call took the sound.")
            }
        })
    }

    private func stopWatchingApp() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    // MARK: Events

    private func receive(on socket: URLSessionWebSocketTask, generation: Int) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await socket.receive()
                } catch {
                    self?.lost(socket, generation: generation)
                    return
                }
                guard case .string(let text) = message,
                      let data = text.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                self?.handle(event, generation: generation)
            }
        }
    }

    private func handle(_ event: [String: Any], generation: Int) {
        guard self.generation == generation else { return }
        switch event["type"] as? String {
        case "session.started":
            guard state == .connecting else { return }
            state = .live
            startedAt = .now
            lastActivity = .now
            Self.log.notice("Live call started")
            // What you said while it connected, 100 ms at a time.
            for chunk in early {
                batch.append(chunk)
                if batch.count >= Self.batchBytes { flush() }
            }
            early = []
            earlyBytes = 0
            flush()
        case "session.output_audio.delta":
            guard state == .live, let delta = event["delta"] as? String, let data = Data(base64Encoded: delta) else { return }
            // Every piece is played, silent ones too, so her voice keeps
            // its timing; only pieces with her voice in them count as
            // talking (and keep the call from hanging up).
            audio?.play(data)
            framesIn += 1
            if Self.loudness(of: data) > Self.audibleLoudness {
                framesAudible += 1
                lastAudibleAt = .now
                lastActivity = .now
                isTalking = true
            }
        case "session.input_transcript.delta":
            if let delta = event["delta"] as? String, !delta.isEmpty {
                // Appended exactly as received: the pieces carry their own spaces.
                heard += delta
                if heard.count > 2_000 { heard = String(heard.suffix(2_000)) }
                lastActivity = .now
                lastHeardAt = .now
                // You're talking over her: GPT-Live stops, and so does what
                // was already on its way to the speaker.
                if !delta.trimmingCharacters(in: .whitespaces).isEmpty, isTalking {
                    audio?.clear()
                    isTalking = false
                    lastAudibleAt = nil
                }
            }
            if let end = (event["end_ms"] as? NSNumber)?.intValue {
                heardUpTo = max(heardUpTo ?? 0, end)
            }
        case "session.output_transcript.delta":
            lastActivity = .now
        case "session.delegation.created":
            let delegation = event["delegation"] as? [String: Any]
            guard state == .live, let id = delegation?["id"] as? String else { return }
            delegated(id, at: (event["offset_ms"] as? NSNumber)?.intValue, generation: generation)
        case "session.usage.updated":
            // A running total.
            if let seconds = Self.seconds(in: event) { reportedSeconds = seconds }
        case "session.closed":
            if let seconds = Self.seconds(in: event) { reportedSeconds = seconds }
            let reason = event["reason"] as? String
            finish(problem: state == .ending ? nil : Self.closingProblem(reason))
        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? ""
            let code = error?["code"] as? String
            Self.log.error("Live call error: \(code ?? "no code", privacy: .public)")
            // Before the call is up, or from the server itself (it failed,
            // or the call hit its time limit), it can't go on. Later, it's a
            // command that was refused; the call goes on.
            if state == .connecting || code?.hasPrefix("relay_") == true {
                finish(problem: OpenAIError(status: 0, message: message, code: code).localizedDescription)
            }
        default:
            break
        }
    }

    /// She handed off to her mind. What you said can reach the transcript a
    /// moment after she decides to, so it waits until the transcript has
    /// caught up with that moment, or has gone quiet for a moment after
    /// your words, or a little over a second at most.
    private func delegated(_ id: String, at offset: Int?, generation: Int) {
        lastActivity = .now
        let handedOffAt = ContinuousClock.now
        Task {
            while ContinuousClock.now - handedOffAt < .milliseconds(1_200) {
                if let offset, let heardUpTo, heardUpTo >= offset - 250 { break }
                if !heard.isEmpty, let lastHeardAt, ContinuousClock.now - lastHeardAt >= .milliseconds(300) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard self.generation == generation, state == .live else { return }
            let request = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            heard = ""
            onDelegate?(id, request)
        }
    }

    private func lost(_ lostSocket: URLSessionWebSocketTask, generation: Int) {
        guard self.generation == generation, lostSocket === socket else { return }
        guard state != .ending else {
            finish(problem: nil)
            return
        }
        let status = (lostSocket.response as? HTTPURLResponse)?.statusCode
        let problem: String
        if status == 401 {
            problem = "Your Live server didn't accept the token. Check it in Settings › Live Calls."
        } else if state == .connecting {
            problem = "I couldn't reach your Live server. Check its address in Settings › Live Calls, and that it's deployed."
        } else {
            problem = "The call dropped. Tap me to call again."
        }
        finish(problem: problem)
    }

    /// The call is over: logs what it cost, and lets the microphone,
    /// speaker and connection go.
    private func finish(problem: String?) {
        guard state != .idle else { return }
        generation += 1
        if let problem { self.problem = problem }
        if let startedAt {
            let elapsed = ContinuousClock.now - startedAt
            let seconds = reportedSeconds ?? Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            OpenAIUsage.recordCall(seconds: seconds, model: Self.model)
            Self.log.notice("Live call ended after \(Int(seconds.rounded()), privacy: .public)s")
        }
        startedAt = nil
        stopWatchingApp()
        receiveTask?.cancel()
        receiveTask = nil
        watchTask?.cancel()
        watchTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        audio?.stop()
        audio = nil
        batch = Data()
        early = []
        earlyBytes = 0
        heard = ""
        level = 0
        isTalking = false
        state = .idle
    }

    private func send(_ event: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        // Called on URLSession's queue; it has nothing to do.
        socket.send(.string(text)) { @Sendable _ in }
    }

    // MARK: The session

    private func sessionStart() -> [String: Any] {
        let voice = UserDefaults.standard.string(forKey: StudyPalSpeaker.voiceKey) ?? StudyPalSpeaker.defaultVoice
        return [
            "type": "session.start",
            "session": [
                "model": Self.model,
                "instructions": Self.instructions(words: context().keywords),
                "audio": [
                    "format": ["type": "audio/pcm", "rate": PalTranscriber.sampleRate] as [String: Any],
                    "output": ["voice": voice],
                ] as [String: Any],
                // Her mind is Memor's own: GPT-Live hands off, Memor answers.
                "delegation": ["type": "client"],
            ] as [String: Any],
        ]
    }

    /// Who she is in a call, when to hand off to her mind, and how to take
    /// turns. The words on your open pages go along, so your terms are
    /// heard right.
    private static func instructions(words: [String]) -> String {
        let who = StudyPalCharacter.name.map { "\($0), the study pal" } ?? "the study pal"
        var text = """
            You are \(who) in Memor, an iPad notes app: a small, soft, pink creature with gray feathered wings who studies with the student. You're their friend, not an assistant: warm, curious, a little cheeky, kind and honest.

            This is a live voice call, and you're her voice and ears. Her mind does the real work: it sees the student's screen, notes and PDFs, remembers them, and can write, draw, mark and change things in the app.

            # When to hand off
            Hand off to the mind for everything except a greeting, thanks or a tiny bit of small talk: every question about what they're studying or their notes, pages or PDFs; every request to write, draw, mark, change, open, find, remember or remind; any fact or explanation, even an easy one; anything you'd need to see their screen for. You can't see their screen, so never guess about it, and never answer study questions from your own knowledge.
            While the mind works, stay quiet, or say one short, natural line at most. When its answer comes, say it warmly in your own voice, keeping its meaning and every term, name and number exactly. Don't add to it, and don't ask a question back.

            # Taking turns
            Never talk while they're talking, and never cut in. Students pause mid-sentence to think: wait until they've clearly finished. No fillers or backchannels ("mm-hmm", "right", "I see"). If they start talking while you're speaking, stop and listen.

            # How you sound
            Softly and warmly, gently and a little playfully, at a relaxed pace, like a kind friend sitting next to them. Keep it short: one to three sentences. Speak English unless they speak another language to you.
            """
        if StudyPalCharacter.name == nil {
            text += "\n\nYou don't have a name yet: it's theirs to give."
        }
        if !words.isEmpty {
            text += "\n\nWords they may say, from the pages they have open (listen for these): " + words.prefix(SpeechVocabulary.limit).joined(separator: ", ")
        }
        return text
    }

    // MARK: Text

    /// An answer as she'd say it: plain words, no Markdown or bullets.
    private static func spoken(_ markdown: String) -> String {
        MarkdownText.plainText(markdown)
            .replacingOccurrences(of: "•", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Characters in one piece of a hand-off reply: well under its 500
    /// tokens, even for symbols, formulas or another language, which take
    /// more tokens per character than English.
    private static let pieceLimit = 900

    /// Text in pieces of whole sentences, each under `pieceLimit`.
    private static func pieces(of text: String, limit: Int = pieceLimit) -> [String] {
        guard !text.isEmpty else { return [] }
        guard text.count > limit else { return [text] }
        var pieces: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            if current.count + sentence.count > limit, !current.isEmpty {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            current += sentence
            while current.count > limit {
                pieces.append(String(current.prefix(limit)))
                current = String(current.dropFirst(limit))
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            pieces.append(current.trimmingCharacters(in: .whitespaces))
        }
        return pieces
    }

    /// A piece of her sound louder than this (RMS, in 16-bit sample units)
    /// has her voice in it; GPT-Live's quiet pieces are all zeros.
    private static let audibleLoudness: Double = 150

    /// How loud a piece of 16-bit PCM is (RMS).
    private static func loudness(of data: Data) -> Double {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                sum += sample * sample
            }
        }
        return (sum / Double(count)).squareRoot()
    }

    private static func seconds(in event: [String: Any]) -> Double? {
        ((event["usage"] as? [String: Any])?["seconds"] as? NSNumber)?.doubleValue
    }

    /// Why the call ended, when OpenAI ended it.
    private static func closingProblem(_ reason: String?) -> String? {
        switch reason {
        case "expired": "The call reached its time limit. Tap me to call again."
        case "content": "OpenAI ended the call."
        case "connection_lost": "The call dropped. Tap me to call again."
        default: nil
        }
    }
}

/// The call's microphone and speaker, in one audio engine with the iPad's
/// voice processing (echo cancellation) on, so she doesn't hear herself
/// through the speaker. Not on the main actor: audio arrives on the audio
/// thread, and the closures that handle it are made here, so they belong
/// to neither. They only pass events along a stream or count buffers.
final class PalCallAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Her voice still to play. Replaced when it's cleared, since the
    /// player reports cleared buffers done later, on its own thread.
    private var pending = PendingBuffers()
    private var events: AsyncStream<SpeechEvent>.Continuation?
    private var isTapped = false
    private var isPlayerAttached = false
    private var configurationObserver: NSObjectProtocol?

    /// 16-bit mono at 24 kHz comes in; the player takes floats.
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private static let log = Logger(subsystem: "com.denasohrabi.memor", category: "voice")

    private enum Failure: Error { case noMicrophone }

    /// Her voice is still playing.
    var isPlaying: Bool { !pending.isEmpty }

    /// For the log: whether the engine runs, where the sound goes, and how
    /// loud the iPad is set.
    var status: String {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
        return "engine \(engine.isRunning ? "running" : "STOPPED"), player \(player.isPlaying ? "playing" : "idle"), out \(route), volume \(String(format: "%.2f", session.outputVolume))"
    }

    /// Starts the microphone, sending how loud it is and the sound itself
    /// (16-bit mono PCM at 24 kHz) to `events`, and gets her voice ready.
    func start(events: AsyncStream<SpeechEvent>.Continuation) throws {
        self.events = events
        let session = AVAudioSession.sharedInstance()
        // A voice call: through the speaker, other audio ducked.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        // Echo cancellation, for the microphone and the speaker together.
        try input.setVoiceProcessingEnabled(true)
        engine.attach(player)
        isPlayerAttached = true
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            events.yield(.level(SpeechCapture.level(of: buffer)))
            let audio = SpeechCapture.pcm16(buffer)
            if !audio.isEmpty { events.yield(.audio(audio)) }
        }
        isTapped = true
        engine.prepare()
        try engine.start()
        player.play()

        // If iPadOS reconfigures the audio mid-call (a route change, say),
        // the engine stops: start it again.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Self.log.notice("Live call audio: configuration changed, engine \(self.engine.isRunning ? "running" : "stopped", privacy: .public)")
            if !self.engine.isRunning {
                try? self.engine.start()
                self.player.play()
            }
        }

        let output = engine.outputNode.outputFormat(forBus: 0)
        let mixer = engine.mainMixerNode.outputFormat(forBus: 0)
        Self.log.notice("""
            Live call audio started: mic \(format.sampleRate, privacy: .public) Hz × \(format.channelCount, privacy: .public), \
            mixer \(mixer.sampleRate, privacy: .public) Hz × \(mixer.channelCount, privacy: .public), \
            output \(output.sampleRate, privacy: .public) Hz × \(output.channelCount, privacy: .public), \
            voice processing in \(input.isVoiceProcessingEnabled, privacy: .public) out \(self.engine.outputNode.isVoiceProcessingEnabled, privacy: .public), \
            \(self.status, privacy: .public)
            """)
    }

    /// Plays a piece of her voice (16-bit mono PCM at 24 kHz).
    func play(_ data: Data) {
        guard data.count >= 2, engine.isRunning else { return }
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
        pending.add()
        // Called on the audio thread: it only counts down.
        let pending = self.pending
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
            pending.finish()
        }
        if !player.isPlaying { player.play() }
    }

    /// Drops what's left of her voice: you started talking over her.
    func clear() {
        guard isPlayerAttached else { return }
        pending = PendingBuffers()
        player.stop()
        if engine.isRunning { player.play() }
    }

    /// Stops the microphone and her voice, and lets the audio session go.
    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
        }
        if isPlayerAttached { player.stop() }
        pending = PendingBuffers()
        if engine.isRunning { engine.stop() }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        events?.finish()
        events = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
