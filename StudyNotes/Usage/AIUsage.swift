import Foundation
import os
import UIKit

// MARK: What it's for

/// What an AI request was for.
enum AIPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Her mind, answering you (each round of tools is its own request).
    case brain
    /// Writing down what she remembers after a talk.
    case memory
    /// Reading her replies aloud.
    case voice
    /// Turning what you say into text.
    case ears
    /// The pictures she draws.
    case drawing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brain: "Her Mind"
        case .memory: "Memory"
        case .voice: "Voice"
        case .ears: "Listening"
        case .drawing: "Pictures"
        }
    }

    var systemImage: String {
        switch self {
        case .brain: "brain.head.profile"
        case .memory: "book.closed.fill"
        case .voice: "waveform"
        case .ears: "ear.fill"
        case .drawing: "paintbrush.pointed.fill"
        }
    }
}

// MARK: Prices

/// List prices in US dollars per million tokens (or per minute, for
/// transcription), as each company publishes them. Checked on
/// 2026-11-25 against platform.claude.com and
/// developers.openai.com/api/docs/pricing.
///
/// These are estimates of what a request costs. The bill at
/// platform.claude.com and platform.openai.com is the real figure.
struct AIPrice: Sendable {
    /// Input tokens that weren't read from the cache.
    var input: Double
    /// Input tokens read from the cache.
    var cachedInput: Double
    /// Input tokens written to the cache (Claude's 5-minute cache costs
    /// 1.25× input; OpenAI has no write premium, so it's the input price).
    var cacheWrite: Double
    var output: Double
    /// Prompts longer than this many tokens are billed at `long`.
    var longAbove: Int?
    var long: Prices?

    /// The rates of a long prompt.
    struct Prices: Sendable {
        var input: Double
        var cachedInput: Double
        var cacheWrite: Double
        var output: Double
    }

    /// Claude: cache reads and writes as Anthropic prices them.
    static func claude(input: Double, cachedInput: Double, output: Double) -> AIPrice {
        AIPrice(input: input, cachedInput: cachedInput, cacheWrite: input * 1.25, output: output)
    }

    /// GPT: long prompts (over 272K tokens) cost more for their input. The
    /// page lists only the input rate, so cached input is assumed to double
    /// with it and output to stay the same.
    static func gpt(input: Double, cachedInput: Double, output: Double, longInput: Double) -> AIPrice {
        let factor = longInput / input
        return AIPrice(
            input: input, cachedInput: cachedInput, cacheWrite: input, output: output,
            longAbove: 272_000,
            long: Prices(input: longInput, cachedInput: cachedInput * factor, cacheWrite: longInput, output: output)
        )
    }
}

enum AIPricing {
    /// Each web search, from either company: $10 per 1,000.
    static let webSearch = 0.01

    /// Text models: her minds and her memory.
    static let text: [String: AIPrice] = [
        // Anthropic
        "claude-fable-5-2": .claude(input: 8, cachedInput: 0.20, output: 40),
        "claude-opus-5-5": .claude(input: 4, cachedInput: 0.20, output: 20),
        "claude-sonnet-5-5": .claude(input: 2, cachedInput: 0.10, output: 10),
        "claude-haiku-5-5": AIPrice(
            input: 0.10, cachedInput: 0.01, cacheWrite: 0.125, output: 0.50,
            // Prompts over 100K tokens use Haiku's second rate card.
            longAbove: 100_000,
            long: .init(input: 0.50, cachedInput: 0.05, cacheWrite: 0.625, output: 2.50)
        ),
        // OpenAI
        "gpt-6.2-astra": .gpt(input: 8, cachedInput: 0.40, output: 40, longInput: 16),
        "gpt-6.2-sol": .gpt(input: 2, cachedInput: 0.10, output: 10, longInput: 4),
        "gpt-6.1-terra": .gpt(input: 1, cachedInput: 0.05, output: 5, longInput: 2),
        "gpt-6-luna": .gpt(input: 0.10, cachedInput: 0.01, output: 0.50, longInput: 0.20),
    ]

    /// Her speaking voice (gpt-realtime-2.1-mini): text in, audio out.
    enum Voice {
        static let textInput = 0.60, textCachedInput = 0.06, textOutput = 2.40
        static let audioInput = 10.0, audioCachedInput = 0.30, audioOutput = 20.0
    }

    /// Her ears (gpt-live-transcribe), per minute of audio.
    static let transcriptionPerMinute = 0.017

