import AVFAudio
import Foundation
import Speech
import UIKit

/// Turns what you say to the study pal into text, for voice messages, with
/// OpenAI's live transcription model (`PalTranscriber`). Your voice streams
/// to OpenAI while you talk, with the words on your open pages as keywords,
/// so the terms you're studying come out right, and the text is ready the
/// moment you're done.
///
/// Tap the mic (or her) and speak, then tap again to send (`start()`, then
/// `release()`), like dictation in ChatGPT or Claude. A pause never sends
/// it, so you can stop and think. Only if you say nothing at all for a
/// while does she stop listening. Whether you said anything is told from
/// how loud the microphone is next to the room's own quiet, and from words
/// arriving.
@MainActor
@Observable
final class StudyPalListener {
    enum State: Equatable {
        case idle
        /// Asking for the microphone, or starting it.
        case starting
        case listening
        /// Listening can't work; says why.
        case unavailable(String)
    }

    private(set) var state = State.idle
    /// What you've said so far, as it's transcribed.
    private(set) var transcript = ""
    /// How loud you are right now, 0 to 1.
    private(set) var level: Float = 0
    /// Voice messages you've finished that are still being turned into text.
    private(set) var transcribing = 0

    /// Something you said, once you stopped talking. A new one has a new `id`.
    struct Heard: Equatable {
        let id: Int
        let text: String
    }

    /// The last thing you said.
    private(set) var heard: Heard?

    var isListening: Bool { state == .starting || state == .listening }
    var isTranscribing: Bool { transcribing > 0 }

    var problem: String? {
        if case .unavailable(let message) = state { return message }
        return nil
    }

    /// Called with what you said, once it's text.
    @ObservationIgnored var onHeard: ((String) -> Void)?
    /// The words on your open pages and what you're studying.
    @ObservationIgnored var context: () -> SpeechContext = { SpeechContext() }

    @ObservationIgnored private var capture: SpeechCapture?
    @ObservationIgnored private var transcriber: PalTranscriber?
    /// Bumped each time listening starts or stops, so late events from an
    /// earlier time don't count.
    @ObservationIgnored private var generation = 0
    /// You tapped again: the microphone's off, and the last of the audio
    /// is on its way.
    @ObservationIgnored private var isEnding = false
    /// Tapped to send before the microphone was even on.
    @ObservationIgnored private var releaseWhenReady = false
    @ObservationIgnored private var startedAt = ContinuousClock.now
    /// When you last sounded like you were talking, or new words came in.
    @ObservationIgnored private var lastSpeech: ContinuousClock.Instant?
    /// How loud the room is when you're not talking.
    @ObservationIgnored private var noiseFloor: Float?
    @ObservationIgnored private var audioSeconds: Double = 0

    /// With nothing said at all after this long, she stops listening (a
    /// tap by mistake, or you changed your mind).
    private static let patience: Duration = .seconds(20)
    private static let longest: Duration = .seconds(120)

    /// Goes up each time listening ends because you said nothing.
    private(set) var silences = 0

    /// Starts listening. Once you `release()`, what you said goes to
    /// `heard` and `onHeard`, unless you said nothing (then `silences` goes
    /// up) or it was cancelled.
    func start() {
        guard !isListening else { return }
        generation += 1
        let generation = generation
        transcript = ""
        level = 0
        isEnding = false
        releaseWhenReady = false
        startedAt = .now
        lastSpeech = nil
        noiseFloor = nil
        audioSeconds = 0
        // It connects while the microphone starts.
        let transcriber: PalTranscriber
        do {
            transcriber = try PalTranscriber(context: context())
        } catch {
            state = .unavailable("Voice messages need an OpenAI key. Add one in Settings, or type instead.")
            return
        }
        transcriber.onText = { [weak self] text in
            guard let self, self.generation == generation, self.isListening else { return }
            self.transcript = text
            // New words: you're still talking.
            self.lastSpeech = .now
        }
        self.transcriber = transcriber
        state = .starting
        Task {
            let problem = await SpeechCapture.prepareMicrophone()
            guard self.generation == generation, state == .starting else { return }
            if let problem {
                transcriber.cancel()
                self.transcriber = nil
                state = .unavailable(problem)
                return
            }
            let capture = SpeechCapture()
            // Unbounded: none of what you say may be dropped.
            let (events, sink) = AsyncStream.makeStream(of: SpeechEvent.self)
            do {
                try capture.start(events: sink)
            } catch {
                capture.stop()
                transcriber.cancel()
                self.transcriber = nil
                state = .unavailable("The microphone didn't start. Try again, or type instead.")
                return
            }
            self.capture = capture
            state = .listening
            if releaseWhenReady {
                release()
            } else {
                watchForSilence(generation: generation)
            }
            Task {
                try? await Task.sleep(for: Self.longest)
                if self.generation == generation { self.release() }
            }
            // Runs until the microphone stops, so every bit of audio goes.
            for await event in events {
                guard self.generation == generation else { return }
                switch event {
                case .audio(let data):
                    transcriber.append(data)
                    audioSeconds += Double(data.count) / Double(PalTranscriber.bytesPerSecond)
                case .level(let level):
                    hear(level)
                case .text, .failed:
                    break
                }
            }
            guard self.generation == generation, isEnding else { return }
            complete(transcriber)
        }
    }

