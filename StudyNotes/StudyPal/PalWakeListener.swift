import Foundation
import Speech

/// Listens for "Hey" and the study pal's name, like Siri, so you can talk
/// to her without touching anything: say "Hey Pishi, what does this word
/// mean?", and what you say after her name goes to her as a voice message
/// once you pause.
///
/// Recognition runs on the iPad, in English, so your voice never leaves it
/// (the microphone dot stays on while she's listening for her name). She
/// doesn't listen for it while you're holding the mic, while she's talking
/// (so she doesn't hear herself), or while Memor isn't on screen. Settings
/// can turn it off (`isEnabledKey`).
@MainActor
@Observable
final class PalWakeListener {
    /// The setting for listening for her name; on unless turned off.
    nonisolated static let isEnabledKey = "studyPal.wakeWord"

    nonisolated static var isTurnedOn: Bool {
        UserDefaults.standard.object(forKey: isEnabledKey) as? Bool ?? true
    }

    enum State: Equatable {
        /// Not listening (not wanted now, or getting ready).
        case off
        /// Listening for her name.
        case waiting
        /// She heard her name and is taking down what you say.
        case capturing
    }

    private(set) var state = State.off
    /// What you've said since her name.
    private(set) var command = ""
    /// Why she can't listen for her name, if she can't (permissions).
    private(set) var problem: String?

    /// She heard her name.
    @ObservationIgnored var onWake: (() -> Void)?
    /// What you said after her name, once you paused.
    @ObservationIgnored var onCommand: ((String) -> Void)?
    /// Whether she should be listening for her name right now.
    @ObservationIgnored var shouldListen: () -> Bool = { false }
    /// The words on your open pages and what you're studying.
    @ObservationIgnored var context: () -> SpeechContext = { SpeechContext() }

    /// What you said after her name is being turned into text.
    private(set) var isTranscribing = false

    @ObservationIgnored private var capture: SpeechCapture?
    /// From the moment she hears her name, what you say streams to OpenAI.
    @ObservationIgnored private var transcriber: PalTranscriber?
    @ObservationIgnored private var speech = SpeechContext()
    /// The last couple of seconds of sound while she waits for her name,
    /// so the start of what you say isn't lost while her name is spotted.
    @ObservationIgnored private var recent: [Data] = []
    @ObservationIgnored private var recentBytes = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// Not before this: a moment's rest after a command, or after a failure.
    @ObservationIgnored private var restAfter = Date.distantPast
    /// The words that wake her, as recognized ("hey", "pishi"…).
    @ObservationIgnored private var nameWords: [String] = []

    /// A pause this long after you've said something ends it.
    private static let pause: Duration = .milliseconds(1_600)
    /// Right after her name, she waits a bit longer for you to start.
    private static let firstPause: Duration = .seconds(4)
    /// A recognition session is renewed this often while she waits, so it
    /// never grows long.
    private static let renewEvery: Duration = .seconds(50)
    /// How much sound from before her name was spotted goes along.
    private static let recentLimit = PalTranscriber.bytesPerSecond * 5 / 2
    private static let greetings: Set<String> = ["hey", "hi", "hello", "okay", "ok", "hay", "yo"]

    /// Starts watching whether she should listen, and listens when she should.
    func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Permissions may have changed (Settings): try again.
    func retry() {
        problem = nil
        restAfter = .distantPast
    }

    /// Lets go of the microphone right away (you're about to hold the mic).
    func stopNow() {
        if state != .off { end() }
        restAfter = .now.addingTimeInterval(0.5)
    }

    private func check() {
        let wanted = Self.isTurnedOn && problem == nil && shouldListen()
        switch (wanted, state) {
        case (true, .off):
            if Date.now >= restAfter { begin() }
        case (false, .waiting):
            end()
        case (false, .capturing):
            // You started talking another way, or she's hidden: drop it.
            end()
        default:
            break
        }
    }

    // MARK: Listening

    private func begin() {
        generation += 1
        let generation = generation
        nameWords = Self.words(StudyPalCharacter.name ?? "study pal")
        command = ""
        state = .waiting
        let wakeHints = StudyPalCharacter.name.map { ["Hey \($0)", $0] } ?? ["Hey study pal"]
        speech = context()
        let hints = wakeHints + speech.keywords.filter { !wakeHints.contains($0) }.prefix(SpeechVocabulary.limit - wakeHints.count)
        Task {
            if let problem = await SpeechCapture.prepare() {
                guard self.generation == generation else { return }
                self.problem = problem
                state = .off
                return
            }
            guard self.generation == generation, state == .waiting else { return }
            let capture = SpeechCapture()
            // Room for several seconds of sound, so none is dropped if the
            // app is busy for a moment.
            let (events, sink) = AsyncStream.makeStream(of: SpeechEvent.self, bufferingPolicy: .bufferingNewest(1_024))
            do {
                try capture.start(events: sink, hints: hints, quietly: true, recognizes: true)
            } catch {
                capture.stop(releasingAudio: false)
                state = .off
                restAfter = .now.addingTimeInterval(5)
                return
            }
            self.capture = capture
            renewLater(generation)
            for await event in events {
                guard self.generation == generation else { break }
                switch event {
                case .text(let text, _): heard(text, generation: generation)
                case .level: break
                case .audio(let data): hear(data)
                case .failed:
                    // Recognition gave up (it does after long quiet): start afresh.
                    if state == .capturing, !command.isEmpty {
                        finish(generation: generation)
                    } else {
                        renew(generation)
                    }
                }
            }
        }
    }

