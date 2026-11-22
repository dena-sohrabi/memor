import SwiftUI

/// The study pal's chat card: your talk with her, what you circled, a few
/// things to ask, and a field to type in, with the mic and the circle tool
/// beside it. It grows with the talk, up to `maxHeight`. Drag it by its top.
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
        // Chat mode: tapping her puts the cursor here.
        .onChange(of: pal.typingRequests) { isTyping = true }
        .onAppear { if !pal.isVoiceMode { isTyping = true } }
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
                             ? "Hold the mic and talk to me, or type. Circle anything on your page to show me."
                             : "I need an OpenAI key to think and talk. Add one in Settings.")
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
                        Text(brain.status ?? "Thinking…").foregroundStyle(.secondary)
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

/// The voice-message button. Hold it while you talk and let go to send
/// (slide away first to cancel), or tap it, talk, and tap it again.
struct PalMicButton: View {
    enum Style {
        /// In her card, beside the text field.
        case inline
        /// On its own, beside her.
        case floating
    }

    let style: Style

    @State private var pressedAt: Date?
    /// A quick tap started it: the next tap sends.
    @State private var isTapMode = false
    @State private var isSecondTap = false
    @State private var willCancel = false

    private var listener: StudyPalListener { Pal.shared.listener }

    /// Shorter than this is a tap, not a hold.
    private static let tapLength: TimeInterval = 0.35

    var body: some View {
        let listening = listener.isListening
        let level = CGFloat(listener.level)
        Image(systemName: willCancel ? "xmark" : (listening ? "waveform" : "mic.fill"))
            .font(.system(size: style == .floating ? 22 : 20, weight: .semibold))
            .symbolEffect(.variableColor.iterative, isActive: listening && !willCancel)
            .foregroundStyle(listening ? (willCancel ? Color.red : Color.white) : (style == .floating ? Color.primary : Color.secondary))
            .frame(width: style == .floating ? 54 : 32, height: style == .floating ? 54 : 36)
            .background {
                if style == .floating || listening {
                    Circle()
                        .fill(listening ? (willCancel ? Color.red.opacity(0.18) : Color.green) : Color.clear)
                        .scaleEffect(listening ? 1 + level * 0.25 : 1)
                        .animation(.easeOut(duration: 0.12), value: level)
                }
            }
            .glassEffect(style == .floating ? .regular.interactive() : .identity, in: .circle)
            .contentShape(.circle)
            .overlay(alignment: style == .floating ? .top : .topTrailing) {
                if listening, let hint {
                    Text(hint)
                        .font(.caption.weight(.medium))
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .offset(y: -44)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { pressing($0) }
                    .onEnded { released($0) }
            )
            .onChange(of: listening) { _, listening in
                // She stopped on her own (or was cancelled).
                if !listening { reset() }
            }
            .accessibilityElement()
            .accessibilityLabel(listening ? "Send Voice Message" : "Talk")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if listener.isListening { Pal.shared.finishRecording() } else { Pal.shared.startRecording(holding: false) }
            }
            .animation(.snappy, value: listening)
    }

    private var hint: String? {
        if willCancel { return "Let go to cancel" }
        if isTapMode { return "Tap to send" }
        return pressedAt != nil ? "Let go to send" : nil
    }

    private func pressing(_ value: DragGesture.Value) {
        if pressedAt == nil, !isSecondTap {
            if isTapMode, listener.isListening {
                // The tap that sends.
                isSecondTap = true
                return
            }
            pressedAt = .now
            Pal.shared.startRecording(holding: true)
        }
        if pressedAt != nil, !isTapMode {
            willCancel = hypot(value.translation.width, value.translation.height) > 90
        }
    }

    private func released(_ value: DragGesture.Value) {
        if isSecondTap {
            reset()
            Pal.shared.finishRecording()
            return
        }
        guard let pressedAt else { return }
        self.pressedAt = nil
        if willCancel {
            reset()
            Pal.shared.cancelRecording()
        } else if Date.now.timeIntervalSince(pressedAt) < Self.tapLength {
            isTapMode = true
            Pal.shared.recordingBecameTap()
        } else {
            reset()
            Pal.shared.finishRecording()
        }
    }

    private func reset() {
        pressedAt = nil
        isTapMode = false
        isSecondTap = false
        willCancel = false
    }
}