    /// You're done: the microphone stops, and what you said is sent once
    /// it's text.
    func release() {
        guard isListening, !isEnding else { return }
        guard state == .listening, let capture else {
            // The microphone isn't on yet; send once it is.
            releaseWhenReady = true
            return
        }
        isEnding = true
        // The audio already captured still goes: the loop in `start`
        // finishes with it.
        capture.stop()
        self.capture = nil
    }

    /// Stops without sending anything.
    func cancel() {
        generation += 1
        capture?.stop()
        capture = nil
        transcriber?.cancel()
        transcriber = nil
        transcript = ""
        level = 0
        isEnding = false
        releaseWhenReady = false
        state = .idle
    }

    /// How loud you are tells when you're talking: louder than the room's
    /// own quiet, by enough. The room's quiet is the quietest it's been,
    /// creeping up very slowly so a noisier room is learned.
    private func hear(_ level: Float) {
        if abs(level - self.level) > 0.03 { self.level = level }
        let floor = noiseFloor.map { level < $0 ? level : $0 + (level - $0) * 0.002 } ?? level
        noiseFloor = floor
        if level > max(0.3, floor + 0.2) { lastSpeech = .now }
    }

    /// With nothing said at all for a while, she stops listening, and
    /// nothing is sent. Once you've said something, she waits for your
    /// tap, however long you pause.
    private func watchForSilence(generation: Int) {
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                guard self.generation == generation, state == .listening, !isEnding else { return }
                if lastSpeech != nil { return }
                if ContinuousClock.now - startedAt >= Self.patience {
                    cancel()
                    silences += 1
                    return
                }
            }
        }
    }

    /// The microphone's off and all its audio has gone: if you said
    /// something, it's turned into text and goes to her.
    private func complete(_ transcriber: PalTranscriber) {
        generation += 1
        self.transcriber = nil
        // Tapped to send, it goes even if it sounded quiet: you meant to
        // talk. (Under a moment of audio was a double tap.)
        let saidSomething = lastSpeech != nil || audioSeconds >= 0.6
        isEnding = false
        level = 0
        state = .idle
        guard saidSomething else {
            transcriber.cancel()
            transcript = ""
            silences += 1
            return
        }
        transcribing += 1
        Task {
            let result = await transcriber.finish()
            transcribing -= 1
            if !isListening { transcript = "" }
            switch result {
            case .success(let text) where !text.isEmpty:
                heard = Heard(id: (heard?.id ?? 0) + 1, text: text)
                onHeard?(text)
            case .success:
                silences += 1
            case .failure(let failure):
                if !isListening { state = .unavailable(failure.message) }
            }
        }
    }
}

/// Streams what you say to OpenAI's live transcription model while you say
/// it, over a Realtime WebSocket, and gives back the text once you're done.
/// The words on your open pages go along as keywords, and a line about
/// what you're studying as its prompt.
///
/// Audio is 16-bit mono PCM at 24 kHz, sent 100 ms at a time. Turn
/// detection is off: `finish()` commits it all and waits for the text.
@MainActor
final class PalTranscriber {
    struct Failure: Error {
        let message: String
    }

