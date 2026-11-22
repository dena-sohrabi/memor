import SwiftUI

/// Memor's settings, grouped like the iPad's own:
/// - Ask Claude: your Claude API key, on a page of its own.
/// - Study Pal: her name, her memory, voice conversations, her voice and
///   her sounds.
/// - Voice and Pictures: your optional OpenAI key.
/// - About: what leaves your iPad, and the version.
///
/// Opened because Ask Claude needs a key (`onKeySaved` set), it goes
/// straight to the Claude key, and closes once one is saved.
struct SettingsView: View {
    var onKeySaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(StudyPalVoice.isEnabledKey) private var palSounds = true
    @AppStorage(StudyPalSpeaker.isEnabledKey) private var palSpeaks = true
    @AppStorage(StudyPalSpeaker.voiceKey) private var palVoice = StudyPalSpeaker.defaultVoice
    @AppStorage(StudyPalCharacter.nameKey) private var palName = ""
    @AppStorage(PalMemoryStore.isOnKey) private var remembers = true
    @State private var hasClaudeKey = APIKeyStore.hasKey
    @State private var hasOpenAIKey = OpenAIKeyStore.hasKey

    var body: some View {
        NavigationStack {
            Group {
                if let onKeySaved {
                    APIKeyPage(kind: .claude) {
                        onKeySaved()
                        dismiss()
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
    }

    private var settings: some View {
        Form {
            Section {
                NavigationLink {
                    APIKeyPage(kind: .claude) { hasClaudeKey = APIKeyStore.hasKey }
                } label: {
                    SettingsRow("Claude API Key", systemImage: "sparkles", color: .orange,
                                value: hasClaudeKey ? "Connected" : "Not Set Up")
                }
            } header: {
                Text("Ask Claude")
            } footer: {
                Text("Claude answers your questions, knows your page and can work on it with you.")
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
                Toggle(isOn: $palSpeaks) {
                    SettingsLabel("Voice Conversations", systemImage: "phone.fill", color: .green)
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
            } header: {
                Text("Study Pal")
            } footer: {
                Text(hasOpenAIKey
                    ? "Switch between Voice and Chat beside her. Voice: tap her and talk, like a call. Chat: tap her and type, and Claude answers in the chat panel."
                    : "Add an OpenAI key below to talk with her out loud.")
            }

            Section {
                NavigationLink {
                    APIKeyPage(kind: .openAI) { hasOpenAIKey = OpenAIKeyStore.hasKey }
                } label: {
                    SettingsRow("OpenAI API Key", systemImage: "waveform", color: .teal,
                                value: hasOpenAIKey ? "Connected" : "Optional")
                }
            } header: {
                Text("Voice and Pictures")
            } footer: {
                Text("Optional. Gives your study pal a voice, and lets Claude draw pictures for your page.")
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
private struct SettingsIcon: View {
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

private struct SettingsLabel: View {
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
private struct SettingsRow: View {
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
        case .claude: "Claude API Key"
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
            "Claude answers what you ask your study pal, reads the page you're on and can add, move and tidy things on it. Your questions, the page you ask about and what you circle go straight to Anthropic."
        case .openAI:
            "Gives your study pal a voice. In Voice mode, OpenAI's realtime model talks with you as her: what you say (turned into text on your iPad), pictures of your page, its typed notes and what she remembers about you go to OpenAI, and she answers out loud and can write notes and draw pictures on your page. After a call, OpenAI writes down what she should remember. Your voice itself never leaves your iPad. Chat mode stays with Claude."
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
                Text("After each call or chat, she writes down what's worth remembering: what you're studying, your exams, what helps you, how you like her to be, and what you talked about. It stays on this iPad and goes with your next talks, so she picks up where you left off and gets to know you. Swipe to delete anything.")
            }

            if store.isEmpty {
                Section {
                    Text("Nothing yet. Talk with her, and what she learns about you shows up here.")
                        .foregroundStyle(.secondary)
                }
            }

            notes("About You", store.aboutNotes)
            notes("How She Is with You", store.styleNotes)

            let talks = store.recentTalks
            if !talks.isEmpty {
                Section("Recent Talks") {
                    ForEach(talks) { talk in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(talk.summary)
                            Text("\(talk.wasCall ? "Call" : "Chat"), \(talk.date.formatted(date: .abbreviated, time: .shortened))")
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
                Text("Your notebooks, pages, PDFs and handwriting. Your API keys, in the Keychain. Your voice: what you say to your study pal is turned into text on the iPad. Her memory of you, which you can read and delete in Settings → Memory.")
            }
            Section("Sent to Anthropic") {
                Text("In Chat mode, when you ask Claude something: your question as text, the page you're on, what you circled, and what she remembers about you. When a chat closes, Claude writes down what she should remember from it.")
            }
            Section("Sent to OpenAI, Only with an OpenAI Key") {
                Text("In Voice mode: what you say to your study pal, as text, pictures of the page you're on and its typed notes, so she can talk with you about it, what she remembers about you, and the descriptions of pictures she draws. When a call ends, OpenAI writes down what she should remember from it.")
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
