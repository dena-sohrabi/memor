import SwiftUI

/// The study pal on top of a window: the library, a notebook or a PDF.
/// Every window has one of these, but she only shows in the window you
/// used last, so there's always exactly one of her. Use another window and
/// she's there instead.
///
/// - Tap her to open or close her chat card (the first time, she asks for
///   a name); in Chat mode it opens ready to type. Tap her while she talks
///   to hush her.
/// - The switch beside her picks Voice (she talks back, listens for her
///   name, and the mic is there) or Chat (she only writes).
/// - The mic beside her sends voice messages: hold it while you talk and
///   let go, or tap, talk and tap again. Slide away while holding to cancel.
/// - While her card is closed, a bubble over her head shows what she's
///   doing and what she says.
/// - Rub her to scratch her, and carry her anywhere; she keeps her spot.
struct PalOverlay: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @State private var window: ObjectIdentifier?
    @State private var cue = StudyPalCue()
    @State private var showsSettings = false
    @State private var isNaming = false
    /// Her last words stay over her head a little after she's done.
    @State private var lingers = false
    @State private var lingerTask: Task<Void, Never>?
    @State private var panelDrag = CGSize.zero
    @AppStorage(StudyPalCharacter.nameKey) private var palName = ""
    /// You chose Not Now when she asked for a name.
    @AppStorage("studyPal.nameAsked") private var nameAsked = false
    /// Her spot, as a share of the window's width and height.
    @AppStorage("studyPal.x") private var seatX = 0.88
    @AppStorage("studyPal.y") private var seatY = 0.8
    /// How far you moved her card from the top-right corner.
    @AppStorage("askPanel.x") private var panelX = 0.0
    @AppStorage("askPanel.y") private var panelY = 0.0

    private var pal: Pal { .shared }
    private var brain: PalBrain { pal.brain }

    /// This is the window she's in.
    private var isHere: Bool {
        guard let window else { return false }
        return PalWorkspace.shared.activeWindow == window
    }

    private var isOut: Bool { isHere }

    var body: some View {
        reacting(to: stage)
            .background {
                WindowReader { found in
                    window = ObjectIdentifier(found)
                    PalWorkspace.shared.windowAppeared(found)
                    // So she can open notebooks and PDFs in their windows.
                    pal.openWindow = openWindow
                }
                .frame(width: 0, height: 0)
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
    }

    private var stage: some View {
        GeometryReader { proxy in
            let layout = Layout(
                size: proxy.size,
                safeTop: proxy.safeAreaInsets.top,
                bottomInset: proxy.safeAreaInsets.bottom,
                isPaletteOpen: pal.isPaletteOpen,
                hasMic: pal.isVoiceMode && pal.hasKey,
                seat: CGPoint(x: seatX, y: seatY),
                panelOffset: CGSize(width: panelX, height: panelY)
            )
            ZStack(alignment: .topLeading) {
                if isOut {
                    palette(layout, size: proxy.size)
                    listeningGlow(layout)
                    perch(layout, size: proxy.size)
                    mic(layout)
                    modeSwitch(layout)
                    bubble(layout)
                    choices(in: proxy.size)
                    nameCard(in: proxy.size)
                }
            }
            .coordinateSpace(.named(StudyPalPerch.space))
            .animation(.spring(duration: 0.35, bounce: 0.2), value: brain.pendingChoice?.id)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: pal.isPaletteOpen)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: isNaming)
            .animation(.easeInOut(duration: 0.25), value: bubbleText)
            .animation(.spring(duration: 0.4, bounce: 0.2), value: isOut)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: pal.isVoiceMode)
        }
    }

    /// Her reactions to what happens: hello, a nod when she's done, delight
    /// when she changed a page, a sad look when something went wrong.
    private func reacting(to content: some View) -> some View {
        content
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { pal.appWentToBackground() }
        }
        .onChange(of: brain.pageChanges) { old, new in
            if isHere, new > old { play(.delight) }
        }
        .onChange(of: brain.finishedReplies) {
            guard isHere else { return }
            play(brain.errorText != nil ? .sad : .nod)
            linger()
        }
        .onChange(of: brain.errorText) { _, error in
            if isHere, error != nil { play(.sad) }
        }
        .onChange(of: pal.listener.isListening) { _, listening in
            if isHere, listening { play(.listen) }
        }
        .onChange(of: pal.wake.state) { _, state in
            // She heard her name.
            if isHere, state == .capturing { play(.listen) }
        }
        .onChange(of: isOut) { _, out in
            if out { play(.wave) }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func palette(_ layout: Layout, size: CGSize) -> some View {
        if pal.isPaletteOpen {
            PalPalette(
                maxHeight: size.height - layout.panelTop - 16 - layout.panelOffset.height,
                onMove: { panelDrag = $0 },
                onMoveEnded: { movePanel(by: $0, in: size, safeTop: layout.panelTop) },
                onNeedsKey: { showsSettings = true }
            )
            .padding(.trailing, 12)
            .padding(.top, layout.panelTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .offset(
                x: layout.panelOffset.width + panelDrag.width,
                y: layout.panelOffset.height + panelDrag.height
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func perch(_ layout: Layout, size: CGSize) -> some View {
        if layout.palFits {
            StudyPalPerch(
                center: layout.palCenter,
                size: layout.pal,
                mood: mood,
                cue: cue,
                onTap: tapPal,
                onDrop: { point, velocity in sitDown(at: point, velocity: velocity, in: size) }
            )
            .animation(.spring(duration: 0.6, bounce: 0.2), value: layout.palCenter)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    /// The voice-message button, just past her wing tip (Voice mode).
    @ViewBuilder
    private func mic(_ layout: Layout) -> some View {
        if layout.palFits, layout.hasMic {
            PalMicButton(style: .floating)
                .position(layout.micCenter)
                .animation(.spring(duration: 0.6, bounce: 0.2), value: layout.micCenter)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    /// Voice or Chat, beside her (under the mic in Voice mode).
    @ViewBuilder
    private func modeSwitch(_ layout: Layout) -> some View {
        if layout.palFits {
            PalModeSwitch(isVoice: Binding(get: { pal.isVoiceMode }, set: { pal.isVoiceMode = $0 }))
                .position(layout.switchCenter)
                .animation(.spring(duration: 0.6, bounce: 0.2), value: layout.switchCenter)
                .transition(.opacity)
        }
    }

    /// A soft glow behind her while she listens, swelling with your voice.
    @ViewBuilder
    private func listeningGlow(_ layout: Layout) -> some View {
        if layout.palFits, pal.listener.isListening || pal.wake.state == .capturing {
            let level = CGFloat(pal.listener.level)
            Ellipse()
                .fill(Color.green.opacity(0.22 + Double(level) * 0.25))
                .frame(width: layout.pal.width * 0.62 * (1 + level * 0.35), height: layout.pal.height * 0.62 * (1 + level * 0.35))
                .blur(radius: 22)
                .position(layout.palCenter)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: level)
                .transition(.opacity)
        }
    }

    /// What she's doing or saying, over her head, while her card is closed.
    private var bubbleText: String? {
        guard !pal.isPaletteOpen, !isNaming else { return nil }
        if let problem = pal.listener.problem ?? pal.speaker.problem { return problem }
        if pal.wake.state == .capturing {
            return pal.wake.command.isEmpty ? "I'm listening…" : pal.wake.command
        }
        if pal.listener.isListening {
            let heard = pal.listener.transcript
            return heard.isEmpty ? "I'm listening…" : heard
        }
        if let error = brain.errorText { return error }
        let reply = brain.messages.last { $0.role == .pal }?.text ?? ""
        if brain.isWorking {
            if let status = brain.status { return status }
            return reply.isEmpty ? "Hmm…" : MarkdownText.plainText(reply)
        }
        if pal.speaker.isTalking || lingers, !reply.isEmpty {
            return MarkdownText.plainText(reply)
        }
        return nil
    }

    /// The bubble grows with what's in it (all of what you're saying, or
    /// her whole reply), from just over her head upward (or below her, near
    /// the top of the window). Too long for the room there, it scrolls,
    /// keeping the newest words in view.
    @ViewBuilder
    private func bubble(_ layout: Layout) -> some View {
        if layout.palFits, let bubbleText {
            let room = layout.bubbleRoom
            PalBubble(text: bubbleText, maxHeight: room) {
                if pal.listener.problem != nil { pal.cancelRecording() }
                pal.openPalette()
            }
            .frame(width: Layout.bubbleWidth, height: room, alignment: layout.bubbleAbove ? .bottom : .top)
            .position(x: layout.bubbleAnchor.x, y: layout.bubbleAbove ? layout.bubbleAnchor.y - room / 2 : layout.bubbleAnchor.y + room / 2)
            .transition(.scale(scale: 0.9, anchor: layout.bubbleAbove ? .bottom : .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func choices(in size: CGSize) -> some View {
        if let choice = brain.pendingChoice {
            AskChoiceCard(
                choice: choice,
                width: min(480, size.width - 32),
                onPick: { brain.choose($0) },
                onDismiss: { brain.dismissChoice() }
            )
            .position(x: size.width / 2, y: size.height * 0.4)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    /// The first time you tap her: what would you like to call her?
    @ViewBuilder
    private func nameCard(in size: CGSize) -> some View {
        if isNaming {
            AskNameCard(
                width: min(420, size.width - 32),
                onName: { name in
                    palName = name
                    isNaming = false
                    play(.delight)
                    pal.openPalette()
                },
                onLater: {
                    nameAsked = true
                    isNaming = false
                    play(.nod)
                    pal.openPalette()
                }
            )
            .position(x: size.width / 2, y: size.height * 0.3)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    // MARK: State

    private var mood: StudyPalMood {
        if pal.speaker.isTalking { return .talking }
        guard brain.isWorking, brain.pendingChoice == nil else { return .idle }
        // A reply she'll say out loud: she thinks until her voice starts.
        let willSpeak = pal.isVoiceMode && pal.speaker.isAvailable
        return brain.isAnswering && !willSpeak ? .talking : .thinking
    }

    private func tapPal() {
        guard pal.hasKey else {
            showsSettings = true
            return
        }
        if palName.trimmingCharacters(in: .whitespaces).isEmpty, !nameAsked, !pal.isPaletteOpen {
            if !isNaming { play(.wave) }
            isNaming = true
            return
        }
        isNaming = false
        if pal.speaker.isTalking {
            pal.hush()
            play(.poke)
        } else if pal.isPaletteOpen {
            pal.closePalette()
            play(.nod)
        } else if pal.isVoiceMode {
            pal.openPalette()
            play(.wave)
        } else {
            // Chat mode: her card opens, ready to type.
            pal.startTyping()
            play(.listen)
        }
    }

    private func play(_ reaction: StudyPalReaction) {
        cue = cue.next(reaction)
    }

    private func linger() {
        lingerTask?.cancel()
        lingers = true
        lingerTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            lingers = false
        }
    }

    /// She settles where you let go, kept in the window. A flick carries
    /// her a little further the way it went.
    private func sitDown(at point: CGPoint, velocity: CGSize, in size: CGSize) {
        let x = point.x + velocity.width * 0.1
        let y = point.y + velocity.height * 0.1
        seatX = Double(min(max(x / max(size.width, 1), 0), 1))
        seatY = Double(min(max(y / max(size.height, 1), 0), 1))
    }

    /// Her card stays where you drop it, kept on screen with its top in reach.
    private func movePanel(by translation: CGSize, in size: CGSize, safeTop: CGFloat) {
        let offset = Layout.clampPanel(
            CGSize(width: panelX + translation.width, height: panelY + translation.height),
            in: size,
            top: safeTop
        )
        panelX = offset.width
        panelY = offset.height
        panelDrag = .zero
    }

    // MARK: Layout

    /// Where everything goes.
    /// - She sits at her spot, kept on screen and above the keyboard.
    /// - Her card is where you put it (at first, the top right, below the
    ///   toolbar). If she's under it, she moves just clear of it.
    /// - The mic is past her wing tip (in Voice mode), the Voice/Chat switch
    ///   under it (or in its place), and the bubble over her head.
    fileprivate struct Layout {
        var pal: CGSize
        var palCenter: CGPoint
        var palFits: Bool
        var hasMic: Bool
        var micCenter: CGPoint
        var switchCenter: CGPoint
        /// Where the bubble starts: the middle of its bottom edge, just over
        /// her head (or of its top edge, just under her).
        var bubbleAnchor: CGPoint
        var bubbleAbove: Bool
        /// How tall the bubble can grow there.
        var bubbleRoom: CGFloat

        static let bubbleWidth: CGFloat = 360
        /// How far the card is from the top-right corner, kept on screen.
        var panelOffset: CGSize
        /// Where the card's top is when it hasn't been moved: below the toolbar.
        var panelTop: CGFloat

        static let panelWidth: CGFloat = 380

        /// Keeps a moved card on screen: all of it across, and its top
        /// (where you drag it) within reach.
        static func clampPanel(_ offset: CGSize, in size: CGSize, top: CGFloat) -> CGSize {
            let leftmost = min(0, -(size.width - 24 - panelWidth))
            let lowest = max(0, size.height - top - 160)
            return CGSize(
                width: min(max(offset.width, leftmost), 0),
                height: min(max(offset.height, -top + 8), lowest)
            )
        }

        init(size: CGSize, safeTop: CGFloat, bottomInset: CGFloat, isPaletteOpen: Bool, hasMic: Bool, seat share: CGPoint, panelOffset: CGSize) {
            self.hasMic = hasMic
            let roomy = size.width >= 760
            let pal = roomy ? CGSize(width: 260, height: 186) : CGSize(width: 190, height: 136)
            self.pal = pal
            palFits = size.width >= pal.width + 24 && size.height >= pal.height + 48
            // Below the navigation bar.
            panelTop = safeTop + 56
            self.panelOffset = Self.clampPanel(panelOffset, in: size, top: panelTop)
            // Her frame leaves room for her wings to flap, so it can hang a
            // little past the edge of the window.
            let hang = pal.width * 0.05
            let bottom = size.height - bottomInset
            let seat = CGPoint(
                x: min(max(share.x * size.width, pal.width / 2 - hang), size.width - pal.width / 2 + hang),
                y: min(max(share.y * size.height, pal.height / 2 + safeTop + 4), max(pal.height / 2 + 4, bottom - pal.height / 2 - 4))
            )
            let overlap: CGFloat = roomy ? 36 : 26
            // From her middle to her tucked-in wing tip.
            let reach = pal.width / 2 - overlap

            var center = seat
            if isPaletteOpen {
                let panel = CGRect(
                    x: size.width - 12 - Self.panelWidth + self.panelOffset.width,
                    y: panelTop + self.panelOffset.height,
                    width: Self.panelWidth,
                    height: size.height
                )
                let body = CGRect(x: seat.x - reach, y: seat.y - pal.height * 0.3, width: reach * 2, height: pal.height * 0.6)
                if body.intersects(panel) {
                    // Just clear of it, on whichever side has room.
                    let left = panel.minX - reach
                    let right = panel.maxX + reach
                    let x = left - reach >= -hang ? left : right
                    center = CGPoint(x: min(max(x, pal.width / 2 - hang), size.width - pal.width / 2 + hang), y: seat.y)
                }
            }
            palCenter = center

            let side = pal.width * 0.42 + 30
            let micX = center.x + side + 30 < size.width ? center.x + side : center.x - side
            micCenter = CGPoint(x: micX, y: center.y + pal.height * 0.1)
            // The switch (two 34-point buttons, stacked) goes under the mic,
            // or over it when there's no room below; without the mic, in its place.
            if hasMic {
                let below = micCenter.y + 27 + 10 + 41
                switchCenter = CGPoint(x: micX, y: below + 41 < bottom ? below : micCenter.y - 27 - 10 - 41)
            } else {
                switchCenter = micCenter
            }

            let overHead = center.y - pal.height * 0.42
            let underFeet = center.y + pal.height * 0.42
            let roomAbove = overHead - (safeTop + 8)
            let roomBelow = bottom - underFeet - 8
            bubbleAbove = roomAbove >= 140 || roomAbove >= roomBelow
            bubbleAnchor = CGPoint(
                x: min(max(center.x, Self.bubbleWidth / 2 + 12), size.width - Self.bubbleWidth / 2 - 12),
                y: bubbleAbove ? overHead : underFeet
            )
            bubbleRoom = max(bubbleAbove ? roomAbove : roomBelow, 60)
        }
    }
}

/// Voice or Chat, beside the study pal. Voice: she talks back, the mic is
/// beside her, and she listens for her name. Chat: she only writes.
private struct PalModeSwitch: View {
    @Binding var isVoice: Bool

    var body: some View {
        VStack(spacing: 2) {
            option(voice: true, symbol: "waveform", label: "Voice")
            option(voice: false, symbol: "text.bubble.fill", label: "Chat")
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    private func option(voice: Bool, symbol: String, label: String) -> some View {
        let isOn = isVoice == voice
        return Button {
            withAnimation(.snappy) { isVoice = voice }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .frame(width: 34, height: 34)
                .background(isOn ? Color.accentColor : Color.clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) Mode")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// What she's hearing, doing or saying, in a glass bubble that's as tall
/// as its words, up to `maxHeight`; past that it scrolls, with the newest
/// words in view.
private struct PalBubble: View {
    let text: String
    let maxHeight: CGFloat
    let onTap: () -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            words
            ScrollView {
                words
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
        .frame(maxHeight: maxHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .contentShape(.rect(cornerRadius: 18))
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
    }

    private var words: some View {
        Text(text)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Finds the window a view is in.
private struct WindowReader: UIViewRepresentable {
    let onWindow: (UIWindow) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: UIView {
        var onWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            // After this layout pass, which may be part of a SwiftUI update.
            Task { @MainActor [weak self] in
                guard self?.window === window else { return }
                self?.onWindow?(window)
            }
        }
    }
}