    /// Read on the audio thread too.
    nonisolated static let sampleRate = 24_000
    nonisolated static let bytesPerSecond = 48_000
    private static let batchBytes = bytesPerSecond / 10

    /// The text so far, as it's transcribed.
    private(set) var liveText = ""
    /// Called with `liveText` each time more of it comes.
    var onText: ((String) -> Void)?

    private let socket: URLSessionWebSocketTask
    private var receiveTask: Task<Void, Never>?
    private var batch = Data()
    private var isCommitting = false
    /// The audio `finish()` committed, as OpenAI names it.
    private var committedItem: String?
    /// What each piece of audio said, and their order.
    private var transcripts: [String: String] = [:]
    private var items: [String] = []
    private var failure: String?
    private var isDone = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(context: SpeechContext) throws {
        socket = try OpenAIClient.transcriptionSocket()
        socket.resume()
        var transcription: [String: Any] = ["model": OpenAIClient.transcriptionModel]
        if !context.prompt.isEmpty { transcription["prompt"] = context.prompt }
        if !context.keywords.isEmpty { transcription["keywords"] = context.keywords }
        // Sent first; the audio that follows is handled after it, in order.
        send([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Self.sampleRate] as [String: Any],
                        "transcription": transcription,
                        // It's told when you're done.
                        "turn_detection": NSNull(),
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ])
        let socket = socket
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await socket.receive()
                } catch {
                    self?.end(failing: "I lost the connection while listening. Try again.")
                    return
                }
                guard case .string(let text) = message,
                      let data = text.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                self?.handle(event)
            }
        }
    }

    /// More of what you're saying.
    func append(_ data: Data) {
        guard !isDone, !isCommitting else { return }
        batch.append(data)
        if batch.count >= Self.batchBytes { flush() }
    }

    /// That's all of it: what was said, once it's text. Empty if nothing
    /// was.
    func finish() async -> Result<String, Failure> {
        if !isDone, !isCommitting {
            flush()
            isCommitting = true
            send(["type": "input_audio_buffer.commit"])
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.end(failing: "Turning what you said into text took too long. Try again.")
            }
        }
        if !isDone {
            await withCheckedContinuation { waiters.append($0) }
        }
        let said = items.compactMap { transcripts[$0] }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { return .success(said) }
        let live = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return .success(live) }
        if let failure { return .failure(Failure(message: failure)) }
        return .success("")
    }

    /// Drops it: nothing more is sent, and the connection closes.
    func cancel() {
        end(failing: nil)
    }

    private func flush() {
        guard !batch.isEmpty else { return }
        send(["type": "input_audio_buffer.append", "audio": batch.base64EncodedString()])
        batch = Data()
    }

    private func handle(_ event: [String: Any]) {
        guard !isDone else { return }
        switch event["type"] as? String {
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return }
            liveText += delta
            onText?(liveText)
        case "conversation.item.input_audio_transcription.completed":
            guard let item = event["item_id"] as? String else { return }
            transcripts[item] = event["transcript"] as? String ?? ""
            if !items.contains(item) { items.append(item) }
            if item == committedItem { end(failing: nil) }
        case "input_audio_buffer.committed":
            guard let item = event["item_id"] as? String else { return }
            if !items.contains(item) { items.append(item) }
            if isCommitting, committedItem == nil {
                committedItem = item
                if transcripts[item] != nil { end(failing: nil) }
            }
        case "conversation.item.input_audio_transcription.failed":
            let error = event["error"] as? [String: Any]
            end(failing: error?["message"] as? String ?? "I couldn't make out what you said. Try again.")
        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? ""
            end(failing: OpenAIError(status: 0, message: message, code: error?["code"] as? String).localizedDescription)
        default:
            break
        }
    }

    private func end(failing message: String?) {
        guard !isDone else { return }
        isDone = true
        if let message { failure = message }
        receiveTask?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    private func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        // Called on URLSession's queue; it has nothing to do.
        socket.send(.string(text)) { @Sendable _ in }
    }
}

/// What the transcriber is told about what you're studying.
struct SpeechContext {
    /// Words to expect: her name and the terms on your open pages.
    var keywords: [String] = []
    /// A line about who's talking and what about.
    var prompt = ""
}

