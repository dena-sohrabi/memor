import SwiftUI

/// Memor's settings, grouped like the iPad's own:
/// - Study Pal: which model is her mind (a Claude or GPT model), and your
///   API keys. Claude needs an Anthropic key; her voice and her pictures
///   need an OpenAI key either way.
/// - Her name, her memory, reading replies aloud, her voice, her sounds,
///   and staying on screen outside Memor.
/// - Usage: what her AI requests used and cost, and a calculator.
/// - About: what leaves your iPad, and the version.
///
/// Opened without any key, it goes straight to the Anthropic key, and
/// closes once one is saved.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StudyPalVoice.isEnabledKey) private var palSounds = true
    @AppStorage(StudyPalSpeaker.isEnabledKey) private var palSpeaks = true
    @AppStorage(StudyPalSpeaker.voiceKey) private var palVoice = StudyPalSpeaker.defaultVoice
    @AppStorage(StudyPalCharacter.nameKey) private var palName = ""
    @AppStorage(PalMemoryStore.isOnKey) private var remembers = true
    @AppStorage(PalBrainModel.settingKey) private var brainModel = ""
    @AppStorage(PalWakeListener.isEnabledKey) private var wakeWord = true
    @State private var hasClaudeKey = APIKeyStore.hasKey
    @State private var hasOpenAIKey = OpenAIKeyStore.hasKey
    /// Opened for a key: once it's saved, Settings closes.
    @State private var opensForKey = PalMind.current == nil

    var body: some View {
        NavigationStack {
            Group {
                if opensForKey {
                    APIKeyPage(kind: .claude) {
                        keysChanged()
                        if hasClaudeKey { dismiss() }
                    }
                } else {
                    settings
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: brainModel) { Pal.shared.keyChanged() }
    }

    /// The model picked in Settings (read through `brainModel`, so the
    /// page updates when it changes).
    private var chosenModel: PalBrainModel {
        PalBrainModel.model(brainModel) ?? PalBrainModel.chosen
    }

    private func keysChanged() {
        hasClaudeKey = APIKeyStore.hasKey
        hasOpenAIKey = OpenAIKeyStore.hasKey
        Pal.shared.keyChanged()
    }

    private var settings: some View {
        Form {
            Section {
                NavigationLink {
                    BrainModelPage()
                } label: {
                    SettingsRow("Her Mind", systemImage: "brain.head.profile", color: .orange,
                                value: chosenModel.title)
                }
                NavigationLink {
                    APIKeyPage(kind: .claude) { keysChanged() }
                } label: {
                    SettingsRow("Anthropic API Key", systemImage: "key.fill", color: .orange,
                                value: hasClaudeKey ? "Connected" : "Not Set Up")
                }
                NavigationLink {
                    APIKeyPage(kind: .openAI) { keysChanged() }
                } label: {
                    SettingsRow("OpenAI API Key", systemImage: "key.fill", color: .teal,
                                value: hasOpenAIKey ? "Connected" : "Not Set Up")
                }
            } header: {
                Text("Study Pal")
            } footer: {
                Text(mindFooter)
            }

            Section {
                LabeledContent {
                    TextField("Not Named Yet", text: $palName)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } label: {
                    SettingsLabel("Name", systemImage: "heart.fill", color: .red)
                }
                NavigationLink {
                    MemoryPage()
                } label: {
                    SettingsRow("Memory", systemImage: "book.closed.fill", color: .indigo,
                                value: remembers ? "On" : "Off")
                }
                Toggle(isOn: $wakeWord) {
                    SettingsLabel("Listen for “Hey \(palName.isEmpty ? "Study Pal" : palName)”", systemImage: "ear.fill", color: .mint)
                }
                .onChange(of: wakeWord) { Pal.shared.wake.retry() }
                Toggle(isOn: $palSpeaks) {
                    SettingsLabel("Read Replies Aloud", systemImage: "waveform", color: .green)
                }
                .disabled(!hasOpenAIKey)
                NavigationLink {
                    VoicePicker()
                } label: {
                    SettingsRow("Voice", systemImage: "person.wave.2.fill", color: .purple,
                                value: palVoice.capitalized)
                }
                .disabled(!hasOpenAIKey)
                Toggle(isOn: $palSounds) {
                    SettingsLabel("Sounds", systemImage: "speaker.wave.2.fill", color: .pink)
                }
            } footer: {
                Text("Say “Hey \(palName.isEmpty ? "Study Pal" : palName)” and what you want, and she answers when you pause; she listens for her name on this iPad only (the microphone dot shows while she does), and never while she's talking or hidden. Or use the mic beside her: hold it while you talk and let go, or tap it, talk and tap again. The switch beside her picks Voice (she talks back and listens for her name) or Chat (she only writes).")
            }

            Section {
                NavigationLink {
                    UsagePage()
                } label: {
                    SettingsRow("AI Usage", systemImage: "chart.bar.fill", color: .cyan,
                                value: AIUsageFormat.cost(AIUsageStore.shared.summary(since: AIUsageFormat.monthStart).total.cost))
                }
                NavigationLink {
                    UsageCalculatorPage()
                } label: {
                    SettingsLabel("Cost Calculator", systemImage: "dollarsign", color: .green)
                }
            } header: {
                Text("Usage")
            } footer: {
                Text("What her mind, memory, voice, ears and pictures cost over the last 30 days, at list prices, and what a month would cost on each model.")
            }

            Section {
                NavigationLink {
                    PrivacyPage()
                } label: {
                    SettingsLabel("Privacy", systemImage: "hand.raised.fill", color: .blue)
                }
                LabeledContent {
                    Text(Self.version)
                } label: {
                    SettingsLabel("Version", systemImage: "info.circle.fill", color: .gray)
                }
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var mindFooter: String {
        let chosen = chosenModel
        var text = "\(chosen.title) thinks for her, with your \(chosen.mind.company) key."
        if !chosen.mind.hasKey {
            text += " Add that key below" + (PalBrainModel.current.map { "; until then, \($0.title) does." } ?? ".")
        }
        text += " Her voice and the pictures she draws use your OpenAI key either way. A change takes effect from her next talk (or tap New Topic in her card)."
        return text
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: Rows

/// A setting's icon: a white symbol on a colored rounded square, as in the
/// iPad's Settings.
struct SettingsIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color.gradient, in: .rect(cornerRadius: 7))
    }
}

struct SettingsLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    init(_ title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(systemImage: systemImage, color: color)
        }
    }
}

/// A label with its current value on the trailing side.
struct SettingsRow: View {
    let title: String
    let systemImage: String
    let color: Color
    let value: String

    init(_ title: String, systemImage: String, color: Color, value: String) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value)
        } label: {
            SettingsLabel(title, systemImage: systemImage, color: color)
        }
    }
}