    /// Her pictures (gpt-image-2.6-flare).
    enum Image {
        static let textInput = 5.0, textCachedInput = 1.25
        static let imageInput = 8.0, imageCachedInput = 2.0, imageOutput = 30.0
    }

    /// What a text request costs on `model`. Unknown models cost nothing
    /// (and show as $0), rather than a guess.
    static func textCost(model: String, input: Int, cachedInput: Int, cacheWrite: Int, output: Int, webSearches: Int = 0) -> Double {
        let searches = Double(webSearches) * webSearch
        guard let price = text[model] else { return searches }
        let prompt = input + cachedInput + cacheWrite
        let rates: AIPrice.Prices
        if let longAbove = price.longAbove, let long = price.long, prompt > longAbove {
            rates = long
        } else {
            rates = .init(input: price.input, cachedInput: price.cachedInput, cacheWrite: price.cacheWrite, output: price.output)
        }
        let dollars = Double(input) * rates.input
            + Double(cachedInput) * rates.cachedInput
            + Double(cacheWrite) * rates.cacheWrite
            + Double(output) * rates.output
        return dollars / 1_000_000 + searches
    }

    static func voiceCost(textInput: Int, textCached: Int, audioInput: Int, audioCached: Int, textOutput: Int, audioOutput: Int) -> Double {
        let dollars = Double(textInput) * Voice.textInput + Double(textCached) * Voice.textCachedInput
            + Double(audioInput) * Voice.audioInput + Double(audioCached) * Voice.audioCachedInput
            + Double(textOutput) * Voice.textOutput + Double(audioOutput) * Voice.audioOutput
        return dollars / 1_000_000
    }

    static func transcriptionCost(seconds: Double) -> Double {
        seconds / 60 * transcriptionPerMinute
    }

    static func imageCost(textInput: Int, imageInput: Int, imageOutput: Int) -> Double {
        let dollars = Double(textInput) * Image.textInput + Double(imageInput) * Image.imageInput
            + Double(imageOutput) * Image.imageOutput
        return dollars / 1_000_000
    }
}

// MARK: A request

/// One request to Claude or OpenAI: what it was for, which model, how many
/// tokens went each way, and what that cost at list prices. Never what was
/// said.
struct AIUsageRecord: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date = Date.now
    var purpose: AIPurpose
    var model: String
    /// The message it answered (her mind), or the reply it read aloud (her
    /// voice), so requests can be added up per message.
    var turn: UUID?
    /// Input tokens not read from the cache (text, for voice and pictures).
    var input = 0
    /// Input tokens read from the cache.
    var cachedInput = 0
    /// Input tokens written to the cache (Claude).
    var cacheWrite = 0
    /// Output tokens, thinking included (text, for voice).
    var output = 0
    /// How many of `output` were thinking.
    var reasoning = 0
    var audioInput = 0
    var audioCachedInput = 0
    var audioOutput = 0
    var imageInput = 0
    var imageOutput = 0
    /// Seconds of audio (listening).
    var seconds = 0.0
    var webSearches = 0
    /// In US dollars, at list prices when it was made.
    var cost = 0.0

    var tokensIn: Int { input + cachedInput + cacheWrite + audioInput + audioCachedInput + imageInput }
    var tokensOut: Int { output + audioOutput + imageOutput }
}

// MARK: Totals

/// Requests added up.
struct AIUsageBucket: Codable, Equatable, Sendable {
    var requests = 0
    var cost = 0.0
    var tokensIn = 0
    var tokensOut = 0
    var cachedInput = 0
    var seconds = 0.0
    var webSearches = 0

    mutating func add(_ record: AIUsageRecord) {
        requests += 1
        cost += record.cost
        tokensIn += record.tokensIn
        tokensOut += record.tokensOut
        cachedInput += record.cachedInput + record.audioCachedInput
        seconds += record.seconds
        webSearches += record.webSearches
    }

    /// How much of the input was read from the cache.
    var cacheShare: Double { tokensIn == 0 ? 0 : Double(cachedInput) / Double(tokensIn) }
}

/// Usage over a stretch of time, overall and split up.
struct AIUsageSummary: Codable, Equatable, Sendable {
    var total = AIUsageBucket()
    var byPurpose: [AIPurpose: AIUsageBucket] = [:]
    var byModel: [String: AIUsageBucket] = [:]

    mutating func add(_ record: AIUsageRecord) {
        total.add(record)
        byPurpose[record.purpose, default: .init()].add(record)
        byModel[record.model, default: .init()].add(record)
    }
}

