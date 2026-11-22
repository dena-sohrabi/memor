import AVFAudio
import Foundation

/// The study pal's little sounds: small, soft and high, like a tiny bird.
enum StudyPalSound: CaseIterable, Sendable {
    /// "Pi-pip!": you tapped her.
    case mrrp
    /// "Hi-ii!", a little slide up and a pip: Ask Claude opened.
    case hello
    /// "Hm?", rising at the end: you started typing.
    case curious
    /// A tiny, soft pip: she's listening.
    case listening
    /// Three pips going up: Claude changed your page.
    case happy
    /// A soft "aww" going down: something went wrong.
    case sad
}

/// Her voice: her little sounds, and soft, contented coos while you scratch
/// her. Her kit has no sounds, so they're all made here in code. They play
/// quietly and mix with whatever else is playing, and the audio engine only
/// runs while she's making a sound. Settings can turn them off
/// (`isEnabledKey`).
@MainActor
final class StudyPalVoice {
    /// The setting for her sounds; on unless turned off.
    nonisolated static let isEnabledKey = "studyPal.sounds"

    private let engine = AVAudioEngine()
    /// A few players take turns, so sounds can overlap.
    private let players = [AVAudioPlayerNode(), AVAudioPlayerNode(), AVAudioPlayerNode()]
    private var humTask: Task<Void, Never>?
    private var lastHum = -1
    private var nextPlayer = 0
    private var bank: SoundBank?
    private var isConnected = false
    private var prepareTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var cooTask: Task<Void, Never>?
    private var lastCoo = -1

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.isEnabledKey) as? Bool ?? true
    }

    init() {
        // Making the sounds takes a moment; do it off the main thread, once.
        prepareTask = Task { [weak self] in
            let bank = await Task.detached(priority: .utility) { SoundBank.make() }.value
            self?.bank = bank
        }
    }

    func shutDown() {
        prepareTask?.cancel()
        idleTask?.cancel()
        cooTask?.cancel()
        humTask?.cancel()
        for player in players { player.stop() }
        engine.stop()
    }

    func play(_ sound: StudyPalSound) {
        guard let buffer = bank?.effects[sound] else { return }
        play(buffer, volume: SoundBank.volume(of: sound))
    }

    /// While you scratch her: a soft coo now, then another every second or
    /// so, never the same one twice in a row.
    func startCooing() {
        guard cooTask == nil else { return }
        cooTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.coo()
                try? await Task.sleep(for: .seconds(Double.random(in: 0.9...1.5)))
            }
        }
    }

    func stopCooing() {
        cooTask?.cancel()
        cooTask = nil
    }

    /// While she thinks: now and then a soft hum, each one a little
    /// different ("mm", "mm-hm", "hmm?"), at uneven moments, so it never
    /// sounds like a loop. A short think may end before the first.
    func startHumming() {
        guard humTask == nil else { return }
        humTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double.random(in: 0.5...1.1)))
            while !Task.isCancelled {
                self?.hum()
                try? await Task.sleep(for: .seconds(Double.random(in: 1.6...3.4)))
            }
        }
    }

    func stopHumming() {
        humTask?.cancel()
        humTask = nil
    }

    private func hum() {
        guard let hums = bank?.hums, !hums.isEmpty else { return }
        var pick = Int.random(in: 0..<hums.count)
        if pick == lastHum { pick = (pick + 1) % hums.count }
        lastHum = pick
        play(hums[pick], volume: SoundBank.humVolume * Float.random(in: 0.8...1.1))
    }

    /// One soft coo.
    func coo() {
        guard let coos = bank?.coos, !coos.isEmpty else { return }
        var pick = Int.random(in: 0..<coos.count)
        if pick == lastCoo { pick = (pick + 1) % coos.count }
        lastCoo = pick
        play(coos[pick], volume: SoundBank.cooVolume)
    }

    private func play(_ buffer: AVAudioPCMBuffer, volume: Float) {
        guard isEnabled, start() else { return }
        idleTask?.cancel()
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
        stopWhenQuiet(after: 2)
    }

    // MARK: Engine

    private func start() -> Bool {
        guard let bank else { return false }
        if !isConnected {
            for player in players {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: bank.format)
            }
            isConnected = true
        }
        if engine.isRunning { return true }
        do {
            // Ambient: mixes with music and follows the device's mute. While
            // she's listening to you, the audio is set up to record;
            // switching it would cut the microphone off.
            let audio = AVAudioSession.sharedInstance()
            if audio.category != .playAndRecord { try audio.setCategory(.ambient) }
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// Lets the engine go once she's been quiet a moment, to save battery.
    private func stopWhenQuiet(after seconds: Double) {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.cooTask == nil, self.humTask == nil else { return }
            for player in self.players { player.stop() }
            self.engine.stop()
        }
    }
}

