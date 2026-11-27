import SwiftUI

/// The study pal on top of Memor's window, over the library and whatever
/// notebook or PDF is open on top of it. She stays put as you go between
/// them.
///
/// - No buttons beside her: hold her and let go for a small menu that
///   picks Voice or Chat.
/// - Voice: no words on screen, except what she's doing while she uses a
///   tool ("Creating an image…"), in a line over her head with no
///   background. Tap her to talk. With a Live server, that's a call: a
///   soft glow while it's on, just talk, and tap her again to hang up.
///   Without one, it's a voice message: talk, then tap again to send, and
///   she answers out loud (tap her while she talks to hush her). If
///   something goes wrong, a small "!" shows over her head; tap it to read
///   what.
/// - Chat: a compose box sits beside her, and tapping her puts the cursor
///   in it. Send, and her chat card opens with your talk; tap her to close
///   it. While the card is closed, a small bubble over her head shows what
///   she's saying, and the same line as Voice mode what she's doing.
/// - The first time you tap her, she asks for a name.
/// - Rub her to scratch her, and carry her anywhere; she keeps her spot.
struct PalOverlay: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var window: ObjectIdentifier?
    @State private var cue = StudyPalCue()
    @State private var showsSettings = false
    @State private var isNaming = false
    /// Her Voice/Chat menu, from holding her.
    @State private var showsMenu = false
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
                seat: CGPoint(x: seatX, y: seatY),
                panelOffset: CGSize(width: panelX, height: panelY)
            )
            ZStack(alignment: .topLeading) {
                if isOut {
                    palette(layout, size: proxy.size)
                    listeningGlow(layout)
                    menuAnchor(layout)
                    perch(layout, size: proxy.size)
                    compose(layout)
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
        // She picks up, and hangs up.
        .onChange(of: pal.call.isOn) { _, isOn in
            if isHere { play(isOn ? .listen : .nod) }
        }
        // A quiet wave when she's back on screen: no sound.
        .onChange(of: isOut) { _, out in
            if out { play(.wave, silent: true) }
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
                onHold: openMenu,
                onDrop: { point, velocity in sitDown(at: point, velocity: velocity, in: size) },
                accessibilityName: palName.isEmpty ? "Study Pal" : palName,
                accessibilityHint: tapHint
            )
            .animation(.spring(duration: 0.6, bounce: 0.2), value: layout.palCenter)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    /// Where her menu points from: her body. (A popover on her perch would
    /// point at the whole window, since she's placed by position.)
    @ViewBuilder
    private func menuAnchor(_ layout: Layout) -> some View {
        if layout.palFits {
            Color.clear
                .frame(width: layout.pal.width * 0.5, height: layout.pal.height * 0.5)
                .popover(isPresented: $showsMenu) {
                    PalModeMenu(
                        isVoice: pal.isVoiceMode,
                        isRecording: pal.listener.isListening,
                        onPick: { voice in
                            showsMenu = false
                            guard voice != pal.isVoiceMode else { return }
                            withAnimation(.snappy) { pal.isVoiceMode = voice }
                        },
                        onCancelRecording: {
                            showsMenu = false
                            pal.cancelRecording()
                        }
                    )
                }
                // Clear and with no content shape, it doesn't take touches:
                // they go to her (it sits under her).
                .position(layout.palCenter)
        }
    }

    /// For VoiceOver: what tapping her does now.
    private var tapHint: String {
        guard pal.hasKey else { return "Opens Settings to add a key." }
        if !pal.isVoiceMode { return pal.isPaletteOpen ? "Closes the chat." : "Starts typing to her." }
        if pal.call.isOn { return "Hangs up." }
        if pal.listener.isListening { return "Sends your voice message." }
        return pal.hasLiveCalls ? "Calls her." : "Starts a voice message."
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

    /// A soft glow behind her while she listens (a voice message, or the
    /// whole of a call), swelling with your voice.
    @ViewBuilder
    private func listeningGlow(_ layout: Layout) -> some View {
        if layout.palFits, pal.listener.isListening || pal.call.isOn {
            let level = CGFloat(pal.call.isOn ? pal.call.level : pal.listener.level)
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
    /// in AI chat apps. Each step fades into the next. It sits clear of the
    /// compose box beside her (Chat mode), and of the "!".
    @ViewBuilder
    private func statusLine(_ layout: Layout, size: CGSize) -> some View {
        if layout.palFits, brain.isWorking, let activity = brain.status, !showsCard, !isNaming {
            let width = min(Layout.statusWidth, size.width - 24)
            PalStatusLine(activity: activity)
                .frame(width: width)
                .position(
                    x: min(max(layout.palCenter.x, width / 2 + 12), size.width - width / 2 - 12),
                    y: layout.statusY(clearingProblem: voiceProblem != nil)
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
        if let text = pal.call.problem {
            // Only Memor's own Settings › Live Calls can fix it here (the
            // microphone's is the iPad's Settings app).
            let needsSettings = text.contains("Live Calls")
            return Problem(text: text, actionTitle: needsSettings ? "Open Settings" : nil, action: needsSettings ? { showsSettings = true } : nil)
        }
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
                    // A microphone or call problem goes once it's been read.
                    if pal.listener.problem != nil { pal.cancelRecording() }
                    pal.call.clearProblem()
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
        if pal.speaker.isTalking || pal.call.isTalking { return .talking }
        // What you said is still being turned into text: she's on it.
        if pal.listener.isTranscribing { return .thinking }
        guard brain.isWorking, brain.pendingChoice == nil else { return .idle }
        // A reply she'll say out loud: she thinks until her voice starts.
        let willSpeak = pal.isVoiceMode && (pal.call.isOn || pal.speaker.isAvailable)
        return brain.isAnswering && !willSpeak ? .talking : .thinking
    }

    /// - In a call: hangs up.
    /// - While she reads a reply aloud: hushes her.
    /// - Voice mode: calls her, with a Live server; otherwise starts a
    ///   voice message, or, while she's listening, sends it.
    /// - Chat mode: closes her card if it's open; otherwise puts the cursor
    ///   in the compose box beside her.
    private func tapPal() {
        if pal.call.isOn {
            pal.endCall()
            return
        }
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
            } else if pal.hasLiveCalls {
                pal.startCall()
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

    /// You held her and let go: her menu.
    private func openMenu() {
        isNaming = false
        showsMenu = true
    }

    private func play(_ reaction: StudyPalReaction, silent: Bool = false) {
        cue = cue.next(reaction, silent: silent)
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
    /// - Past her wing tip, in Chat mode: the compose box (in a narrow
    ///   window, it goes under her, or over her head). Nothing else sits
    ///   beside her.
    /// - Over her head: the bubble (Chat mode) or the "!" (Voice mode), and
    ///   the status line while she uses a tool.
    fileprivate struct Layout {
        var pal: CGSize
        var palCenter: CGPoint
        var palFits: Bool
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
        /// The top and bottom of the compose box when it's beside her (Chat
        /// mode); infinitely far away otherwise.
        var besideTop: CGFloat
        var besideBottom: CGFloat
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

        init(size: CGSize, safeTop: CGFloat, bottomInset: CGFloat, isVoice: Bool, isPaletteOpen: Bool, seat share: CGPoint, panelOffset: CGSize) {
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

            // Just past her wing tip, on the side with room.
            let side = pal.width * 0.42 + 30
            let besideX = center.x + side + 30 < size.width ? center.x + side : center.x - side
            let besideY = center.y + pal.height * 0.1

            let overHead = center.y - pal.height * 0.42
            let underFeet = center.y + pal.height * 0.42

            // Chat mode's compose box: beside her, from just past her wing tip.
            let onRight = besideX > center.x
            let inner = besideX
            let besideRoom = onRight ? size.width - 12 - inner : inner - 12
            var composeOverHead = false
            var composeUnderFeet = false
            if besideRoom >= 240 {
                composeWidth = min(Self.composeMaxWidth, besideRoom)
                composeEdge = CGPoint(
                    x: onRight ? inner + composeWidth / 2 : inner - composeWidth / 2,
                    y: min(besideY + Self.composeHeight / 2, bottom - 8)
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

            if !isVoice, besideRoom >= 240 {
                besideTop = composeEdge.y - Self.composeHeight
                besideBottom = composeEdge.y
            } else {
                besideTop = .infinity
                besideBottom = -.infinity
            }
        }

        /// The middle of the status line: over her head and over the
        /// compose box beside her (or under her feet and under it), so it
        /// never runs into it, wherever she sits. `clearingProblem`: the
        /// "!" is showing, and the line goes past it too.
        func statusY(clearingProblem: Bool) -> CGFloat {
            // Half the line's height, and a little room.
            let half: CGFloat = 12
            let gap: CGFloat = 6
            if bubbleAbove {
                var y = min(bubbleAnchor.y - 14, besideTop - gap - half)
                if clearingProblem, problemCenter.y < palCenter.y {
                    y = min(y, problemCenter.y - 18 - gap - half)
                }
                return y
            } else {
                var y = max(bubbleAnchor.y + 14, besideBottom + gap + half)
                if clearingProblem, problemCenter.y > palCenter.y {
                    y = max(y, problemCenter.y + 18 + gap + half)
                }
                return y
            }
        }
    }
}

/// Her menu, from holding her: Voice (she talks with you) or Chat (she only
/// writes), and, while you're recording a voice message, a way to drop it.
private struct PalModeMenu: View {
    let isVoice: Bool
    let isRecording: Bool
    let onPick: (_ voice: Bool) -> Void
    let onCancelRecording: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            option(voice: true, symbol: "waveform", title: "Voice", detail: "Talk with her")
            Divider().padding(.leading, 52)
            option(voice: false, symbol: "text.bubble", title: "Chat", detail: "She only writes")
            if isRecording {
                Divider()
                Button(role: .destructive, action: onCancelRecording) {
                    Label("Cancel Voice Message", systemImage: "xmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 250)
        .presentationCompactAdaptation(.popover)
    }

    private func option(voice: Bool, symbol: String, title: String, detail: String) -> some View {
        let isOn = isVoice == voice
        return Button { onPick(voice) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) Mode")
        .accessibilityHint(detail)
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