/// What one day cost for one purpose, for the chart.
struct AIDailyCost: Identifiable, Sendable {
    let day: Date
    let purpose: AIPurpose
    let cost: Double

    var id: String { "\(day.timeIntervalSince1970)-\(purpose.rawValue)" }
}

/// What one of your messages takes, on average: her mind's requests for
/// it added up (one per round of tools).
struct AIMessageProfile: Equatable, Sendable {
    var messages = 0
    var rounds = 0.0
    var input = 0.0
    var cachedInput = 0.0
    var cacheWrite = 0.0
    var output = 0.0
    var webSearches = 0.0
    var cost = 0.0

    /// A typical message, until there's enough of yours to go by: the
    /// page pictures and text, a couple of rounds of tools, most of it
    /// read from the cache after the first message of a talk.
    static let typical = AIMessageProfile(
        messages: 0, rounds: 2, input: 4_000, cachedInput: 25_000, cacheWrite: 8_000,
        output: 1_200, webSearches: 0.1, cost: 0
    )

    /// It's yours, not the typical one.
    var isMeasured: Bool { messages >= 3 }

    var tokensIn: Double { input + cachedInput + cacheWrite }
    var cacheShare: Double { tokensIn == 0 ? 0 : cachedInput / tokensIn }

    /// What this message would cost on `model`, rounds taken as they came.
    func priced(on model: String) -> Double {
        // Long-prompt rates go by the size of each request, not the message.
        let perRound = max(rounds, 1)
        let one = AIPricing.textCost(
            model: model,
            input: Int(input / perRound), cachedInput: Int(cachedInput / perRound),
            cacheWrite: Int(cacheWrite / perRound), output: Int(output / perRound)
        ) * perRound
        return one + webSearches * AIPricing.webSearch
    }
}

// MARK: The log

/// Every AI request this iPad made, kept for a year (the totals since you
/// started counting are kept for good). Saved in a file in the app's own
/// storage, on this iPad only.
@MainActor
@Observable
final class AIUsageStore {
    static let shared = AIUsageStore()

    static let log = Logger(subsystem: "com.denasohrabi.memor", category: "usage")

    private(set) var records: [AIUsageRecord]
    /// Since the log started, or was last reset.
    private(set) var since: Date
    /// Everything since `since`, including requests too old to keep.
    private(set) var allTime: AIUsageSummary

    private static let keepFor: TimeInterval = 365 * 24 * 60 * 60
    private static let maxRecords = 20_000

    @ObservationIgnored private let saver = Debouncer()

    private struct Saved: Codable {
        var since: Date
        var allTime: AIUsageSummary
        var records: [AIUsageRecord]
    }

