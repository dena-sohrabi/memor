import AVFAudio
import Foundation
import Speech

/// Turns what you say to the study pal into text, for voice messages.
/// Recognition runs on the iPad, in English, so your voice never leaves
/// it; only the text goes to her.
///
/// Two ways to talk: hold the mic button while you speak and let go to
/// send (`start(holding: true)`, then `release()`), or tap it, speak, and
/// tap it again (`stop()`). Either way, a pause doesn't cut you off.
@MainActor
@Observable
final class StudyPalListener {
    enum State: Equatable {
        case idle
        /// Asking for permission, or starting the microphone.
        case starting
        case listening
        /// Listening can't work; says why.
        case unavailable(String)
    }

    private(set) var state = State.idle
    /// What you've said so far.
    private(set) var transcript = ""
    /// How loud you are right now, 0 to 1.
    private(set) var level: Float = 0

    /// Something you said, once you stopped talking. A new one has a new `id`.
    struct Heard: Equatable {
        let id: Int
        let text: String
    }

    /// The last thing you said.
    private(set) var heard: Heard?

    var isListening: Bool { state == .starting || state == .listening }

    var problem: String? {
        if case .unavailable(let message) = state { return message }
        return nil
    }

    /// Called with what you said, once you're done.
    @ObservationIgnored var onHeard: ((String) -> Void)?

    @ObservationIgnored private var capture: SpeechCapture?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    /// Bumped each time listening starts or stops, so late results from an
    /// earlier time don't count.
    @ObservationIgnored private var generation = 0
    /// You let go (or tapped again): the last words are being worked out.
    @ObservationIgnored private var isReleasing = false
    /// Let go before the microphone was even on.
    @ObservationIgnored private var releaseWhenReady = false

    /// How long she waits for the last words after you let go.
    private static let lastWords: Duration = .milliseconds(1_200)
    /// A tap with nothing said, after this long, is given up on.
    private static let patience: Duration = .seconds(12)
    private static let longest: Duration = .seconds(120)

    /// Goes up each time listening ends because you said nothing.
    private(set) var silences = 0

    /// Starts listening. Once you `release()` (or `stop()`), what you said
    /// goes to `heard` and `onHeard`, unless you said nothing (then
    /// `silences` goes up) or it was cancelled. Tapped on (`holding`
    /// false), she gives up if you say nothing for a while.
    func start(holding: Bool = false) {
        guard !isListening else { return }
        generation += 1
        let generation = generation
        transcript = ""
        level = 0
        isReleasing = false
        releaseWhenReady = false
        state = .starting
        Task {
            let problem = await SpeechCapture.prepare()
            guard self.generation == generation, state == .starting else { return }
            if let problem {
                state = .unavailable(problem)
                return
            }
            let capture = SpeechCapture()
            let (events, sink) = AsyncStream.makeStream(of: SpeechEvent.self, bufferingPolicy: .bufferingNewest(32))
            do {
                try capture.start(events: sink)
            } catch {
                capture.stop()
                state = .unavailable("The microphone didn't start. Try again, or type instead.")
                return
            }
            self.capture = capture
            state = .listening
            if releaseWhenReady {
                release()
            } else if !holding {
                wait(Self.patience, generation: generation)
            }
            Task {
                try? await Task.sleep(for: Self.longest)
                if self.generation == generation { finish() }
            }
            // Ends when listening stops and the stream finishes.
            for await event in events {
                guard self.generation == generation else { break }
                switch event {
                case .text(let text, let isFinal): didHear(text, isFinal: isFinal, generation: generation)
                case .level(let level): setLevel(level, generation: generation)
                case .failed: recognitionFailed(generation: generation)
                }
            }
        }
    }

    /// You're done: she works out your last words, then sends it all.
    func release() {
        guard isListening, !isReleasing else { return }
        guard state == .listening, let capture else {
            // The microphone isn't on yet; send once it is.
            releaseWhenReady = true
            return
        }
        isReleasing = true
        capture.finishAudio()
        wait(Self.lastWords, generation: generation)
    }

    /// The same as letting go, for a tap.
    func stop() {
        release()
    }

    /// What started as a hold was a tap: from now on she gives up if you
    /// say nothing for a while.
    func becameTap() {
        guard isListening, !isReleasing else { return }
        wait(Self.patience, generation: generation)
    }

    /// Stops without sending anything.
    func cancel() {
        generation += 1
        silenceTask?.cancel()
        capture?.stop()
        capture = nil
        transcript = ""
        level = 0
        isReleasing = false
        releaseWhenReady = false
        state = .idle
    }

