import SwiftUI

/// Options the study pal wants you to pick from, in a small glass card:
/// pictures in a grid, or plain choices as buttons. Tap one, or just tell her.
struct AskChoiceCard: View {
    let choice: PalChoice
    let width: CGFloat
    let onPick: (PalChoice.Option) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(choice.question.isEmpty ? "Choose one" : choice.question)
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            if choice.hasPictures {
                pictures
            } else {
                buttons
            }
            Text("Tap one, or just tell her.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: width)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
    }

    private var pictures: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12)], spacing: 12) {
            ForEach(choice.options) { option in
                Button { onPick(option) } label: {
                    VStack(spacing: 6) {
                        AsyncImage(url: option.imageURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            default:
                                ProgressView()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 112)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(.rect(cornerRadius: 12))
                        Text(option.label)
                            .font(.footnote)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            ForEach(choice.options) { option in
                Button { onPick(option) } label: {
                    Text(option.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 11)
                        .padding(.horizontal, 14)
                        .background(.background.opacity(0.6), in: .rect(cornerRadius: 14))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The first time you tap the study pal, she asks what you'd like to call
/// her. Her name is yours to choose; you can change it in Settings, or
/// just tell her a new one.
struct AskNameCard: View {
    let width: CGFloat
    let onName: (String) -> Void
    let onLater: () -> Void

    @State private var name = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hi! I'm new here.")
                    .font(.headline)
                Text("What would you like to call me?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            TextField("My name", text: $name)
                .font(.title3)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isFocused)
                .onSubmit(save)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(.background.opacity(0.6), in: .rect(cornerRadius: 14))
            HStack {
                Button("Not Now", action: onLater)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("That's Me", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(18)
        .frame(width: width)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        .onAppear { isFocused = true }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onName(String(trimmed.prefix(30)))
    }
}

/// A short note over the study pal's head when something goes wrong in a
/// spoken chat, with Try Again when that can help.
struct AskNotice: View {
    let text: String
    let canRetry: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            if canRetry {
                Button("Try Again", action: onRetry)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onTapGesture(perform: onDismiss)
    }
}
