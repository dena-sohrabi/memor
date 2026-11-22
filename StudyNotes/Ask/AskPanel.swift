import SwiftUI

/// The glass chat panel: the circled area (if any), Claude's answers and a
/// field for follow-ups, typed or said out loud. It starts small and grows
/// with the conversation, up to `maxHeight`. Drag it by its top to move it.
struct AskPanel: View {
    let session: AskSession
    let maxHeight: CGFloat
    /// Listens for a spoken follow-up; what you say fills the field.
    let listener: StudyPalListener
    let onListen: () -> Void
    /// The panel is being dragged this far.
    let onMove: (CGSize) -> Void
    /// It was let go this far from where it started.
    let onMoveEnded: (CGSize) -> Void
    let onClose: () -> Void
    /// Why she couldn't say her answer out loud, if something went wrong.
    var voiceProblem: String?
    /// A follow-up was typed and sent (not said), so she stops talking.
    var onTypedQuestion: () -> Void = {}
    /// The question field went from empty to not, so the study pal listens.
    var onStartTyping: () -> Void = {}

    @State private var question = ""
    @State private var contentHeight: CGFloat = 0
    @FocusState private var isTyping: Bool

    private static let chromeHeight: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            conversation
            inputBar
        }
        .frame(width: 380)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        .onChange(of: question.isEmpty) { _, isEmpty in
            if !isEmpty, !listener.isListening { onStartTyping() }
        }
        .onChange(of: listener.transcript) { _, transcript in
            if listener.isListening { question = transcript }
        }
        .onChange(of: isTyping) { _, typing in
            // Typing takes over from listening.
            if typing, listener.isListening { listener.cancel() }
        }
        .onChange(of: listener.heard) {
            // What you said was sent as a follow-up.
            question = ""
        }
    }

    /// Its top is the handle you move it by. The gesture is measured on
    /// the screen, not in the panel, so the panel doesn't shake as it moves.
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
        .padding(.top, 14)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Capsule()
                .fill(.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 5)
        }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { onMove($0.translation) }
                .onEnded { onMoveEnded($0.translation) }
        )
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let image = session.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 180)
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5)
                            }
                            .accessibilityLabel("The area you circled")
                    }

                    ForEach(session.messages) { message in
                        MessageView(
                            message: message,
                            canAddToPage: isFinished(message),
                            isAddingToPage: session.addingToPageID == message.id,
                            onAddToPage: { session.addToPage(message) }
                        )
                    }

                    // The study pal shows that Claude is thinking; this says what about.
                    if session.isWorking, !session.isAnswering {
                        Text(session.status ?? "Thinking…").foregroundStyle(.secondary)
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 44), max(maxHeight - Self.chromeHeight, 120)))
            .onChange(of: session.messages.last?.text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: session.messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(listener.isListening ? "Listening…" : "Ask about this…", text: $question, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isTyping)
                    .onSubmit(send)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.background.opacity(0.6), in: .rect(cornerRadius: 20))
                MicButton(listener: listener, onListen: onListen)
                    .disabled(session.isWorking)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            if let problem = listener.problem ?? voiceProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
        .padding(12)
    }

    /// An answer that's done streaming, so it can be put on the page.
    private func isFinished(_ message: AskSession.Message) -> Bool {
        guard message.role == .assistant, !message.text.isEmpty else { return false }
        return !(session.isWorking && message.id == session.messages.last?.id)
    }

    private var canSend: Bool {
        !session.isWorking && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        // Sent by hand: stop listening, or it would send again.
        if listener.isListening { listener.cancel() }
        onTypedQuestion()
        session.ask(question)
        question = ""
    }
}

private struct MessageView: View {
    let message: AskSession.Message
    let canAddToPage: Bool
    let isAddingToPage: Bool
    /// Writes the answer's key points on the page.
    let onAddToPage: () -> Void

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
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(markdown: message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if canAddToPage {
                    Button(action: onAddToPage) {
                        if isAddingToPage {
                            Label {
                                Text("Writing the key points…")
                            } icon: {
                                ProgressView().controlSize(.mini)
                            }
                        } else {
                            Label("Add to Page", systemImage: "text.badge.plus")
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.borderless)
                    .disabled(isAddingToPage)
                }
            }
        }
    }
}

/// The small glass box that shows while the Ask tool is on and nothing is
/// circled: type or say a question, and it opens the chat panel. Tapping
/// the study pal opens it ready to type; tap the mic to talk instead, and
/// what you say fills the field and sends when you pause. The study pal
/// floats beside it (see `AskOverlay`).
struct AskComposeBar: View {
    let onSend: (String) -> Void
    let onCancel: () -> Void
    var width: CGFloat = 480
    let listener: StudyPalListener
    let onListen: () -> Void
    /// The field went from empty to not, so the study pal listens.
    var onStartTyping: () -> Void = {}

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(listener.isListening ? "Listening…" : "Ask anything, or circle part of the page", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($isFocused)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                MicButton(listener: listener, onListen: onListen)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .accessibilityLabel("Send")
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            if let problem = listener.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(width: width)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 3)
        .onChange(of: text.isEmpty) { _, isEmpty in
            if !isEmpty, !listener.isListening { onStartTyping() }
        }
        .onChange(of: listener.transcript) { _, transcript in
            if listener.isListening { text = transcript }
        }
        .onChange(of: isFocused) { _, focused in
            // Typing takes over from listening.
            if focused, listener.isListening { listener.cancel() }
        }
        .onChange(of: listener.problem) { _, problem in
            // Listening can't work here: type instead.
            if problem != nil { isFocused = true }
        }
        .onAppear {
            // Ready to type, unless you're already talking.
            if !listener.isListening { isFocused = true }
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        // Sent by hand: stop listening, or it would send again.
        if listener.isListening { listener.cancel() }
        onSend(text)
        text = ""
    }
}

/// Speak instead of typing. While the study pal listens, it shows a moving
/// waveform; tap it again to send what you said.
struct MicButton: View {
    let listener: StudyPalListener
    let onListen: () -> Void

    var body: some View {
        Button {
            if listener.isListening { listener.stop() } else { onListen() }
        } label: {
            Image(systemName: listener.isListening ? "waveform" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: listener.isListening)
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(listener.isListening ? Color.accentColor : Color.secondary)
        .accessibilityLabel(listener.isListening ? "Stop Listening" : "Speak")
    }
}
