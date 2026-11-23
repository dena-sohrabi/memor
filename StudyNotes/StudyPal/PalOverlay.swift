import SwiftUI

/// The study pal on top of a window: the library, a notebook or a PDF.
/// Every window has one of these, but she only shows in the window you
/// used last, so there's always exactly one of her. Use another window and
/// she's there instead.
///
/// - The switch beside her picks Voice or Chat.
/// - Voice: no words on screen, except what she's doing while she uses a
///   tool ("Creating an image…"), in a line over her head with no
///   background. Tap her (or the mic beside her) and talk, then tap again
///   to send. She answers out loud, and before something slow she may say
///   what she's doing. Tap her while she talks to hush her. If something
///   goes wrong, a small "!" shows over her head; tap it to read what.
/// - Chat: a compose box sits beside her, and tapping her puts the cursor
///   in it. Send, and her chat card opens with your talk; tap her to close
///   it. While the card is closed, a small bubble over her head shows what
///   she's saying, and the same line as Voice mode what she's doing.
/// - The first time you tap her, she asks for a name.
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

    /// Her chat card is showing: Chat mode only.
    private var showsCard: Bool { pal.isPaletteOpen && !pal.isVoiceMode }

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
                isVoice: pal.isVoiceMode,
                isPaletteOpen: showsCard,
                hasKey: pal.hasKey,
                seat: CGPoint(x: seatX, y: seatY),
                panelOffset: CGSize(width: panelX, height: panelY)
            )
            ZStack(alignment: .topLeading) {
                if isOut {
                    palette(layout, size: proxy.size)
                    listeningGlow(layout)
                    perch(layout, size: proxy.size)
                    mic(layout)
                    compose(layout)
                    modeSwitch(layout)
                    bubble(layout)
                    statusLine(layout, size: proxy.size)
                    problemButton(layout)
                    choices(in: proxy.size)
                    nameCard(in: proxy.size)
                }
            }
            .coordinateSpace(.named(StudyPalPerch.space))
            .animation(.spring(duration: 0.35, bounce: 0.2), value: brain.pendingChoice?.id)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: showsCard)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: isNaming)
            .animation(.easeInOut(duration: 0.25), value: bubbleText)
            .animation(.easeInOut(duration: 0.25), value: brain.status)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: voiceProblem?.text)
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
        if showsCard {
            PalPalette(
                maxHeight: min(size.height - layout.panelTop - 16 - layout.panelOffset.height, Layout.panelMaxHeight(in: size)),
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
            PalMicButton(style: .floating(cancelBelow: layout.switchAboveMic))
                .position(layout.micCenter)
                .animation(.spring(duration: 0.6, bounce: 0.2), value: layout.micCenter)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    /// Chat mode: the box to write to her, beside her, while her card is
    /// closed. It grows a line at a time, away from its fixed edge.
    @ViewBuilder
    private func compose(_ layout: Layout) -> some View {
        if layout.palFits, !pal.isVoiceMode, !showsCard {
            let room = Layout.composeRoom
            PalComposeBar(width: layout.composeWidth, onNeedsKey: { showsSettings = true })
                .frame(width: layout.composeWidth, height: room, alignment: layout.composeGrowsUp ? .bottom : .top)
                .position(
                    x: layout.composeEdge.x,
                    y: layout.composeGrowsUp ? layout.composeEdge.y - room / 2 : layout.composeEdge.y + room / 2
                )
                .animation(.spring(duration: 0.6, bounce: 0.2), value: layout.composeEdge)
                .transition(.scale(scale: 0.9, anchor: layout.composeAnchor).combined(with: .opacity))
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

    /// Chat mode: what she's hearing or saying, over her head, while her
    /// card is closed. Voice mode never shows words. What she's doing with
    /// a tool is the status line instead.
    private var bubbleText: String? {
        guard !pal.isVoiceMode, !showsCard, !isNaming else { return nil }
        if let problem = pal.listener.problem ?? pal.speaker.problem { return problem }
        if pal.listener.isListening {
            let heard = pal.listener.transcript
            return heard.isEmpty ? "I'm listening…" : heard
        }
        if let error = brain.errorText { return error }
        let reply = brain.messages.last { $0.role == .pal }?.text ?? ""
        if brain.isWorking {
            if brain.status != nil { return nil }
            return reply.isEmpty ? "Hmm…" : MarkdownText.plainText(reply)
        }
        if lingers, !reply.isEmpty {
            return MarkdownText.plainText(reply)
        }
        return nil
    }

    /// The bubble grows with what's in it, from just over her head upward
    /// (or below her, near the top of the window), up to a few lines; past
    /// that it scrolls, keeping the newest words in view. Tap it for her card.
    @ViewBuilder
    private func bubble(_ layout: Layout) -> some View {
        if layout.palFits, let bubbleText {
            let room = min(layout.bubbleRoom, Layout.bubbleMaxHeight)
            PalBubble(text: bubbleText, maxHeight: room) {
                if pal.listener.problem != nil { pal.cancelRecording() }
                pal.openPalette()
            }
            .frame(width: Layout.bubbleWidth, height: room, alignment: layout.bubbleAbove ? .bottom : .top)
            .position(x: layout.bubbleAnchor.x, y: layout.bubbleAbove ? layout.bubbleAnchor.y - room / 2 : layout.bubbleAnchor.y + room / 2)
            .transition(.scale(scale: 0.9, anchor: layout.bubbleAbove ? .bottom : .top).combined(with: .opacity))
        }
    }

    /// What she's doing with a tool, over her head, in both modes (her card
    /// shows its own): one line with no background, like the step updates
    /// in AI chat apps. Each step fades into the next.
    @ViewBuilder
    private func statusLine(_ layout: Layout, size: CGSize) -> some View {
        if layout.palFits, brain.isWorking, let activity = brain.status, !showsCard, !isNaming {
            let width = min(Layout.statusWidth, size.width - 24)
            // Over the "!" when that's showing too.
            let lift: CGFloat = voiceProblem != nil ? 44 : 0
            PalStatusLine(activity: activity)
                .frame(width: width)
                .position(
                    x: min(max(layout.palCenter.x, width / 2 + 12), size.width - width / 2 - 12),
                    y: layout.bubbleAbove ? layout.bubbleAnchor.y - 14 - lift : layout.bubbleAnchor.y + 14 + lift
                )
                .allowsHitTesting(false)
                .id(activity)
                .transition(.opacity.combined(with: .offset(y: 4)))
        }
    }

    /// Something that went wrong, for Voice mode, where no words show.
    private struct Problem {
        let text: String
        var actionTitle: String?
        var action: (() -> Void)?
    }

    private var voiceProblem: Problem? {
        guard pal.isVoiceMode, !isNaming else { return nil }
        if let text = pal.listener.problem ?? pal.speaker.problem {
            return Problem(text: text)
        }
        if let error = brain.errorText {
            return brain.canRetry ? Problem(text: error, actionTitle: "Try Again", action: { pal.retry() }) : Problem(text: error)
        }
        if pal.hasKey, !pal.speaker.isAvailable {
            // Otherwise she'd answer in silence, with nothing to read.
            return Problem(
                text: "I can't talk out loud: my voice needs an OpenAI key, and it has to be turned on in Settings. Switch to Chat to read my answers.",
                actionTitle: "Open Settings",
                action: { showsSettings = true }
            )
        }
        return nil
    }

    /// Voice mode: a small "!" over her head when something went wrong.
    /// Tap it to read what.
    @ViewBuilder
    private func problemButton(_ layout: Layout) -> some View {
        if layout.palFits, let problem = voiceProblem {
            PalProblemButton(
                text: problem.text,
                actionTitle: problem.actionTitle,
                action: problem.action,
                onDismiss: {
                    // A microphone problem goes once it's been read.
                    if pal.listener.problem != nil { pal.cancelRecording() }
                }
            )
            .position(layout.problemCenter)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
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
                    if !pal.isVoiceMode { pal.startTyping() }
                },
                onLater: {
                    nameAsked = true
                    isNaming = false
                    play(.nod)
                    if !pal.isVoiceMode { pal.startTyping() }
                }
            )
            .position(x: size.width / 2, y: size.height * 0.3)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    // MARK: State

    private var mood: StudyPalMood {
        if pal.speaker.isTalking { return .talking }
        // What you said is still being turned into text: she's on it.
        if pal.listener.isTranscribing || pal.wake.isTranscribing { return .thinking }
        guard brain.isWorking, brain.pendingChoice == nil else { return .idle }
        // A reply she'll say out loud: she thinks until her voice starts.
        let willSpeak = pal.isVoiceMode && pal.speaker.isAvailable
        return brain.isAnswering && !willSpeak ? .talking : .thinking
    }

    /// - While she talks: hushes her.
    /// - Voice mode: starts a voice message, or, while she's listening,
    ///   sends it.
    /// - Chat mode: closes her card if it's open; otherwise puts the cursor
    ///   in the compose box beside her.
    private func tapPal() {
        guard pal.hasKey else {
            showsSettings = true
            return
        }
        if palName.trimmingCharacters(in: .whitespaces).isEmpty, !nameAsked, !showsCard {
            if !isNaming { play(.wave) }
            isNaming = true
            return
        }
        isNaming = false
        if pal.speaker.isTalking {
            pal.hush()
            play(.poke)
        } else if pal.isVoiceMode {
            if pal.listener.isListening {
                pal.finishRecording()
            } else {
                pal.startRecording()
            }
        } else if pal.isPaletteOpen {
            pal.closePalette()
            play(.nod)
        } else {
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
    /// - Her card (Chat mode) is where you put it (at first, the top right,
    ///   below the toolbar), no taller than about half the window. If she's
    ///   under it, she moves just clear of it.
    /// - Past her wing tip: in Voice mode the mic, with the Voice/Chat
    ///   switch under it; in Chat mode the switch, with the compose box
    ///   beyond it (in a narrow window, the compose box goes under her, or
    ///   over her head).
    /// - Over her head: the bubble (Chat mode) or the "!" (Voice mode), and
    ///   the status line while she uses a tool.
    fileprivate struct Layout {
        var pal: CGSize
        var palCenter: CGPoint
        var palFits: Bool
        var hasMic: Bool
        var micCenter: CGPoint
        var switchCenter: CGPoint
        /// No room under the mic, so the switch is over it.
        var switchAboveMic = false
        var composeWidth: CGFloat
        /// The middle of the compose box's fixed edge: its bottom when it
        /// grows upward, its top when it grows downward.
        var composeEdge: CGPoint
        var composeGrowsUp: Bool
        /// Where it grows out from, nearest her.
        var composeAnchor: UnitPoint
        var problemCenter: CGPoint
        /// Where the bubble starts: the middle of its bottom edge, just over
        /// her head (or of its top edge, just under her).
        var bubbleAnchor: CGPoint
        var bubbleAbove: Bool
        /// How tall the bubble can grow there.
        var bubbleRoom: CGFloat
        /// How far the card is from the top-right corner, kept on screen.
        var panelOffset: CGSize
        /// Where the card's top is when it hasn't been moved: below the toolbar.
        var panelTop: CGFloat

        static let bubbleWidth: CGFloat = 360
        /// Room for the longest status line.
        static let statusWidth: CGFloat = 320
        /// About six lines.
        static let bubbleMaxHeight: CGFloat = 150
        static let panelWidth: CGFloat = 380
        static let composeMaxWidth: CGFloat = 420
        /// The compose box with one line.
        static let composeHeight: CGFloat = 46
        /// Room for it to grow to four lines.
        static let composeRoom: CGFloat = 130

        /// Her card is never taller than about half the window.
        static func panelMaxHeight(in size: CGSize) -> CGFloat {
            max(420, size.height * 0.5)
        }

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

        init(size: CGSize, safeTop: CGFloat, bottomInset: CGFloat, isVoice: Bool, isPaletteOpen: Bool, hasKey: Bool, seat share: CGPoint, panelOffset: CGSize) {
            hasMic = isVoice && hasKey
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
                    height: Self.panelMaxHeight(in: size)
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
            // which is as wide as it, or over it when there's no room below;
            // without the mic, in its place.
            if hasMic {
                let micRadius = PalMicButton.floatingSize / 2
                let below = micCenter.y + micRadius + 10 + 41
                switchAboveMic = below + 41 >= bottom
                switchCenter = CGPoint(x: micX, y: switchAboveMic ? micCenter.y - micRadius - 10 - 41 : below)
            } else {
                switchCenter = micCenter
            }

            let overHead = center.y - pal.height * 0.42
            let underFeet = center.y + pal.height * 0.42

            // Chat mode's compose box: past the switch, on the same side.
            let onRight = micX > center.x
            let inner = onRight ? micX + 21 + 10 : micX - 21 - 10
            let besideRoom = onRight ? size.width - 12 - inner : inner - 12
            var composeOverHead = false
            var composeUnderFeet = false
            if besideRoom >= 240 {
                composeWidth = min(Self.composeMaxWidth, besideRoom)
                composeEdge = CGPoint(
                    x: onRight ? inner + composeWidth / 2 : inner - composeWidth / 2,
                    y: min(micCenter.y + Self.composeHeight / 2, bottom - 8)
                )
                composeGrowsUp = true
                composeAnchor = onRight ? .leading : .trailing
            } else {
                // A narrow window: under her, or over her head when there's
                // no room below.
                composeWidth = min(Self.composeMaxWidth, size.width - 24)
                let x = min(max(center.x, composeWidth / 2 + 12), size.width - composeWidth / 2 - 12)
                if bottom - underFeet >= Self.composeHeight + 16 {
                    composeEdge = CGPoint(x: x, y: underFeet + 8)
                    composeGrowsUp = false
                    composeAnchor = .top
                    composeUnderFeet = !isVoice
                } else {
                    composeEdge = CGPoint(x: x, y: overHead - 8)
                    composeGrowsUp = true
                    composeAnchor = .bottom
                    composeOverHead = !isVoice
                }
            }

            // Over her head, past the compose box if it's there.
            let top = composeOverHead ? overHead - Self.composeHeight - 16 : overHead
            let foot = composeUnderFeet ? underFeet + Self.composeHeight + 16 : underFeet
            let roomAbove = top - (safeTop + 8)
            let roomBelow = bottom - foot - 8
            bubbleAbove = roomAbove >= 140 || roomAbove >= roomBelow
            bubbleAnchor = CGPoint(
                x: min(max(center.x, Self.bubbleWidth / 2 + 12), size.width - Self.bubbleWidth / 2 - 12),
                y: bubbleAbove ? top : foot
            )
            bubbleRoom = max(bubbleAbove ? roomAbove : roomBelow, 60)
            problemCenter = CGPoint(x: center.x, y: roomAbove >= 40 ? overHead - 4 : underFeet + 4)
        }
    }
}

/// Voice or Chat, beside the study pal. Voice: she talks back, the mic is
/// beside her, and she listens for her name. Chat: she only writes, and a
/// compose box sits beside her.
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

/// Voice mode's only sign that something went wrong: a small "!" over her
/// head. Tap it to read what happened in a popover, with a button to fix
/// it when there is one.
private struct PalProblemButton: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?
    /// The popover closed.
    let onDismiss: () -> Void

    @State private var isShowing = false

    var body: some View {
        Button { isShowing = true } label: {
            Image(systemName: "exclamationmark")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Something Went Wrong")
        .accessibilityValue(text)
        .popover(isPresented: $isShowing) {
            VStack(alignment: .leading, spacing: 14) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle) {
                        isShowing = false
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 320, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
        .onChange(of: isShowing) { _, showing in
            if !showing { onDismiss() }
        }
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
