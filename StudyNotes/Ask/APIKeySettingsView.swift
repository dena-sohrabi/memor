import SwiftUI

/// Where you add, check and remove your Claude API key, with a plain
/// explanation of where it's kept and what gets sent.
struct APIKeySettingsView: View {
    var onSaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var savedHint = APIKeyStore.maskedHint()
    @State private var isChecking = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let savedHint {
                        LabeledContent("Saved key", value: savedHint)
                            .privacySensitive()
                        Button("Remove Key", role: .destructive) {
                            APIKeyStore.delete()
                            self.savedHint = nil
                            message = "The key was removed from this iPad."
                        }
                    }
                    SecureField(savedHint == nil ? "Paste your API key" : "Replace with a new key", text: $keyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .onSubmit(save)
                    Button(isChecking ? "Checking…" : "Save Key", action: save)
                        .disabled(trimmedKey.isEmpty || isChecking)
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Claude API Key")
                } footer: {
                    Text("Create a key at platform.claude.com under API Keys. Anthropic bills your account for each question, usually a few cents. A Claude Pro or Max subscription can't be used here, but some plans include monthly API credits you can claim on claude.ai.")
                }

                Section("Privacy") {
                    Label("Your key is stored only in this iPad's Keychain. It isn't backed up, synced or shared, and it's sent only to Anthropic to sign your requests.", systemImage: "lock.shield")
                    Label("When you circle something and ask, Memor sends that part of the page and your questions straight to Anthropic. Nothing goes to Memor or anyone else.", systemImage: "paperplane")
                    Label("Memor is open source, so anyone can check how this works.", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .font(.footnote)
            }
            .navigationTitle("Ask Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var trimmedKey: String {
        keyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let key = trimmedKey
        guard !key.isEmpty, !isChecking else { return }
        isChecking = true
        message = nil
        Task {
            defer { isChecking = false }
            do {
                try await ClaudeClient.validate(key: key)
                guard APIKeyStore.save(key) else {
                    message = "Couldn't save the key to the Keychain."
                    return
                }
                keyText = ""
                savedHint = APIKeyStore.maskedHint()
                onSaved?()
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
