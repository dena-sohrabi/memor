import Charts
import SwiftUI

extension AIPurpose {
    var color: Color {
        switch self {
        case .brain: .orange
        case .memory: .indigo
        case .voice: .green
        case .ears: .mint
        case .drawing: .pink
        }
    }
}

/// A stretch of time to add usage up over.
enum UsagePeriod: String, CaseIterable, Identifiable {
    case today, week, month, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        case .all: "All Time"
        }
    }

    /// Where it starts; nil for all time.
    var start: Date? {
        let today = Calendar.current.startOfDay(for: .now)
        switch self {
        case .today: return today
        case .week: return Calendar.current.date(byAdding: .day, value: -6, to: today)
        case .month: return Calendar.current.date(byAdding: .day, value: -29, to: today)
        case .all: return nil
        }
    }

    /// Days in the chart; none for today.
    var chartDays: Int? {
        switch self {
        case .today: nil
        case .week: 7
        case .month, .all: 30
        }
    }
}

extension AIUsageFormat {
    /// A price per million tokens: "$4", "$0.10".
    static func rate(_ dollars: Double) -> String {
        let whole = dollars >= 1 && dollars.rounded() == dollars
        return dollars.formatted(.currency(code: "USD").precision(.fractionLength(whole ? 0 : 2)))
    }

    static func seconds(_ seconds: Double) -> String {
        seconds < 90
            ? "\(Int(seconds.rounded())) s"
            : (seconds / 60).formatted(.number.precision(.fractionLength(0...1))) + " min"
    }

    /// The last 30 days, today included.
    static var monthStart: Date { UsagePeriod.month.start ?? .distantPast }
}

// MARK: Usage

/// What her AI requests used and cost: over a stretch of time, per day,
/// per job and per model, and what one of your messages takes on average.
struct UsagePage: View {
    @State private var period = UsagePeriod.month
    @State private var isConfirmingReset = false
    private let store = AIUsageStore.shared

    var body: some View {
        let start = period.start
        let summary = start.map { store.summary(since: $0) } ?? store.allTime
        let profile = store.messageProfile(since: start ?? .distantPast)
        Form {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AIUsageFormat.cost(summary.total.cost))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(totals(summary.total))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if let days = period.chartDays {
                    chart(days: days)
                }
            } footer: {
                if period == .all {
                    Text("Since \(store.since.formatted(date: .long, time: .omitted)). The chart shows the last 30 days.")
                }
            }

            Section("By What She Did") {
                ForEach(AIPurpose.allCases) { purpose in
                    let bucket = summary.byPurpose[purpose] ?? AIUsageBucket()
                    UsageRow(title: purpose.title, detail: detail(of: purpose, bucket, start: start),
                             value: AIUsageFormat.cost(bucket.cost), systemImage: purpose.systemImage, color: purpose.color)
                }
            }

            let models = summary.byModel.sorted { $0.value.cost > $1.value.cost }
            if !models.isEmpty {
                Section("By Model") {
                    ForEach(models, id: \.key) { model, bucket in
                        UsageRow(title: AIUsageFormat.modelName(model), detail: tokens(bucket),
                                 value: AIUsageFormat.cost(bucket.cost), systemImage: "cpu", color: .gray)
                    }
                }
            }

            Section {
                if profile.messages == 0 {
                    Text("No messages yet.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Messages", value: profile.messages.formatted())
                    LabeledContent("Requests per Message", value: profile.rounds.formatted(.number.precision(.fractionLength(1))))
                    LabeledContent("Tokens In", value: "\(AIUsageFormat.tokens(profile.tokensIn)) (\(AIUsageFormat.percent(profile.cacheShare)) cached)")
                    LabeledContent("Tokens Out", value: AIUsageFormat.tokens(profile.output))
                    if profile.webSearches > 0 {
                        LabeledContent("Web Searches", value: profile.webSearches.formatted(.number.precision(.fractionLength(0...2))))
                    }
                    LabeledContent("Cost per Message", value: AIUsageFormat.cost(profile.cost))
                }
            } header: {
                Text("Her Average Message")
            } footer: {
                Text("Her mind's requests for one of your messages, added up: one request, plus one more for each round of tools she uses. Each request sends the whole talk again; the part she's seen before comes from the cache, at a small part of the price. Tokens out include her thinking.")
            }

            Section {
                NavigationLink("Recent Requests") { UsageRequestsPage() }
                NavigationLink("Cost Calculator") { UsageCalculatorPage() }
            }

