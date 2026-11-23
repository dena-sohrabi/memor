import SwiftUI

/// The study pal's chat card (Chat mode only): your talk with her, what you
/// circled, a few things to ask, and a field to type in, with the mic and
/// the circle tool beside it. While she works, a line says what she's
/// doing ("Creating an image…"). It grows with the talk, up to `maxHeight`.
/// Drag it by its top.
struct PalPalette: View {
    let maxHeight: CGFloat
    /// The card is being dragged this far.
    let onMove: (CGSize) -> Void
    /// It was let go this far from where it started.
    let onMoveEnded: (CGSize) -> Void
    /// There's no OpenAI key yet: Settings should open.
    let onNeedsKey: () -> Void

    @State private var draft = ""
    @State private var contentHeight: CGFloat = 0
    @FocusState private var isTyping: Bool
    @AppStorage(StudyPalCharacter.nameKey) private var palName = ""

    private var pal: Pal { .shared }
    private var brain: PalBrain { pal.brain }
    private static let chromeHeight: CGFloat = 190

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            conversation
            attachment
            suggestions
            inputBar
        }
        .frame(width: 380)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        .onChange(of: isTyping) { _, typing in
            // Typing takes over from talking.
            if typing, pal.listener.isListening { pal.cancelRecording() }
        }
        .task {
            // Opens ready for the next message. Focus set the moment it
            // appears, mid-transition, is often dropped.
            try? await Task.sleep(for: .milliseconds(150))
            if !pal.listener.isListening { isTyping = true }
        }
    }

    // MARK: Header

    /// Its top is the handle you move it by. The gesture is measured on the
    /// screen, not in the card, so the card doesn't shake as it moves.
    private var header: some View {
        HStack(spacing: 4) {
            Text(palName.isEmpty ? "Your Study Pal" : palName)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            iconButton("square.and.pencil", label: "New Topic") {
                draft = ""
                pal.startNewTopic()
            }
            .disabled(brain.messages.isEmpty)
            iconButton("xmark", label: "Close") {
                pal.closePalette()
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.top, 14)
        .padding(.bottom, 10)
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

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if brain.messages.isEmpty {
                        Text(pal.hasKey
                             ? "Write to me, or tap the mic and talk. Circle anything on your page to show me."
                             : "I need an API key to think. Add one in Settings.")
                            .foregroundStyle(.secondary)
                        if !pal.hasKey {
                            Button("Open Settings", action: onNeedsKey)
                                .buttonStyle(.bordered)
                        }
                    }

                    ForEach(brain.messages) { message in
                        PalMessageView(
                            message: message,
                            isFinished: isFinished(message),
                            onPutOnPage: {
                                pal.send("Put the key points of that on my page, where they belong and the way my notes are written.")
                            }
                        )
                    }

                    if brain.isWorking, !brain.isAnswering {
                        PalStatusLine(activity: brain.status ?? .thinking, hasHalo: false)
                    }

                    if let errorText = brain.errorText {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(errorText, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            if brain.canRetry {
                                Button("Try Again") { pal.retry() }
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
            .onChange(of: brain.messages.last?.text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: brain.messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// A reply that's done, so it can go on the page.
    private func isFinished(_ message: PalBrain.Message) -> Bool {
        guard message.role == .pal, !message.text.isEmpty else { return false }
        return !(brain.isWorking && message.id == brain.messages.last?.id)
    }

    // MARK: Attachment and suggestions

    /// What you circled, waiting to go with your next message.
    @ViewBuilder
    private var attachment: some View {
        if let circle = pal.attachedCircle, let image = UIImage(data: circle.image) {
            HStack(spacing: 10) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 120, maxHeight: 64)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5) }
                    .accessibilityLabel("What you circled")
                Text("Goes with your next message.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { pal.removeAttachment() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    private var suggestionTexts: [String] {
        if pal.attachedCircle != nil {
            return ["What does this mean?", "Explain this", "Check my work", "Write the answer beside it"]
        }
        if brain.messages.isEmpty, pal.hasKey {
            return PalWorkspace.shared.focusedPage == nil
                ? ["What should I study now?", "Quiz me on something"]
                : ["Explain what's on my page", "Quiz me on this", "Did I get this right?"]
        }
        return []
    }

    @ViewBuilder
    private var suggestions: some View {
        let texts = suggestionTexts
        if !texts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(texts, id: \.self) { text in
                        Button(text) { pal.send(text) }
                            .font(.footnote.weight(.medium))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.top, 8)
        }
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                if PalWorkspace.shared.focusedPage != nil {
                    Button {
                        if pal.isCircling { pal.stopCircling() } else { pal.startCircling() }
                    } label: {
                        Image(systemName: "lasso.badge.sparkles")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 32, height: 36)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(pal.isCircling ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(pal.isCircling ? "Stop Circling" : "Circle Something to Show Her")
                }
                TextField(fieldPrompt, text: listeningBinding, axis: .vertical)
                    .lineLimit(1...10)
                    .focused($isTyping)
                    .onSubmit(send)
                    .disabled(!pal.hasKey || pal.listener.isListening)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.background.opacity(0.6), in: .rect(cornerRadius: 20))
                PalMicButton(style: .inline)
                    .disabled(!pal.hasKey)
                if brain.isWorking, draft.isEmpty {
                    Button { pal.interrupt() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
            if let note = pal.listener.problem ?? pal.speaker.problem {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            } else if pal.isCircling {
                Text("Draw a loop around anything on the page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
        .padding(12)
    }

    private var fieldPrompt: String {
        if pal.listener.isListening { return "Listening…" }
        return pal.attachedCircle != nil ? "Ask about what you circled…" : "Ask me anything…"
    }

    /// While you talk, the field shows what she's hearing.
    private var listeningBinding: Binding<String> {
        Binding(
            get: { pal.listener.isListening ? pal.listener.transcript : draft },
            set: { if !pal.listener.isListening { draft = $0 } }
        )
    }

    private var canSend: Bool {
        pal.hasKey && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pal.attachedCircle != nil)
    }

    private func send() {
        guard canSend else { return }
        pal.send(draft)
        draft = ""
    }
}

/// One message in her card: yours on the right, hers on the left.
private struct PalMessageView: View {
    let message: PalBrain.Message
    let isFinished: Bool
    let onPutOnPage: () -> Void

    var body: some View {
        switch message.role {
        case .student:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if let data = message.circled, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 200, maxHeight: 120)
                            .clipShape(.rect(cornerRadius: 10))
                            .accessibilityLabel("What you circled")
                    }
                    if !message.text.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if message.wasSpoken {
                                Image(systemName: "waveform")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Said out loud")
                            }
                            Text(message.text)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 16))
                    }
                }
            }
        case .pal:
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(markdown: message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isFinished {
                    Button(action: onPutOnPage) {
                        Label("Put It on My Page", systemImage: "text.badge.plus")
                    }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

/// The voice-message button. Tap it and talk, then tap it again to send,
/// like dictation in ChatGPT or Claude: a pause never sends it. While
/// she listens it turns green with a send arrow, swelling with your voice,
/// and a small ✕ beside it drops the message instead. No words: what's
/// happening shows in the button itself.
struct PalMicButton: View {
    enum Style {
        /// In her card, beside the text field. The ✕ goes before it.
        case inline
        /// On its own, beside her, as wide as the Voice/Chat switch. The ✕
        /// goes over it, or under it when the switch is over it.
        case floating(cancelBelow: Bool)
    }

    let style: Style

    /// As wide as the Voice/Chat switch: two 34-point buttons in 4 points
    /// of padding.
    static let floatingSize: CGFloat = 42

    private var listener: StudyPalListener { Pal.shared.listener }

    private var isFloating: Bool {
        if case .floating = style { return true }
        return false
    }

    var body: some View {
        let listening = listener.isListening
        switch style {
        case .inline:
            HStack(spacing: 2) {
                if listening {
                    cancelButton(size: 32, glass: false)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                button(listening: listening)
            }
            .animation(.snappy, value: listening)
        case .floating(let cancelBelow):
            button(listening: listening)
                .overlay(alignment: cancelBelow ? .bottom : .top) {
                    if listening {
                        cancelButton(size: 32, glass: true)
                            .offset(y: cancelBelow ? 32 + 8 : -(32 + 8))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: listening)
        }
    }

    private func button(listening: Bool) -> some View {
        let level = CGFloat(listener.level)
        let size: CGSize = isFloating ? CGSize(width: Self.floatingSize, height: Self.floatingSize) : CGSize(width: 32, height: 36)
        let circle = isFloating ? Self.floatingSize : 30
        return Button {
            if listener.isListening { Pal.shared.finishRecording() } else { Pal.shared.startRecording() }
        } label: {
            Image(systemName: listening ? "arrow.up" : "mic.fill")
                .font(.system(size: isFloating ? 18 : (listening ? 15 : 20), weight: listening ? .bold : .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(listening ? Color.white : (isFloating ? Color.primary : Color.secondary))
                .frame(width: size.width, height: size.height)
                .background {
                    if listening {
                        ZStack {
                            // Swells with your voice.
                            Circle()
                                .fill(Color.green.opacity(0.3))
                                .frame(width: circle, height: circle)
                                .scaleEffect(1 + level * 0.45)
                                .animation(.easeOut(duration: 0.12), value: level)
                            Circle()
                                .fill(Color.green)
                                .frame(width: circle, height: circle)
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .glassEffect(isFloating && !listening ? .regular.interactive() : .identity, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listening ? "Send Voice Message" : "Talk")
    }

    private func cancelButton(size: CGFloat, glass: Bool) -> some View {
        Button { Pal.shared.cancelRecording() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .glassEffect(glass ? .regular.interactive() : .identity, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel Voice Message")
    }
}

/// Chat mode: the box beside her for writing to her, while her card is
/// closed. Tapping her puts the cursor here. Send, and her card opens with
/// your talk (its own field takes the next message); close the card and
/// this box is back. With a talk going, the bubbles button opens the card
/// without sending anything.
struct PalComposeBar: View {
    let width: CGFloat
    /// There's no key for her mind yet: Settings should open.
    let onNeedsKey: () -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool
    @AppStorage(StudyPalCharacter.nameKey) private var palName = ""

    private var pal: Pal { .shared }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField(prompt, text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($isFocused)
                .onSubmit(send)
                .disabled(!pal.hasKey)
                .padding(.vertical, 10)
                .padding(.leading, 16)
            if !pal.brain.messages.isEmpty {
                Button { pal.openPalette() } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 40)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Show Chat")
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .frame(height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .frame(width: width)
        .glassEffect(.regular, in: .rect(cornerRadius: 23))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 3)
        .overlay {
            // Without a key the field can't be used; tapping it says where to add one.
            if !pal.hasKey {
                Color.clear
                    .contentShape(.rect(cornerRadius: 23))
                    .onTapGesture(perform: onNeedsKey)
            }
        }
        .onChange(of: pal.typingRequests) { isFocused = true }
    }

    private var prompt: String {
        guard pal.hasKey else { return "Add a key in Settings to chat" }
        let name = palName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Write to your study pal…" : "Write to \(name)…"
    }

    private var canSend: Bool {
        pal.hasKey && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        pal.send(draft)
        draft = ""
        pal.openPalette()
    }
}