/// Words to expect when you talk, from the pages you have open, so the
/// terms of your subject come out right ("xylan", not "Island"). Words the
/// iPad's dictionary doesn't know come first: those are the ones that get
/// misheard.
@MainActor
enum SpeechVocabulary {
    static let limit = 100

    static func hints(from text: String, name: String?) -> [String] {
        var found: [String: (word: String, count: Int)] = [:]
        var order: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            guard let word, (4...40).contains(word.count), word.allSatisfy(\.isLetter) else { return }
            let key = word.lowercased()
            guard !common.contains(key) else { return }
            if let seen = found[key] {
                // "Xylan" at the start of a sentence, "xylan" elsewhere.
                found[key] = (word == key ? key : seen.word, seen.count + 1)
            } else if order.count < 2_000 {
                found[key] = (word, 1)
                order.append(key)
            }
        }
        let checker = UITextChecker()
        let language = UITextChecker.availableLanguages.first { $0.hasPrefix("en") } ?? "en_US"
        let ranked = order.compactMap { found[$0] }
            .map { entry -> (word: String, score: Int) in
                let length = (entry.word as NSString).length
                let unknown = checker.rangeOfMisspelledWord(
                    in: entry.word, range: NSRange(location: 0, length: length),
                    startingAt: 0, wrap: false, language: language
                ).location != NSNotFound
                return (entry.word, (unknown ? 1_000 : 0) + entry.count * 10 + min(length, 12))
            }
            .sorted { $0.score > $1.score }
        var hints: [String] = []
        // Keywords can't hold line breaks or angle brackets.
        if let name = name?.filter({ !"<>\r\n".contains($0) }).trimmingCharacters(in: .whitespaces), !name.isEmpty {
            hints.append(name)
        }
        for entry in ranked where hints.count < limit && !hints.contains(entry.word) {
            hints.append(entry.word)
        }
        return hints
    }

    /// Who's talking, to whom, and about what.
    static func prompt(name: String?, studying titles: [String]) -> String {
        let pal = name.map { "their study pal, \($0)" } ?? "their study pal"
        let subject = titles.isEmpty ? "" : " They're studying: " + titles.prefix(4).joined(separator: "; ") + "."
        return "A student talking to \(pal) about their notes: short questions and requests, often with terms from their subject.\(subject)"
    }

    /// Everyday words that are never misheard, so they don't take a place.
    private static let common: Set<String> = [
        "about", "above", "after", "again", "against", "also", "always", "among", "another", "answer", "anything",
        "around", "because", "been", "before", "being", "below", "between", "both", "called", "came", "case",
        "cause", "change", "chapter", "come", "could", "different", "does", "doing", "done", "down", "during",
        "each", "either", "else", "even", "every", "example", "fact", "figure", "find", "first", "follow",
        "following", "form", "found", "four", "from", "give", "given", "going", "good", "great", "have", "having",
        "here", "high", "however", "important", "include", "including", "into", "itself", "just", "keep", "kind",
        "know", "known", "large", "last", "less", "like", "little", "long", "look", "made", "main", "make",
        "makes", "many", "mean", "means", "more", "most", "much", "must", "name", "near", "need", "never", "next",
        "note", "notes", "number", "often", "only", "onto", "other", "others", "over", "page", "part", "parts",
        "people", "place", "point", "same", "second", "seen", "several", "should", "show", "shown", "side",
        "similar", "since", "small", "some", "something", "such", "take", "than", "that", "their", "them", "then",
        "there", "therefore", "these", "they", "thing", "things", "this", "those", "though", "three", "through",
        "thus", "time", "together", "toward", "towards", "under", "until", "upon", "used", "uses", "using",
        "very", "want", "well", "went", "were", "what", "when", "where", "whether", "which", "while", "will",
        "with", "within", "without", "word", "words", "work", "would", "write", "year", "years", "your",
    ]
}

/// What the microphone (and, listening for her name, the recognizer)
/// reports.
enum SpeechEvent: Sendable {
    case text(String, isFinal: Bool)
    /// How loud you are, 0 to 1.
    case level(Float)
    /// The sound itself, as 16-bit mono PCM at 24 kHz, for the transcriber.
    case audio(Data)
    case failed
}

