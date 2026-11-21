import SwiftUI

/// The glass chat panel that slides in on the side after you circle
/// something: the circled area, Claude's answer, and a field for follow-ups.
struct AskPanel: View {
    let session: AskSession
    let onClose: () -> Void

    @State private var question = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            conversation
            inputBar
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
    }

    private var header: some View {
        HStack {
            Label("Ask Claude", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Image(uiImage: session.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5)
                        }
                        .accessibilityLabel("The area you circled")

                    ForEach(session.messages) { message in
                        MessageView(message: message)
                    }

                    if session.isWorking, session.messages.last?.text.isEmpty ?? true {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Thinking…").foregroundStyle(.secondary)
                        }
                    }

                    if let errorText = session.errorText {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(errorText, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            if session.canRetry {
                                Button("Try Again") { session.retry() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(18)
            }
            .onChange(of: session.messages.last?.text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: session.messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this…", text: $question, axis: .vertical)
                .lineLimit(1...5)
                .focused($isFieldFocused)
                .onSubmit(send)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.background.opacity(0.6), in: .rect(cornerRadius: 20))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(12)
    }

    private var canSend: Bool {
        !session.isWorking && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        session.ask(question)
        question = ""
    }
}

private struct MessageView: View {
    let message: AskSession.Message

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 16))
            }
        case .assistant:
            Text(Self.formatted(message.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Bold, italics, code and links from Claude's Markdown, keeping its line breaks.
    private static func formatted(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