    private init() {
        let saved = (try? Data(contentsOf: Self.fileURL)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        records = saved?.records ?? []
        since = saved?.since ?? .now
        allTime = saved?.allTime ?? AIUsageSummary()
        // Whatever is waiting to be saved goes before the app is put away.
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saver.flush() }
        }
    }

    /// Adds a request, if it used anything.
    func add(_ record: AIUsageRecord) {
        guard record.tokensIn > 0 || record.tokensOut > 0 || record.seconds > 0 || record.webSearches > 0 else { return }
        records.append(record)
        allTime.add(record)
        prune()
        saver.schedule(after: .seconds(2)) { [weak self] in self?.save() }
    }

    /// Starts counting afresh.
    func reset() {
        records = []
        allTime = AIUsageSummary()
        since = .now
        saver.cancel()
        save()
    }

    // MARK: Adding up

    func entries(since start: Date) -> [AIUsageRecord] {
        // Records are in the order they were made.
        guard let first = records.firstIndex(where: { $0.date >= start }) else { return [] }
        return Array(records[first...])
    }

    func summary(since start: Date) -> AIUsageSummary {
        var summary = AIUsageSummary()
        for record in entries(since: start) { summary.add(record) }
        return summary
    }

    /// Cost per day and purpose for the last `days` days, today included.
    func daily(days: Int) -> [AIDailyCost] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var costs: [Date: [AIPurpose: Double]] = [:]
        for record in entries(since: start) {
            costs[calendar.startOfDay(for: record.date), default: [:]][record.purpose, default: 0] += record.cost
        }
        return costs.sorted { $0.key < $1.key }.flatMap { day, purposes in
            purposes.sorted { $0.key.rawValue < $1.key.rawValue }.map { AIDailyCost(day: day, purpose: $0.key, cost: $0.value) }
        }
    }

    /// Your average message since `start`, from her mind's requests.
    func messageProfile(since start: Date) -> AIMessageProfile {
        var turns: [UUID: AIMessageProfile] = [:]
        for record in entries(since: start) where record.purpose == .brain {
            guard let turn = record.turn else { continue }
            var message = turns[turn, default: AIMessageProfile()]
            message.rounds += 1
            message.input += Double(record.input)
            message.cachedInput += Double(record.cachedInput)
            message.cacheWrite += Double(record.cacheWrite)
            message.output += Double(record.output)
            message.webSearches += Double(record.webSearches)
            message.cost += record.cost
            turns[turn] = message
        }
        guard !turns.isEmpty else { return AIMessageProfile() }
        let count = Double(turns.count)
        var average = AIMessageProfile()
        average.messages = turns.count
        for message in turns.values {
            average.rounds += message.rounds / count
            average.input += message.input / count
            average.cachedInput += message.cachedInput / count
            average.cacheWrite += message.cacheWrite / count
            average.output += message.output / count
            average.webSearches += message.webSearches / count
            average.cost += message.cost / count
        }
        return average
    }

    /// How many messages you sent since `start` (her mind's turns).
    func messageCount(since start: Date) -> Int {
        Set(entries(since: start).filter { $0.purpose == .brain }.compactMap(\.turn)).count
    }

    /// Average cost of each reply she read aloud since `start`.
    func voiceCostPerReply(since start: Date) -> Double? {
        let voice = entries(since: start).filter { $0.purpose == .voice }
        let replies = Set(voice.compactMap(\.turn)).count
        guard replies >= 3 else { return nil }
        return voice.filter { $0.turn != nil }.reduce(0) { $0 + $1.cost } / Double(replies)
    }

    /// Average cost of one request for `purpose` since `start`.
    func averageCost(of purpose: AIPurpose, since start: Date) -> Double? {
        let matching = entries(since: start).filter { $0.purpose == purpose }
        guard matching.count >= 3 else { return nil }
        return matching.reduce(0) { $0 + $1.cost } / Double(matching.count)
    }

    // MARK: File

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Usage/usage.json")
    }

    private func prune() {
        let cutoff = Date.now.addingTimeInterval(-Self.keepFor)
        if let first = records.first, first.date < cutoff {
            records.removeAll { $0.date < cutoff }
        }
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
    }

    private func save() {
        let saved = Saved(since: since, allTime: allTime, records: records)
        let url = Self.fileURL
        do {
            let data = try JSONEncoder().encode(saved)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.log.error("Couldn't save the AI usage log.")
        }
    }
}

// MARK: Reading usage from the APIs

/// Adds up a Claude Messages stream's `usage` as its events go by, and logs
/// it once the stream ends (finished, stopped or failed: what was used up
/// to then is billed either way).
@MainActor
final class ClaudeUsageMeter {
    private var record: AIUsageRecord

    init(model: String, purpose: AIPurpose, turn: UUID?) {
        record = AIUsageRecord(purpose: purpose, model: model, turn: turn)
    }

    func read(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            guard let message = event["message"] as? [String: Any] else { return }
            if let model = message["model"] as? String, !model.isEmpty { record.model = model }
            if let usage = message["usage"] as? [String: Any] { take(usage) }
        case "message_delta":
            // Its counts are the totals so far.
            if let usage = event["usage"] as? [String: Any] { take(usage) }
        default:
            break
        }
    }

    private func take(_ usage: [String: Any]) {
        if let value = usage["input_tokens"] as? Int { record.input = value }
        if let value = usage["cache_read_input_tokens"] as? Int { record.cachedInput = value }
        if let value = usage["cache_creation_input_tokens"] as? Int { record.cacheWrite = value }
        if let value = usage["output_tokens"] as? Int { record.output = value }
        if let tools = usage["server_tool_use"] as? [String: Any], let searches = tools["web_search_requests"] as? Int {
            record.webSearches = searches
        }
    }

    func finish() {
        record.date = .now
        record.cost = AIPricing.textCost(
            model: record.model, input: record.input, cachedInput: record.cachedInput,
            cacheWrite: record.cacheWrite, output: record.output, webSearches: record.webSearches
        )
        AIUsageStore.shared.add(record)
    }
}