/// The microphone, and for her name the on-device recognizer. Not on the
/// main actor: audio arrives on the audio thread and results on the
/// recognizer's queue, and the closures that handle them are made here, so
/// they belong to neither. They only pass events along a stream.
final class SpeechCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private enum Failure: Error { case unavailable, noMicrophone }

    /// Her name is listened for in English: your own kind of English if
    /// your iPad is set to it, otherwise American English.
    static var locale: Locale {
        Locale.current.language.languageCode == .english ? Locale.current : Locale(identifier: "en-US")
    }

    /// Holds the request for the audio thread.
    private final class RequestBox: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    }

    /// Asks for the microphone, for voice messages. Returns why it can't
    /// be used, or nil.
    static func prepareMicrophone() async -> String? {
        guard await AVAudioApplication.requestRecordPermission() else {
            return "The microphone is off for Memor. Turn it on in Settings › Privacy & Security › Microphone, or type instead."
        }
        return nil
    }

    /// Asks for speech recognition and the microphone, and checks that
    /// her name can be listened for on this iPad. Returns why it can't, or
    /// nil.
    static func prepare() async -> String? {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
        guard speech == .authorized else {
            return "Speech recognition is off for Memor, so I can't listen for my name. Turn it on in Settings › Privacy & Security › Speech Recognition."
        }
        if let problem = await prepareMicrophone() { return problem }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return "Listening for my name isn't available right now."
        }
        // Listening for her name happens all the time, so it stays on the iPad.
        guard recognizer.supportsOnDeviceRecognition else {
            return "This iPad can't listen for my name on its own yet. Add English under Settings › General › Keyboard › Dictation Languages."
        }
        return nil
    }

    /// Where what's heard goes; finished when it stops.
    private var events: AsyncStream<SpeechEvent>.Continuation?

    /// Starts the microphone, sending how loud it is and the audio itself
    /// to `events`. `recognizes`: also recognizes speech on the iPad (to
    /// hear her name), expecting `hints`. `quietly`: for waiting to hear her
    /// name, so other audio keeps playing at full volume.
    func start(events: AsyncStream<SpeechEvent>.Continuation, hints: [String] = [], quietly: Bool = false, recognizes: Bool = false) throws {
        self.events = events
        let session = AVAudioSession.sharedInstance()
        // The same setup she speaks with, so switching between listening
        // and talking doesn't glitch.
        try session.setCategory(.playAndRecord, mode: .default, options: quietly ? [.mixWithOthers, .defaultToSpeaker] : [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        var recognizer: SFSpeechRecognizer?
        let box: RequestBox?
        if recognizes {
            guard let found = SFSpeechRecognizer(locale: Self.locale) else { throw Failure.unavailable }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            if !hints.isEmpty { request.contextualStrings = hints }
            self.request = request
            recognizer = found
            box = RequestBox(request)
        } else {
            box = nil
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box?.request.append(buffer)
            events.yield(.level(SpeechCapture.level(of: buffer)))
            let audio = SpeechCapture.pcm16(buffer)
            if !audio.isEmpty { events.yield(.audio(audio)) }
        }
        engine.prepare()
        try engine.start()

        if let recognizer, let request = self.request {
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    events.yield(.text(result.bestTranscription.formattedString, isFinal: result.isFinal))
                } else if error != nil {
                    events.yield(.failed)
                }
            }
        }
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

    /// A buffer as 16-bit little-endian mono PCM at 24 kHz: its channels
    /// mixed, and each output sample the average of the input samples it
    /// stands for.
    private static func pcm16(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let channels = buffer.floatChannelData else { return Data() }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let inputRate = buffer.format.sampleRate
        guard frames > 0, channelCount > 0, inputRate > 0 else { return Data() }
        let step = inputRate / Double(PalTranscriber.sampleRate)
        let count = Int(Double(frames) / step)
        guard count > 0 else { return Data() }
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let start = min(Int(Double(i) * step), frames - 1)
                let end = max(start + 1, min(frames, Int(Double(i + 1) * step)))
                var sum: Float = 0
                for frame in start..<end {
                    for channel in 0..<channelCount { sum += channels[channel][frame] }
                }
                let value = sum / Float((end - start) * channelCount)
                out[i] = Int16(max(-1, min(1, value)) * 32_767).littleEndian
            }
        }
        return data
    }
}