    private func didHear(_ text: String, isFinal: Bool, generation: Int) {
        guard generation == self.generation, isListening else { return }
        transcript = text
        if isFinal, isReleasing {
            finish()
        } else if !isReleasing, silenceTask != nil {
            // Tapped on: you're talking, so she keeps listening.
            wait(Self.patience, generation: generation)
        }
    }

    private func setLevel(_ level: Float, generation: Int) {
        guard generation == self.generation, abs(level - self.level) > 0.03 else { return }
        self.level = level
    }

    private func recognitionFailed(generation: Int) {
        guard generation == self.generation, isListening else { return }
        if transcript.isEmpty {
            cancel()
            state = .unavailable("I couldn't hear that. Tap me and try again, or type instead.")
        } else {
            finish()
        }
    }

    /// Finishes once `duration` passes with nothing new heard.
    private func wait(_ duration: Duration, generation: Int) {
        silenceTask?.cancel()
        silenceTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self.generation == generation else { return }
            finish()
        }
    }

    private func finish() {
        guard isListening else { return }
        generation += 1
        silenceTask?.cancel()
        silenceTask = nil
        capture?.stop()
        capture = nil
        isReleasing = false
        releaseWhenReady = false
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        level = 0
        state = .idle
        if text.isEmpty {
            silences += 1
        } else {
            heard = Heard(id: (heard?.id ?? 0) + 1, text: text)
            onHeard?(text)
        }
    }
}

/// What the microphone and recognizer report.
enum SpeechEvent: Sendable {
    case text(String, isFinal: Bool)
    /// How loud you are, 0 to 1.
    case level(Float)
    case failed
}

/// The microphone and the recognizer. Not on the main actor: audio arrives
/// on the audio thread and results on the recognizer's queue, and the
/// closures that handle them are made here, so they belong to neither.
/// They only pass events along a stream to the listener.
final class SpeechCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private enum Failure: Error { case unavailable, noMicrophone }

    /// She understands English: your own kind of English if your iPad is
    /// set to it, otherwise American English.
    static var locale: Locale {
        Locale.current.language.languageCode == .english ? Locale.current : Locale(identifier: "en-US")
    }

    /// Holds the request for the audio thread.
    private final class RequestBox: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    }

    /// Asks for speech recognition and the microphone, and checks that
    /// recognition can run on this iPad. Returns why it can't, or nil.
    static func prepare() async -> String? {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
        guard speech == .authorized else {
            return "Speech recognition is off for Memor. Turn it on in Settings › Privacy & Security › Speech Recognition, or type instead."
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            return "The microphone is off for Memor. Turn it on in Settings › Privacy & Security › Microphone, or type instead."
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return "Speech recognition isn't available right now. Type instead."
        }
        // Your voice stays on the iPad, or it isn't used at all.
        guard recognizer.supportsOnDeviceRecognition else {
            return "This iPad can't recognize English on its own yet, and Memor doesn't send your voice anywhere. Add English under Settings › General › Keyboard › Dictation Languages, or type instead."
        }
        return nil
    }

    /// Where what she hears goes; finished when she stops.
    private var events: AsyncStream<SpeechEvent>.Continuation?

    /// Starts the microphone and recognition, sending what's heard, and
    /// how loud it is, to `events`. `hints` are words it should expect
    /// (her name). `quietly`: for waiting to hear her name, so other audio
    /// keeps playing at full volume.
    func start(events: AsyncStream<SpeechEvent>.Continuation, hints: [String] = [], quietly: Bool = false) throws {
        self.events = events
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale) else { throw Failure.unavailable }
        let session = AVAudioSession.sharedInstance()
        // The same setup she speaks with, so switching between listening
        // and talking doesn't glitch.
        try session.setCategory(.playAndRecord, mode: .default, options: quietly ? [.mixWithOthers, .defaultToSpeaker] : [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if !hints.isEmpty { request.contextualStrings = hints }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noMicrophone }
        let box = RequestBox(request)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.request.append(buffer)
            events.yield(.level(SpeechCapture.level(of: buffer)))
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                events.yield(.text(result.bestTranscription.formattedString, isFinal: result.isFinal))
            } else if error != nil {
                events.yield(.failed)
            }
        }
    }

    /// Stops the microphone, but lets recognition finish the last words.
    func finishAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
    }

    /// Stops listening. `releasingAudio`: lets the audio session go too
    /// (not when she's about to talk, or her voice would be cut).
    func stop(releasingAudio: Bool = true) {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        events?.finish()
        events = nil
        if releasingAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// How loud a buffer is, 0 (quiet) to 1 (loud).
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 50) / 40, 0), 1)
    }
}
