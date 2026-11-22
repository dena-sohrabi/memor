import AVFAudio
import Foundation
import Speech

/// Listens when you tap the study pal, and turns what you say into text.
/// Recognition runs on the iPad, so your voice never leaves it; only the
/// text goes to Claude, as your question.
///
/// She stops listening on her own a moment after you stop talking, or
/// when you tap her again.
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

    @ObservationIgnored private var capture: SpeechCapture?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    /// Bumped each time listening starts or stops, so late results from an
    /// earlier time don't count.
    @ObservationIgnored private var generation = 0

    /// How long a pause ends what you're saying. Recognition adds full
    /// stops early, even mid-thought, so they don't count as the end.
    private static let pause: Duration = .milliseconds(1_500)
    /// After a clear question.
    private static let questionPause: Duration = .seconds(1)
    /// When you trail off on a word that leads somewhere ("and", "so",
    /// "um"), you're probably not done.
    private static let midThoughtPause: Duration = .milliseconds(2_400)
    private static let leadingWords: Set<String> = [
        "and", "but", "so", "or", "because", "um", "uh", "like", "the", "a", "an", "to", "of",
        "with", "then", "if", "that", "which", "is", "are", "my", "your", "what", "how", "why", "about",
    ]
    private static let longest: Duration = .seconds(45)

    /// Goes up each time she stops listening because you said nothing.
    private(set) var silences = 0

    /// Starts listening, waiting up to `patience` for you to start talking.
    /// Once you stop, what you said becomes `heard`, unless you said
    /// nothing (then `silences` goes up) or listening was cancelled.
    func start(patience: Duration = .seconds(7)) {
        guard !isListening else { return }
        generation += 1
        let generation = generation
        transcript = ""
        level = 0
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
            wait(patience, generation: generation)
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

    /// Stops now and sends what you said so far.
    func stop() {
        finish()
    }

    /// Stops without sending anything.
    func cancel() {
        generation += 1
        silenceTask?.cancel()
        capture?.stop()
        capture = nil
        transcript = ""
        level = 0
        state = .idle
    }

    private func didHear(_ text: String, isFinal: Bool, generation: Int) {
        guard generation == self.generation, isListening else { return }
        transcript = text
        if isFinal {
            finish()
        } else {
            wait(Self.pause(after: text), generation: generation)
        }
    }

    /// How long to wait after what's been said so far.
    private static func pause(after text: String) -> Duration {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastWord = trimmed.split(separator: " ").last
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        if leadingWords.contains(lastWord) || trimmed.hasSuffix("…") { return midThoughtPause }
        if trimmed.hasSuffix("?") { return questionPause }
        return pause
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
        capture?.stop()
        capture = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        level = 0
        state = .idle
        if text.isEmpty {
            silences += 1
        } else {
            heard = Heard(id: (heard?.id ?? 0) + 1, text: text)
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
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            return "Speech recognition isn't available right now. Type instead."
        }
        // Your voice stays on the iPad, or it isn't used at all.
        guard recognizer.supportsOnDeviceRecognition else {
            let language = Locale.current.localizedString(forIdentifier: recognizer.locale.identifier) ?? "your language"
            return "This iPad can't recognize \(language) on its own, and Memor doesn't send your voice anywhere. Type instead."
        }
        return nil
    }

    /// Where what she hears goes; finished when she stops.
    private var events: AsyncStream<SpeechEvent>.Continuation?

    /// Starts the microphone and recognition, sending what's heard, and
    /// how loud it is, to `events`.
    func start(events: AsyncStream<SpeechEvent>.Continuation) throws {
        self.events = events
        guard let recognizer = SFSpeechRecognizer() else { throw Failure.unavailable }
        let session = AVAudioSession.sharedInstance()
        // The same setup she speaks with, so switching between listening
        // and talking doesn't glitch.
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation
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

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        events?.finish()
        events = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