// MARK: API keys

/// Which API key a key page is for.
enum APIKeyKind {
    case claude, openAI

    var title: String {
        switch self {
        case .claude: "Anthropic API Key"
        case .openAI: "OpenAI API Key"
        }
    }

    var placeholder: String {
        switch self {
        case .claude: "sk-ant-…"
        case .openAI: "sk-…"
        }
    }

    var usage: String {
        switch self {
        case .claude:
            "When Claude is her mind, your messages go to Anthropic: as text (what you say out loud is turned into text by OpenAI first), with pictures of the pages on your screen, their text, what you circled or selected, and what she remembers about you and those notes. Claude's small model writes down what she should remember."
        case .openAI:
            "Her ears, her voice and the pictures she draws come from OpenAI: what you say to her goes to OpenAI to be turned into text, with the words on your open pages so it's heard right; what she says goes to OpenAI to be spoken; and what she wants drawn, to be drawn. Listening for “Hey” and her name stays on your iPad. When GPT is her mind, your messages go to OpenAI the same way they'd go to Anthropic for Claude. Nothing is stored on OpenAI's side for the conversation."
        }
    }

    var link: (title: String, url: URL) {
        switch self {
        case .claude: ("Get a key at platform.claude.com", URL(string: "https://platform.claude.com")!)
        case .openAI: ("Get a key at platform.openai.com", URL(string: "https://platform.openai.com/api-keys")!)
        }
    }

    var hint: String? {
        switch self {
        case .claude: APIKeyStore.maskedHint()
        case .openAI: OpenAIKeyStore.maskedHint()
        }
    }

    func delete() {
        switch self {
        case .claude: APIKeyStore.delete()
        case .openAI: OpenAIKeyStore.delete()
        }
    }

    /// Checks the key with a free request, then saves it to the Keychain.
    @MainActor
    func checkAndSave(_ key: String) async throws {
        switch self {
        case .claude:
            try await ClaudeClient.validate(key: key)
            guard APIKeyStore.save(key) else { throw KeySaveError() }
        case .openAI:
            try await OpenAIClient.validate(key: key)
            guard OpenAIKeyStore.save(key) else { throw KeySaveError() }
        }
    }
}

private struct KeySaveError: LocalizedError {
    var errorDescription: String? { "Couldn't save the key to the Keychain." }
}

/// One API key: add it, replace it or remove it, and what it's for. The
/// key is kept only in this iPad's Keychain.
private struct APIKeyPage: View {
    let kind: APIKeyKind
    var onSaved: () -> Void = {}