enum OpenAIUsage {
    /// A Responses API `usage` object (and the response's output, for the
    /// web searches in it), logged.
    @MainActor
    static func recordResponse(_ usage: [String: Any]?, output: [[String: Any]], model: String, purpose: AIPurpose, turn: UUID?) {
        var record = AIUsageRecord(purpose: purpose, model: model, turn: turn)
        let input = usage?["input_tokens"] as? Int ?? 0
        let cached = (usage?["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        record.input = max(input - cached, 0)
        record.cachedInput = cached
        record.output = usage?["output_tokens"] as? Int ?? 0
        record.reasoning = (usage?["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0
        record.webSearches = output.filter { $0["type"] as? String == "web_search_call" }.count
        record.cost = AIPricing.textCost(
            model: model, input: record.input, cachedInput: record.cachedInput,
            cacheWrite: 0, output: record.output, webSearches: record.webSearches
        )
        AIUsageStore.shared.add(record)
    }

    /// A realtime `response.done` event's usage (her voice), logged.
    @MainActor
    static func recordVoice(_ usage: [String: Any]?, model: String, turn: UUID?) {
        guard let usage else { return }
        let inputDetails = usage["input_token_details"] as? [String: Any]
        let cachedDetails = inputDetails?["cached_tokens_details"] as? [String: Any]
        let outputDetails = usage["output_token_details"] as? [String: Any]
        let cachedText = cachedDetails?["text_tokens"] as? Int ?? 0
        let cachedAudio = cachedDetails?["audio_tokens"] as? Int ?? 0
        var record = AIUsageRecord(purpose: .voice, model: model, turn: turn)
        record.input = max((inputDetails?["text_tokens"] as? Int ?? 0) - cachedText, 0)
        record.cachedInput = cachedText
        record.audioInput = max((inputDetails?["audio_tokens"] as? Int ?? 0) - cachedAudio, 0)
        record.audioCachedInput = cachedAudio
        record.output = outputDetails?["text_tokens"] as? Int ?? 0
        record.audioOutput = outputDetails?["audio_tokens"] as? Int ?? 0
        if inputDetails == nil, outputDetails == nil {
            // No breakdown: all in is the text it was given, all out is audio.
            record.input = usage["input_tokens"] as? Int ?? 0
            record.audioOutput = usage["output_tokens"] as? Int ?? 0
        }
        record.cost = AIPricing.voiceCost(
            textInput: record.input, textCached: record.cachedInput,
            audioInput: record.audioInput, audioCached: record.audioCachedInput,
            textOutput: record.output, audioOutput: record.audioOutput
        )
        AIUsageStore.shared.add(record)
    }

    /// Seconds of audio she listened to, logged.
    @MainActor
    static func recordListening(seconds: Double, model: String) {
        var record = AIUsageRecord(purpose: .ears, model: model)
        record.seconds = seconds
        record.cost = AIPricing.transcriptionCost(seconds: seconds)
        AIUsageStore.shared.add(record)
    }

    /// An Images API `usage` object, logged.
    @MainActor
    static func recordImage(_ usage: [String: Any]?, model: String) {
        var record = AIUsageRecord(purpose: .drawing, model: model)
        let details = usage?["input_tokens_details"] as? [String: Any]
        record.input = details?["text_tokens"] as? Int ?? usage?["input_tokens"] as? Int ?? 0
        record.imageInput = details?["image_tokens"] as? Int ?? 0
        // Without usage in the reply, a 1024×1024 picture at medium quality
        // is counted as about 1,056 image tokens.
        record.imageOutput = usage?["output_tokens"] as? Int ?? 1_056
        record.cost = AIPricing.imageCost(textInput: record.input, imageInput: record.imageInput, imageOutput: record.imageOutput)
        AIUsageStore.shared.add(record)
    }
}

// MARK: Formatting

@MainActor
enum AIUsageFormat {
    /// Dollars, with more digits for amounts under a dollar ($0.0042).
    static func cost(_ dollars: Double) -> String {
        let digits = dollars == 0 ? 2 : dollars < 0.01 ? 4 : dollars < 1 ? 3 : 2
        return dollars.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }

    /// 12.3K, 1.2M.
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    static func tokens(_ count: Double) -> String {
        tokens(Int(count.rounded()))
    }

    static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)))
    }

    /// The model's name as Settings shows it ("Claude Opus 5.5"), or its id.
    static func modelName(_ id: String) -> String {
        if let model = PalBrainModel.model(id) { return model.title }
        switch id {
        case ClaudeClient.choresModel: return "Claude Haiku 5.5"
        case OpenAIClient.choresModel: return "GPT-6 Luna"
        case OpenAIClient.voiceModel: return "GPT Realtime 2.1 Mini"
        case OpenAIClient.transcriptionModel: return "GPT Live Transcribe"
        case OpenAIClient.imageModel: return "GPT Image 2.6 Flare"
        default: return id
        }
    }
}