            Section {
                Button("Reset Usage", role: .destructive) { isConfirmingReset = true }
            } footer: {
                Text("Worked out on this iPad from each company's list prices and the tokens each request used, so it's an estimate: your bills at platform.claude.com and platform.openai.com are the real figures. Requests are kept for a year; only counts and costs are kept, never what was said.")
            }
        }
        .animation(.default, value: period)
        .navigationTitle("AI Usage")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset the usage log?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset Usage", role: .destructive) { store.reset() }
        } message: {
            Text("Every request logged on this iPad is forgotten, and counting starts again.")
        }
    }

    private func chart(days: Int) -> some View {
        let daily = store.daily(days: days)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return Chart(daily) { entry in
            BarMark(x: .value("Day", entry.day, unit: .day), y: .value("Cost", entry.cost))
                .foregroundStyle(by: .value("For", entry.purpose.title))
        }
        .chartForegroundStyleScale(domain: AIPurpose.allCases.map(\.title), range: AIPurpose.allCases.map(\.color))
        .chartXScale(domain: first...end)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let dollars = value.as(Double.self) { Text(AIUsageFormat.cost(dollars)) }
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 190)
        .padding(.vertical, 6)
    }

    private func totals(_ bucket: AIUsageBucket) -> String {
        let requests = bucket.requests == 1 ? "1 request" : "\(bucket.requests.formatted()) requests"
        return "\(requests) · \(AIUsageFormat.tokens(bucket.tokensIn)) tokens in · \(AIUsageFormat.tokens(bucket.tokensOut)) out"
    }

    private func tokens(_ bucket: AIUsageBucket) -> String {
        var parts = ["\(bucket.requests.formatted()) req"]
        if bucket.tokensIn > 0 || bucket.tokensOut > 0 {
            parts.append("\(AIUsageFormat.tokens(bucket.tokensIn)) in (\(AIUsageFormat.percent(bucket.cacheShare)) cached)")
            parts.append("\(AIUsageFormat.tokens(bucket.tokensOut)) out")
        }
        if bucket.seconds > 0 { parts.append(AIUsageFormat.seconds(bucket.seconds)) }
        return parts.joined(separator: " · ")
    }

    private func detail(of purpose: AIPurpose, _ bucket: AIUsageBucket, start: Date?) -> String {
        guard bucket.requests > 0 else { return "None" }
        switch purpose {
        case .brain:
            let messages = store.messageCount(since: start ?? .distantPast)
            var text = "\(messages.formatted()) messages · \(tokens(bucket))"
            if bucket.webSearches > 0 { text += " · \(bucket.webSearches) searches" }
            return text
        case .memory:
            return "\(bucket.requests.formatted()) talks written down"
        case .voice:
            return "\(bucket.requests.formatted()) pieces read aloud · \(AIUsageFormat.tokens(bucket.tokensOut)) out"
        case .ears:
            return "\(bucket.requests.formatted()) times · \(AIUsageFormat.seconds(bucket.seconds)) of talking"
        case .drawing:
            return bucket.requests == 1 ? "1 picture" : "\(bucket.requests.formatted()) pictures"
        }
    }
}

/// A row with an icon, a line under its title, and a value.
private struct UsageRow: View {
    let title: String
    let detail: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                SettingsIcon(systemImage: systemImage, color: color)
            }
        }
    }
}

// MARK: Requests

/// Every request in the log, newest first, with what it used and cost.
struct UsageRequestsPage: View {
    private let store = AIUsageStore.shared
    private static let shown = 300