    @State private var keyText = ""
    @State private var hint: String?
    @State private var isChecking = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                if let hint {
                    LabeledContent("Saved Key", value: hint)
                        .privacySensitive()
                }
                SecureField(hint == nil ? kind.placeholder : "Replace with a new key", text: $keyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .onSubmit(save)
                Button(isChecking ? "Checking…" : "Save Key", action: save)
                    .disabled(trimmed.isEmpty || isChecking)
            } footer: {
                Text(message ?? "Stored only in this iPad's Keychain: never synced, backed up or logged.")
            }

            Section("How It's Used") {
                Text(kind.usage)
                    .foregroundStyle(.secondary)
                Link(kind.link.title, destination: kind.link.url)
            }

            if hint != nil {
                Section {
                    Button("Remove Key", role: .destructive) {
                        kind.delete()
                        hint = nil
                        message = "The key was removed from this iPad."
                        onSaved()
                    }
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { hint = kind.hint }
    }

    private var trimmed: String {
        keyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let key = trimmed
        guard !key.isEmpty, !isChecking else { return }
        isChecking = true
        message = nil
        Task {
            defer { isChecking = false }
            do {
                try await kind.checkAndSave(key)
                keyText = ""
                hint = kind.hint
                message = "Saved."
                onSaved()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: Memory

/// What she remembers about you, all of it, with a way to delete any of it.
private struct MemoryPage: View {
    @AppStorage(PalMemoryStore.isOnKey) private var remembers = true
    @State private var isConfirmingForget = false
    private let store = PalMemoryStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Remember Our Talks", isOn: $remembers)
            } footer: {
                Text("She writes down what's worth remembering as you talk: about you and how you like her to be, which goes with every talk; about each notebook and PDF, which goes along only while it's open; and a line about each talk, which she looks up only when it helps. It's kept in your iCloud, so it's the same on all your iPads. Swipe to delete anything.")
            }

            if store.isEmpty {
                Section {
                    Text("Nothing yet. Talk with her, and what she learns shows up here.")
                        .foregroundStyle(.secondary)
                }
            }

            notes("About You", store.aboutNotes)
            notes("How She Is with You", store.styleNotes)

            ForEach(store.itemsWithNotes, id: \.id) { entry in
                Section("“\(entry.item.title)”") {
                    ForEach(entry.item.notes) { note in
                        Text(note.text)
                    }
                    .onDelete { offsets in
                        for index in offsets { store.deleteItemNote(entry.item.notes[index].id, from: entry.id) }
                    }
                }
            }

            let talks = store.recentTalks
            if !talks.isEmpty {
                Section("Talks") {
                    ForEach(talks) { talk in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(talk.summary)
                            Text(talk.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { store.deleteTalk(talks[index].id) }
                    }
                }
            }

            if !store.isEmpty {
                Section {
                    Button("Forget Everything", role: .destructive) { isConfirmingForget = true }
                }
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget everything she remembers about you?", isPresented: $isConfirmingForget, titleVisibility: .visible) {
            Button("Forget Everything", role: .destructive) { store.forgetEverything() }
        } message: {
            Text("This can't be undone.")
        }
    }

    @ViewBuilder
    private func notes(_ title: String, _ notes: [PalMemory.Note]) -> some View {
        if !notes.isEmpty {
            Section(title) {
                ForEach(notes) { note in
                    Text(note.text)
                }
                .onDelete { offsets in
                    for index in offsets { store.deleteNote(notes[index].id) }
                }
            }
        }
    }
}

// MARK: Privacy

/// What stays on the iPad and what leaves it, in plain words.
private struct PrivacyPage: View {
    var body: some View {
        Form {
            Section("Stays on Your iPad") {
                Text("Your API keys, in the Keychain. Your voice: what you say to your study pal is turned into text on the iPad. Her reminders, which are notifications on this iPad. The AI usage log in Settings → AI Usage: which model each request went to, its token counts and its cost, never what was said.")
            }
            Section("Kept in Your iCloud") {
                Text("Your notebooks, pages, PDFs, handwriting, typed notes and chats with her. Her memory, which you can read and delete in Settings → Memory, her name and your settings. They're saved to your own iCloud, never to a Memor server, so they're on all your iPads and come back if you reinstall Memor.")
            }
            Section("Sent to Her Mind (Anthropic or OpenAI), When You Message Her") {
                Text("Your message as text, pictures of the pages on your screen and their text, what you circled or selected, what she remembers about you and those notes, and what she finds when she searches your notes for you. When a talk pauses, the same company's small model writes down what she should remember from it.")
            }
            Section("Sent to OpenAI for Her Voice and Pictures") {
                Text("What she says, to be spoken in her voice, and descriptions of the pictures she draws.")
            }
            Section("Never") {
                Text("No accounts, analytics or tracking, and no Memor server: everything goes straight from your iPad to the service it's for.")
            }
        }
        .foregroundStyle(.primary)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