    /// Stops listening for now; she starts again when she should.
    private func end() {
        generation += 1
        endTask?.cancel()
        restartTask?.cancel()
        capture?.stop(releasingAudio: false)
        capture = nil
        transcriber?.cancel()
        transcriber = nil
        recent = []
        recentBytes = 0
        command = ""
        state = .off
    }

    /// Sound: while she waits for her name, only the last bit is kept; once
    /// she's heard it, it streams to OpenAI.
    private func hear(_ data: Data) {
        if let transcriber {
            transcriber.append(data)
            return
        }
        recent.append(data)
        recentBytes += data.count
        while recentBytes > Self.recentLimit, !recent.isEmpty {
            recentBytes -= recent.removeFirst().count
        }
    }

    /// She heard her name: what you say from here (and the moment before,
    /// her name included) goes to OpenAI to be turned into text. Without an
    /// OpenAI key, the iPad's own words are used.
    private func startTranscribing() {
        guard transcriber == nil, let transcriber = try? PalTranscriber(context: speech) else { return }
        self.transcriber = transcriber
        for chunk in recent { transcriber.append(chunk) }
        recent = []
        recentBytes = 0
    }

    /// A fresh recognition session, so it doesn't grow long.
    private func renew(_ generation: Int) {
        guard self.generation == generation, state == .waiting else { return }
        end()
        restAfter = .now.addingTimeInterval(0.3)
    }

    private func renewLater(_ generation: Int) {
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: Self.renewEvery)
            guard !Task.isCancelled else { return }
            renew(generation)
        }
    }

    private func heard(_ text: String, generation: Int) {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        // No name yet (or recognition revised it away): keep waiting, or
        // keep what was said so far.
        guard let start = Self.wakeEnd(in: tokens, name: nameWords) else { return }
        let said = tokens[start...].joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        if state == .waiting {
            state = .capturing
            restartTask?.cancel()
            startTranscribing()
            onWake?()
            command = said
            waitForPause(said.isEmpty ? Self.firstPause : Self.pause, generation: generation)
        } else if said != command {
            command = said
            waitForPause(said.isEmpty ? Self.firstPause : Self.pause, generation: generation)
        }
    }

    private func waitForPause(_ duration: Duration, generation: Int) {
        endTask?.cancel()
        endTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            finish(generation: generation)
        }
    }

    /// You paused: what you said goes to her, as OpenAI heard it, and she
    /// listens for her name again after she's answered.
    private func finish(generation: Int) {
        guard self.generation == generation, state == .capturing else { return }
        let onDevice = command
        let name = nameWords
        let transcriber = self.transcriber
        self.transcriber = nil
        end()
        restAfter = .now.addingTimeInterval(1)
        guard let transcriber else {
            if !onDevice.isEmpty { onCommand?(onDevice) }
            return
        }
        isTranscribing = true
        Task {
            let result = await transcriber.finish()
            isTranscribing = false
            var text = onDevice
            if case .success(let heard) = result, !heard.isEmpty {
                // It heard "Hey <name>" too (and maybe a bit before it).
                if let said = Self.command(in: heard, name: name) {
                    if !said.isEmpty { text = said }
                } else {
                    text = heard
                }
            }
            if !text.isEmpty { onCommand?(text) }
        }
    }

    /// What was said after the last "Hey <name>" in `text`, or nil if her
    /// name isn't in it.
    private static func command(in text: String, name: [String]) -> String? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let start = wakeEnd(in: tokens, name: name) else { return nil }
        return tokens[start...].joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
    }

    // MARK: Hearing her name

    /// Lowercased words without punctuation.
    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Where what you said starts: just after the last "Hey <name>" in
    /// `tokens`. Her name may come out spelled a little differently (it's
    /// her own word, not one the recognizer knows), so close is enough.
    private static func wakeEnd(in tokens: [String], name: [String]) -> Int? {
        guard !name.isEmpty else { return nil }
        let plain = tokens.map { words($0).joined() }
        var found: Int?
        for index in plain.indices where greetings.contains(plain[index]) {
            let end = index + 1 + name.count
            guard end <= plain.count else { continue }
            if zip(plain[(index + 1)..<end], name).allSatisfy({ sounds($0, like: $1) }) {
                found = end
            }
        }
        return found
    }

    /// Close enough to be her name: the same, or a letter or two off.
    private static func sounds(_ heard: String, like name: String) -> Bool {
        if heard == name { return true }
        guard !heard.isEmpty, heard.first == name.first || name.count <= 3 else { return false }
        let allowed = max(1, name.count / 3)
        return distance(heard, name) <= allowed
    }

    /// How many letters apart two words are (edit distance).
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}