    var body: some View {
        let recent = Array(store.records.suffix(Self.shown).reversed())
        let days = Dictionary(grouping: recent) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
        List {
            if recent.isEmpty {
                Text("No requests yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(days, id: \.key) { day, records in
                Section {
                    ForEach(records) { record in
                        UsageRow(title: AIUsageFormat.modelName(record.model),
                                 detail: "\(record.purpose.title) · \(record.date.formatted(date: .omitted, time: .shortened)) · \(used(by: record))",
                                 value: AIUsageFormat.cost(record.cost),
                                 systemImage: record.purpose.systemImage, color: record.purpose.color)
                    }
                } header: {
                    Text(day.formatted(date: .complete, time: .omitted))
                }
            }
        }
        .navigationTitle("Recent Requests")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func used(by record: AIUsageRecord) -> String {
        if record.purpose == .ears { return AIUsageFormat.seconds(record.seconds) }
        var parts: [String] = []
        let tokensIn = record.tokensIn
        let cached = record.cachedInput + record.audioCachedInput
        if tokensIn > 0 {
            parts.append(cached > 0
                ? "\(AIUsageFormat.tokens(tokensIn)) in (\(AIUsageFormat.percent(Double(cached) / Double(tokensIn))) cached)"
                : "\(AIUsageFormat.tokens(tokensIn)) in")
        }
        parts.append("\(AIUsageFormat.tokens(record.tokensOut)) out")
        if record.webSearches > 0 { parts.append(record.webSearches == 1 ? "1 search" : "\(record.webSearches) searches") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Calculator

/// What a month with her would cost: set how much you use her, pick her
/// mind, and see it per job, with every mind side by side. It starts from
/// how you've used her over the last 30 days, and prices your average
/// message on each model.
struct UsageCalculatorPage: View {
    @State private var model = PalBrainModel.chosen
    @State private var messagesPerDay: Double
    @State private var spokenShare: Double
    @State private var picturesPerDay: Int
    private let store = AIUsageStore.shared

    init() {
        let store = AIUsageStore.shared
        let start = AIUsageFormat.monthStart
        let recent = store.entries(since: start)
        // The days you've used her, of the last 30, so a new log isn't
        // averaged over days before it began.
        let days = Double(Set(recent.map { Calendar.current.startOfDay(for: $0.date) }).count)
        let messages = Double(store.messageCount(since: start))
        let listened = Double(recent.filter { $0.purpose == .ears }.count)
        let pictures = Double(recent.filter { $0.purpose == .drawing }.count)
        let measured = days > 0 && messages >= 3
        _messagesPerDay = State(initialValue: measured ? min(max((messages / days).rounded(), 1), 200) : 20)
        _spokenShare = State(initialValue: measured ? min(listened / messages, 1) : 0.5)
        _picturesPerDay = State(initialValue: measured ? Int((pictures / days).rounded()) : 1)
    }

    var body: some View {
        let picked = costs(for: model)
        Form {
            Section {
                VStack(alignment: .leading) {
                    LabeledContent("Messages a Day", value: Int(messagesPerDay).formatted())
                    Slider(value: $messagesPerDay, in: 1...200, step: 1)
                }
                VStack(alignment: .leading) {
                    LabeledContent("Said Out Loud", value: AIUsageFormat.percent(spokenShare))
                    Slider(value: $spokenShare, in: 0...1, step: 0.05)
                }
                Stepper(value: $picturesPerDay, in: 0...50) {
                    LabeledContent("Pictures a Day", value: picturesPerDay.formatted())
                }
            } header: {
                Text("How You Use Her")
            } footer: {
                Text("Starts from how you've used her on the days you did, over the last 30 days. Messages said out loud are heard by her ears and answered in her voice.")
            }

            Section {
                Picker(selection: $model) {
                    ForEach(PalMind.allCases) { mind in
                        Section(mind.company) {
                            ForEach(PalBrainModel.all.filter { $0.mind == mind }) { Text($0.title).tag($0) }
                        }
                    }
                } label: {
                    SettingsLabel("Her Mind", systemImage: "brain.head.profile", color: .orange)
                }
                ForEach(picked.parts, id: \.purpose) { part in
                    UsageRow(title: part.purpose.title, detail: part.detail, value: AIUsageFormat.cost(part.daily * 30),
                             systemImage: part.purpose.systemImage, color: part.purpose.color)
                }
                LabeledContent {
                    Text(AIUsageFormat.cost(picked.daily * 30))
                        .font(.title3.bold())
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } label: {
                    Text("A Month")
                        .font(.headline)
                }
                LabeledContent("A Day", value: AIUsageFormat.cost(picked.daily))
            } header: {
                Text("Estimated Cost")
            } footer: {
                if let spent = spentLastMonth {
                    Text("Over the last 30 days you've spent \(AIUsageFormat.cost(spent)).")
                }
            }

            Section {
                ForEach(PalBrainModel.all) { other in
                    let otherCosts = self.costs(for: other)
                    Button {
                        model = other
                    } label: {
                        UsageRow(title: other.title, detail: "\(AIUsageFormat.cost(profile.priced(on: other.id))) a message",
                                 value: AIUsageFormat.cost(otherCosts.daily * 30) + " a month",
                                 systemImage: other == model ? "checkmark" : "brain.head.profile",
                                 color: other.mind == .claude ? .orange : .teal)
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Every Mind, Same Use")
            } footer: {
                Text(profileNote)
            }
        }
        .animation(.default, value: model)
        .navigationTitle("Cost Calculator")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Working it out

    private struct Part {
        let purpose: AIPurpose
        let daily: Double
        let detail: String
    }

    private struct Costs {
        let parts: [Part]
        var daily: Double { parts.reduce(0) { $0 + $1.daily } }
    }

    /// Your average message over the last 30 days, or a typical one.
    private var profile: AIMessageProfile {
        let measured = store.messageProfile(since: AIUsageFormat.monthStart)
        return measured.isMeasured ? measured : .typical
    }

    private var spentLastMonth: Double? {
        let spent = store.summary(since: AIUsageFormat.monthStart).total.cost
        return spent > 0 ? spent : nil
    }

    private func costs(for model: PalBrainModel) -> Costs {
        let start = AIUsageFormat.monthStart
        let messages = messagesPerDay
        let spoken = messages * spokenShare

        let perMessage = profile.priced(on: model.id)

        // Her memory writes a talk down every so often, with her company's
        // small model.
        let memoryPerMessage: Double
        let memory = store.summary(since: start).byPurpose[.memory]?.cost ?? 0
        let sent = store.messageCount(since: start)
        if sent >= 3, memory > 0 {
            memoryPerMessage = memory / Double(sent)
        } else {
            let chores = model.mind == .claude ? ClaudeClient.choresModel : OpenAIClient.choresModel
            memoryPerMessage = AIPricing.textCost(model: chores, input: 3_000, cachedInput: 0, cacheWrite: 0, output: 800) / 6
        }

        // A reply read aloud: about 20 seconds of speech.
        let perReply = store.voiceCostPerReply(since: start)
            ?? AIPricing.voiceCost(textInput: 600, textCached: 0, audioInput: 0, audioCached: 0, textOutput: 0, audioOutput: 400)
        // About 8 seconds of you talking.
        let perHearing = store.averageCost(of: .ears, since: start) ?? AIPricing.transcriptionCost(seconds: 8)
        // A 1024×1024 picture at medium quality.
        let perPicture = store.averageCost(of: .drawing, since: start)
            ?? AIPricing.imageCost(textInput: 150, imageInput: 0, imageOutput: 1_056)

        return Costs(parts: [
            Part(purpose: .brain, daily: messages * perMessage, detail: "\(AIUsageFormat.cost(perMessage)) a message"),
            Part(purpose: .memory, daily: messages * memoryPerMessage, detail: "\(AIUsageFormat.cost(memoryPerMessage)) a message"),
            Part(purpose: .voice, daily: spoken * perReply, detail: "\(AIUsageFormat.cost(perReply)) a reply read aloud"),
            Part(purpose: .ears, daily: spoken * perHearing, detail: "\(AIUsageFormat.cost(perHearing)) a message said aloud"),
            Part(purpose: .drawing, daily: Double(picturesPerDay) * perPicture, detail: "\(AIUsageFormat.cost(perPicture)) a picture"),
        ])
    }

    private var profileNote: String {
        let average = self.profile
        let tokens = "\(AIUsageFormat.tokens(average.tokensIn)) tokens in (\(AIUsageFormat.percent(average.cacheShare)) from the cache) and \(AIUsageFormat.tokens(average.output)) out, over \(average.rounds.formatted(.number.precision(.fractionLength(1)))) requests"
        let source = average.isMeasured
            ? "Your average message over the last 30 days: \(tokens)."
            : "Until you've sent a few messages, a typical message: \(tokens)."
        return source + " Each mind is priced for the same tokens; Claude and GPT count tokens a little differently, so it's a guide. Estimates use list prices."
    }
}

// MARK: Her mind

/// Pick the model that thinks for her: Claude or GPT, from the most
/// capable to the cheapest, with prices and what your average message
/// would cost on each.
struct BrainModelPage: View {
    @AppStorage(PalBrainModel.settingKey) private var brainModel = ""
    private let store = AIUsageStore.shared

    var body: some View {
        let chosen = PalBrainModel.model(brainModel) ?? PalBrainModel.chosen
        let measured = store.messageProfile(since: AIUsageFormat.monthStart)
        let profile = measured.isMeasured ? measured : .typical
        Form {
            ForEach(PalMind.allCases) { mind in
                Section {
                    ForEach(PalBrainModel.all.filter { $0.mind == mind }) { model in
                        Button {
                            brainModel = model.id
                        } label: {
                            row(model, isChosen: model == chosen, perMessage: profile.priced(on: model.id))
                        }
                    }
                } header: {
                    Text(mind.company)
                } footer: {
                    let notes: [String] = [
                        mind.hasKey ? nil : "Add your \(mind.company) API key in Settings to use these.",
                        mind == PalMind.allCases.last ? Self.note(measured: measured.isMeasured) : nil,
                    ].compactMap { $0 }
                    if !notes.isEmpty {
                        Text(notes.joined(separator: "\n\n"))
                    }
                }
            }
        }
        .navigationTitle("Her Mind")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: brainModel) { Pal.shared.keyChanged() }
    }

    private static func note(measured: Bool) -> String {
        "Prices are per million tokens in and out. “A message” is \(measured ? "your average message over the last 30 days" : "a typical message"), priced on each model. A change takes effect from her next talk (or tap New Topic in her card). Her memory uses the same company's small model; her ears, voice and pictures use OpenAI whichever mind you pick."
    }

    private func row(_ model: PalBrainModel, isChosen: Bool, perMessage: Double) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .foregroundStyle(.primary)
                Text(model.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let price = model.price {
                    Text("\(AIUsageFormat.rate(price.input)) in · \(AIUsageFormat.rate(price.output)) out · about \(AIUsageFormat.cost(perMessage)) a message")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            if isChosen {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
    }
}