// MARK: Making the sounds

/// Audio buffers aren't Sendable, but these are made once off the main
/// thread, handed over, and from then on only read by the players.
private struct SoundBank: @unchecked Sendable {
    let format: AVAudioFormat
    let effects: [StudyPalSound: AVAudioPCMBuffer]
    let coos: [AVAudioPCMBuffer]
    let hums: [AVAudioPCMBuffer]

    static let rate = 44_100.0
    /// The hum is the quietest of all.
    static let humVolume: Float = 0.16
    /// Coos are the softest of her sounds.
    static let cooVolume: Float = 0.22

    static func volume(of sound: StudyPalSound) -> Float {
        switch sound {
        case .mrrp, .hello, .happy: 0.32
        case .curious, .sad: 0.28
        case .listening: 0.22
        }
    }

    static func make() -> SoundBank? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return nil }
        var effects: [StudyPalSound: AVAudioPCMBuffer] = [:]
        for sound in StudyPalSound.allCases {
            effects[sound] = buffer(samples(for: sound), format: format, peak: 0.5)
        }
        // A few coos, a little different in pitch, length and lilt.
        let shapes: [(pitch: Double, length: Double, lift: Double)] = [
            (640, 0.34, 0.07), (720, 0.3, 0.09), (580, 0.4, 0.05), (780, 0.26, 0.1),
        ]
        let coos = shapes.compactMap { shape in
            buffer(coo(pitch: shape.pitch, length: shape.length, lift: shape.lift), format: format, peak: 0.5)
        }
        let hums = humShapes.compactMap { buffer($0, format: format, peak: 0.5) }
        return SoundBank(format: format, effects: effects, coos: coos, hums: hums)
    }

    private static func samples(for sound: StudyPalSound) -> [Float] {
        switch sound {
        case .mrrp:
            return note(0.07, from: 1_050, to: 1_350)
                + silence(0.035)
                + note(0.09, from: 1_200, to: 1_600)
        case .hello:
            return note(0.17, from: 900, to: 1_400, wobble: 0.015)
                + silence(0.03)
                + note(0.08, from: 1_450, to: 1_600)
        case .curious:
            // Dips, then rises at the end, like a question.
            return note(0.26, from: 820, to: 1_300, wobble: 0.012) { (x: Double) -> Double in
                x < 0.4 ? -0.4 * x : (x - 0.4) / 0.6 * 1.16 - 0.16
            }
        case .happy:
            var samples: [Float] = []
            for (index, pitch) in [1_100.0, 1_300, 1_550].enumerated() {
                samples += note(0.06, from: pitch, to: pitch * 1.12)
                if index < 2 { samples += silence(0.035) }
            }
            return samples
        case .sad:
            return note(0.38, from: 1_000, to: 720, wobble: 0.02)
        case .listening:
            return note(0.09, from: 980, to: 1_250)
        }
    }

    /// One small, round note that glides from one pitch to another, easing
    /// out (or along `shape`, given 0 to 1 across the note and giving 0 to
    /// 1 of the glide), and wobbling a little by `wobble`, a share of the
    /// pitch. Almost a pure tone: that keeps it soft and sweet. It starts
    /// with a tiny upward chirp, the "boop" that makes small creatures cute.
    private static func note(
        _ length: Double,
        from start: Double,
        to end: Double,
        wobble: Double = 0.008,
        shape: (Double) -> Double = { x in 1 - (1 - x) * (1 - x) }
    ) -> [Float] {
        let count = Int(rate * length)
        var samples: [Float] = []
        samples.reserveCapacity(count)
        var phase: Double = 0
        let tau = 2 * Double.pi
        for i in 0..<count {
            let t = Double(i) / rate
            let x = t / length
            let glide: Double = start + (end - start) * shape(x)
            let chirp: Double = 1 + 0.06 * max(0, 1 - t / 0.02)
            let waver: Double = 1 + wobble * sin(tau * 7 * t)
            phase += glide * chirp * waver / rate
            let tone: Double = sin(tau * phase) + 0.12 * sin(2 * tau * phase) + 0.03 * sin(3 * tau * phase)
            let attack: Double = min(1, t / 0.012)
            let release: Double = x < 0.55 ? 1 : 0.5 + 0.5 * cos(Double.pi * (x - 0.55) / 0.45)
            samples.append(Float(tone * attack * release))
        }
        return samples
    }

    /// "Mmm~": a soft, contented coo. It eases in slowly, lifts a little by
    /// `lift` (a share of the pitch) and settles, with a gentle wobble.
    /// Nearly a pure tone, with no chirp: softer than her other sounds.
    private static func coo(pitch: Double, length: Double, lift: Double) -> [Float] {
        let count = Int(rate * length)
        var samples: [Float] = []
        samples.reserveCapacity(count)
        var phase: Double = 0
        let tau = 2 * Double.pi
        for i in 0..<count {
            let t = Double(i) / rate
            let x = t / length
            let contour: Double = 1 + lift * sin(Double.pi * min(x * 1.2, 1)) - 0.04 * x
            let waver: Double = 1 + 0.012 * sin(tau * 5.5 * t)
            phase += pitch * contour * waver / rate
            let tone: Double = sin(tau * phase) + 0.06 * sin(2 * tau * phase)
            let rise: Double = min(1, t / 0.06)
            let attack: Double = rise * rise
            let release: Double = x < 0.45 ? 1 : 0.5 + 0.5 * cos(Double.pi * (x - 0.45) / 0.55)
            samples.append(Float(tone * attack * release))
        }
        return samples
    }

    /// Her thinking hums, each a little different: a level "mmm", a
    /// curious "mm?", an "mm-hm", a long "hmmm", short ones, a low one.
    /// Closed-mouth and soft: a round tone with a little body.
    private static var humShapes: [[Float]] {
        let pause = silence(0.1)
        var shapes: [[Float]] = []
        shapes.append(hum(0.55, from: 450, to: 425))
        shapes.append(hum(0.4, from: 420, to: 500))
        shapes.append(hum(0.22, from: 470, to: 460) + pause + hum(0.3, from: 430, to: 480))
        shapes.append(hum(0.75, from: 430, to: 410, bulge: 30))
        shapes.append(hum(0.25, from: 485, to: 470))
        shapes.append(hum(0.24, from: 440, to: 440) + pause + hum(0.26, from: 448, to: 428))
        shapes.append(hum(0.5, from: 380, to: 395))
        shapes.append(hum(0.6, from: 420, to: 430, bulge: 45))
        return shapes
    }

    /// One soft "mm", gliding from `start` to `end`, rising by `bulge` in
    /// the middle.
    private static func hum(_ length: Double, from start: Double, to end: Double, bulge: Double = 0) -> [Float] {
        let count = Int(rate * length)
        var samples: [Float] = []
        samples.reserveCapacity(count)
        var phase: Double = 0
        let tau = 2 * Double.pi
        for i in 0..<count {
            let t = Double(i) / rate
            let x = t / length
            let glide: Double = start + (end - start) * sin(Double.pi / 2 * x) + bulge * sin(Double.pi * x)
            let waver: Double = 1 + 0.01 * sin(tau * 5 * t)
            phase += glide * waver / rate
            let tone: Double = sin(tau * phase) + 0.22 * sin(2 * tau * phase) + 0.06 * sin(3 * tau * phase)
            let swell: Double = sin(Double.pi * x)
            samples.append(Float(tone * swell * swell))
        }
        return samples
    }

    private static func silence(_ length: Double) -> [Float] {
        Array(repeating: 0, count: Int(rate * length))
    }

    private static func buffer(_ samples: [Float], format: AVAudioFormat, peak: Float) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let loudest = samples.reduce(Float(0)) { max($0, abs($1)) }
        let scale = loudest > 0 ? peak / loudest : 0
        for (i, sample) in samples.enumerated() { channel[i] = sample * scale }
        return buffer
    }
}
