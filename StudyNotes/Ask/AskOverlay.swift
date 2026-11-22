import SwiftUI

/// A call with the study pal: what you both said, to remember afterwards.
struct PalCall {
    let id = UUID()
    var lines: [PalLine] = []
}

/// A part of the page circled in voice mode, for the study pal to talk about.
struct VoiceQuestion: Equatable {
    let id = UUID()
    let text: String
    /// The circled part, as JPEG.
    let image: Data?
}

/// Ask Claude and the study pal on top of a page.
///
/// A switch beside her picks how you talk with her (when she has a voice:
/// an OpenAI key, and Voice Conversations on in Settings):
/// - Voice: like a call. Tap her, a soft pip, and she listens; when you
///   pause, she hums while she thinks and answers out loud, then listens
///   again. OpenAI's realtime model is the one talking with you: it gets
///   your words as text and a picture of your page, and works on the page
///   with her tools (notes, pictures, options to pick from). Tap her while
///   she talks to cut in; stay quiet, tap her before you speak, or tap the
///   red button to hang up. A pill under her says whose turn it is.
/// - Chat: as before, for when you can't talk out loud. Tap her and the
///   compose box opens; Claude answers in the chat panel, which you can
///   drag by its top.
/// A saved chat reopened from its marker always opens in the panel.
///
/// She's the same pal in both: the name you gave her (the first time you
/// tap her, she asks for one), her nature, and what she remembers about
/// you. When a call or a chat ends, what's worth keeping is written into
/// her memory (`PalMemoryWriter`), so the next talk picks up from it.
///
/// She moves on her own only to keep clear of the panel and the keyboard.
/// Rub her to scratch her, and carry her anywhere; she keeps her spot.
struct AskOverlay: View {
    /// A chat with Claude, in the panel.
    let session: AskSession?
    /// The Ask tool is on. With no chat open, the compose box shows.
    let isAskMode: Bool
    /// Whether she's out: only once there's a page for her to sit on.
    var showsPal = true
    /// Something circled in voice mode: she talks about it.
    var voiceQuestion: VoiceQuestion?
    /// What she can do on the page, for voice mode.
    let pageActions: () -> AskPageActions?
    /// A picture of the page and its typed text, for voice mode.
    let pageContext: () -> PageContext?
    /// Opens the compose box (or Settings, without an API key).
    let onSummon: () -> Void
    /// Sends a question from the compose box to Claude (chat mode).
    let onSend: (String) -> Void
    let onCancelCompose: () -> Void
    let onClose: () -> Void

    @State private var palCue = StudyPalCue()
    @State private var listener = StudyPalListener()
    @State private var speaker = StudyPalSpeaker()
    @State private var toolbox = StudyPalToolbox()
    /// You're on a call with her: she listens again after each answer.
    @State private var isInCall = false
    /// The call so far, to remember once it's over (and to carry on from
    /// if her connection drops in the middle).
    @State private var call: PalCall?
    /// Which version of the page she last saw on this call.
    @State private var sentPageVersion: Int?
    /// Hangs up a call left quiet for a while.
    @State private var hangUpTask: Task<Void, Never>?
    /// The chat in the panel, to remember once it closes.
    @State private var watchedSession: AskSession?
    @AppStorage(StudyPalCharacter.nameKey) private var palName = ""
    /// You chose Not Now when she asked for a name.
    @AppStorage("studyPal.nameAsked") private var nameAsked = false
    @State private var isNaming = false
    @AppStorage(StudyPalSpeaker.modeKey) private var palMode = "voice"
    /// Her spot, as a share of the page's width and height.
    @AppStorage("studyPal.x") private var seatX = 0.88
    @AppStorage("studyPal.y") private var seatY = 0.8
    /// How far you moved the chat panel from the top-right corner.
    @AppStorage("askPanel.x") private var panelX = 0.0
    @AppStorage("askPanel.y") private var panelY = 0.0
    @State private var panelDrag = CGSize.zero

    fileprivate enum Mode: Equatable {
        case resting, composing, chatting
    }

    private var mode: Mode {
        if session != nil { return .chatting }
        return isAskMode ? .composing : .resting
    }

    /// She has a voice and the switch is on Voice.
    private var isVoiceMode: Bool { speaker.isAvailable && palMode == "voice" }

    private var voiceBinding: Binding<Bool> {
        Binding(get: { palMode == "voice" }, set: { palMode = $0 ? "voice" : "chat" })
    }

    var body: some View {
        reactingToTalk(reactingToChat(stage))
    }

    private var stage: some View {
        GeometryReader { proxy in
            let layout = Layout(
                size: proxy.size,
                bottomInset: proxy.safeAreaInsets.bottom,
                mode: mode,
                seat: CGPoint(x: seatX, y: seatY),
                panelOffset: CGSize(width: panelX, height: panelY)
            )
            ZStack(alignment: .topLeading) {
                askSurface(layout, size: proxy.size)
                listeningGlow(layout)
                pal(layout, in: proxy.size)
                modeSwitch(layout)
                callPill(layout)
                notice(layout)
                choices(in: proxy.size)
                nameCard(in: proxy.size)
            }
            .coordinateSpace(.named(StudyPalPerch.space))
            .animation(.spring(duration: 0.35, bounce: 0.2), value: pendingChoice?.id)
            .animation(.easeInOut(duration: 0.25), value: noticeText)
            .animation(.spring(duration: 0.3, bounce: 0.2), value: callPhase)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: isNaming)
        }
    }

    // MARK: Pieces

    /// The chat panel or the compose box, when they're showing.
    @ViewBuilder
    private func askSurface(_ layout: Layout, size: CGSize) -> some View {
        if let session, mode == .chatting {
            AskPanel(
                session: session,
                maxHeight: size.height - 24 - layout.panelOffset.height,
                listener: listener,
                onListen: startListening,
                onMove: { panelDrag = $0 },
                onMoveEnded: { movePanel(by: $0, in: size) },
                onClose: onClose,
                onStartTyping: { cue(.listen) }
            )
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .offset(
                x: layout.panelOffset.width + panelDrag.width,
                y: layout.panelOffset.height + panelDrag.height
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if mode == .composing {
            AskComposeBar(
                onSend: { text in
                    if isVoiceMode {
                        // Typed, but she still answers out loud.
                        onCancelCompose()
                        talk(text)
                    } else {
                        onSend(text)
                    }
                },
                onCancel: onCancelCompose,
                width: layout.composeWidth,
                listener: listener,
                onListen: startListening,
                onStartTyping: { cue(.listen) }
            )
            .position(layout.composeCenter)
            .transition(.scale(scale: 0.9, anchor: layout.composeAnchor).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func pal(_ layout: Layout, in size: CGSize) -> some View {
        if showsPal, layout.palFits {
            StudyPalPerch(
                center: layout.palCenter,
                size: layout.pal,
                mood: mood,
                cue: palCue,
                onTap: tapPal,
                onDrop: { point, velocity in
                    sitDown(at: point, velocity: velocity, in: size)
                }
            )
            .animation(.spring(duration: 0.6, bounce: 0.2), value: layout.palCenter)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    /// Voice or Chat, beside her, once she has a voice.
    @ViewBuilder
    private func modeSwitch(_ layout: Layout) -> some View {
        if showsPal, layout.palFits, speaker.isAvailable, mode != .chatting {
            AskModeSwitch(isVoice: voiceBinding)
                .position(layout.switchCenter)
                .animation(.spring(duration: 0.6, bounce: 0.2), value: layout.switchCenter)
                .transition(.opacity)
        }
    }

    /// A soft glow behind her while she listens, swelling with your voice,
    /// so it's plain she's hearing you.
    @ViewBuilder
    private func listeningGlow(_ layout: Layout) -> some View {
        if showsPal, layout.palFits, callPhase == .listening {
            let swell = 1 + CGFloat(listener.level) * 0.35
            Ellipse()
                .fill(Color.green.opacity(0.22 + Double(listener.level) * 0.25))
                .frame(width: layout.pal.width * 0.62 * swell, height: layout.pal.height * 0.62 * swell)
                .blur(radius: 22)
                .position(layout.palCenter)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: listener.level)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func callPill(_ layout: Layout) -> some View {
        if showsPal, layout.palFits, let callPhase {
            AskCallPill(phase: callPhase, level: listener.level, isCall: isInCall, onHangUp: hangUp)
                .position(layout.callPillCenter)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    private var pendingChoice: AskSession.Choice? {
        toolbox.pendingChoice ?? session?.pendingChoice
    }

    /// Options to pick from: hers in voice mode, or Claude's in a chat.
    @ViewBuilder
    private func choices(in size: CGSize) -> some View {
        if let choice = pendingChoice {
            AskChoiceCard(
                choice: choice,
                width: min(480, size.width - 32),
                onPick: { option in
                    if toolbox.pendingChoice != nil { toolbox.choose(option) } else { session?.choose(option) }
                },
                onDismiss: {
                    if toolbox.pendingChoice != nil { toolbox.dismissChoice() } else { session?.dismissChoice() }
                }
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
                    cue(.delight)
                },
                onLater: {
                    nameAsked = true
                    isNaming = false
                    cue(.nod)
                }
            )
            .position(x: size.width / 2, y: size.height * 0.3)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    /// Something went wrong with her voice or hearing: a short note over her head.
    private var noticeText: String? {
        guard mode != .chatting else { return nil }
        if isVoiceMode { return speaker.problem ?? listener.problem }
        return mode == .resting ? listener.problem : nil
    }

    @ViewBuilder
    private func notice(_ layout: Layout) -> some View {
        if showsPal, layout.palFits, let noticeText {
            AskNotice(text: noticeText, canRetry: false, onRetry: {}, onDismiss: { listener.cancel() })
                .frame(maxWidth: 320)
                .position(x: layout.noticeCenter.x, y: layout.noticeCenter.y)
                .transition(.opacity)
        }
    }

    // MARK: Call state

    /// Where a voice conversation is, for the pill under her. Nil when
    /// there's no voice going.
    private var callPhase: AskCallPhase? {
        let going = isInCall || speaker.isTalking || speaker.isThinking || toolbox.isBusy
        guard isVoiceMode, going else { return nil }
        if listener.isListening { return .listening }
        if speaker.isTalking { return .talking }
        if toolbox.pendingChoice != nil { return .choosing }
        if speaker.isThinking || toolbox.isBusy { return .thinking }
        return .waiting
    }

    private var mood: StudyPalMood {
        // She moves her mouth while she speaks, and hums while she thinks.
        if speaker.isTalking { return .talking }
        if speaker.isThinking || (toolbox.isBusy && toolbox.pendingChoice == nil) { return .thinking }
        guard let session, session.isWorking, session.pendingChoice == nil else { return .idle }
        return session.isAnswering ? .talking : .thinking
    }

    // MARK: Reactions

    private func reactingToChat(_ content: some View) -> some View {
        content
            .onChange(of: mode) { old, new in
                if old == .resting, new == .composing, !listener.isListening { cue(.wave) }
                // The compose box closed, or a question was sent another way.
                if old == .composing, new != .composing, !isInCall { listener.cancel() }
            }
            .onChange(of: session?.isWorking ?? false) { wasWorking, isWorking in
                guard wasWorking, !isWorking else { return }
                cue(session?.errorText != nil ? .sad : .nod)
            }
            .onChange(of: session?.pageChanges ?? 0) { old, new in
                if new > old { cue(.delight) }
            }
            .onChange(of: toolbox.pageChanges) { old, new in
                if new > old { cue(.delight) }
            }
            .onChange(of: palMode) { _, new in
                // Off to Chat: the call ends.
                if new != "voice" { hangUp() }
            }
            .onChange(of: session?.id) {
                // A chat closed (or another opened): she remembers it.
                rememberChat(watchedSession)
                watchedSession = session
            }
            .onAppear { watchedSession = session }
    }

    private func reactingToTalk(_ content: some View) -> some View {
        content
            .onChange(of: listener.heard) { _, heard in
                if let heard { send(heard.text) }
            }
            .onChange(of: listener.silences) {
                // You said nothing: the call's over.
                if isInCall { endCall() }
            }
            .onChange(of: speaker.pendingCalls) { _, calls in
                runTools(calls)
            }
            .onChange(of: speaker.lastReply) { _, reply in
                if let reply { call?.lines.append(PalLine(isStudent: false, text: reply.text)) }
            }
            .onChange(of: speaker.isTalking) { _, talking in
                guard !talking else { return }
                listenForReply()
                // She answered something circled or typed, outside a call.
                if !isInCall { scheduleHangUp() }
            }
            .onChange(of: speaker.isThinking) { _, thinking in
                if !thinking { listenForReply() }
            }
            .onChange(of: toolbox.pendingChoice?.id) { listenForReply() }
            .onChange(of: voiceQuestion?.id) {
                guard let voiceQuestion, isVoiceMode else { return }
                talk(voiceQuestion.text, image: voiceQuestion.image)
            }
            .onDisappear {
                hangUp()
                rememberChat(watchedSession ?? session)
                watchedSession = nil
            }
    }

    // MARK: Talking with her

    /// Voice mode: tap her to call her, cut in while she talks, send what
    /// you said, or (before you've said anything) hang up. Chat mode: tap
    /// her to open the compose box, ready to type.
    private func tapPal() {
        // The first time: she'd like a name.
        if palName.trimmingCharacters(in: .whitespaces).isEmpty, !nameAsked, mode == .resting, !isInCall {
            if !isNaming { cue(.wave) }
            isNaming = true
            return
        }
        isNaming = false
        hangUpTask?.cancel()
        if isVoiceMode, speaker.isTalking || speaker.isThinking {
            speaker.stop()
            isInCall = true
            startListening()
            return
        }
        if listener.isListening {
            if listener.transcript.isEmpty, isInCall {
                hangUp()
            } else {
                listener.stop()
            }
            return
        }
        if isVoiceMode {
            if toolbox.isBusy, toolbox.pendingChoice == nil {
                cue(.poke)
            } else {
                isInCall = true
                ensureConversation()
                startListening()
            }
            return
        }
        switch mode {
        case .resting:
            // Chat mode: the compose box opens, ready to type. Its mic
            // button is there to talk instead.
            onSummon()
        case .composing, .chatting:
            cue(.poke)
        }
    }

    private func startListening() {
        // Chat mode needs a Claude key; without one, this opens Settings.
        guard isVoiceMode || APIKeyStore.hasKey else {
            onSummon()
            return
        }
        cue(.listen)
        listener.start(patience: isInCall ? .seconds(8) : .seconds(7))
    }

    /// On a call, once she's done talking (or is showing options), she
    /// listens for your reply.
    private func listenForReply() {
        guard isInCall, isVoiceMode, !listener.isListening, !speaker.isTalking, !speaker.isThinking else { return }
        guard speaker.pendingCalls.isEmpty || toolbox.pendingChoice != nil else { return }
        startListening()
    }

    /// The call's over for now: she stops listening. The conversation stays
    /// open a couple of minutes, so tapping her soon carries on from it;
    /// then she hangs up.
    private func endCall() {
        isInCall = false
        if listener.isListening { listener.cancel() }
        scheduleHangUp()
    }

    /// Hangs up in a couple of minutes, unless you talk to her again first.
    private func scheduleHangUp() {
        hangUpTask?.cancel()
        guard call != nil else { return }
        hangUpTask = Task {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, !isInCall else { return }
            hangUp()
        }
    }

    /// Hangs up for good: she goes quiet, remembers the call, and the next
    /// call starts fresh.
    private func hangUp() {
        hangUpTask?.cancel()
        hangUpTask = nil
        speaker.endConversation()
        toolbox.cancel()
        isInCall = false
        listener.cancel()
        if let call {
            PalMemoryWriter.remember(call.lines, talkID: call.id, wasCall: true, with: .openAI)
        }
        call = nil
        sentPageVersion = nil
    }

    /// A chat in the panel closed: she remembers what you talked about.
    private func rememberChat(_ session: AskSession?) {
        guard let session, session.hasNewTurns else { return }
        PalMemoryWriter.remember(session.memoryLines, talkID: session.memoryID, wasCall: false, with: .claude)
        session.markRemembered()
    }

    /// You said something. Voice mode: your pick from the options showing,
    /// or something to her. Chat mode: from the compose box, or a follow-up
    /// in the panel's chat.
    private func send(_ text: String) {
        if isVoiceMode {
            if toolbox.pendingChoice != nil {
                toolbox.answerChoice(saying: text)
            } else if speaker.pendingCalls.isEmpty {
                talk(text)
            }
            return
        }
        switch mode {
        case .composing:
            onSend(text)
        case .chatting:
            if let session, !session.isWorking { session.ask(text) }
        case .resting:
            break
        }
    }

    private func talk(_ text: String, image: Data? = nil) {
        hangUpTask?.cancel()
        if !ensureConversation() { showPageIfChanged() }
        call?.lines.append(PalLine(isStudent: true, text: text))
        speaker.say(text, image: image)
    }

    /// Opens a conversation with her, if there isn't one: who she is, what
    /// she remembers, what's on your page (its picture and typed notes) and
    /// what she can do on it. If her connection dropped in the middle of a
    /// call, she gets what was said so far. Returns whether it opened one.
    @discardableResult
    private func ensureConversation() -> Bool {
        guard !speaker.isConversing else { return false }
        let actions = pageActions()
        toolbox.actions = actions
        sentPageVersion = actions?.askPageVersion
        let context = pageContext()
        if call == nil { call = PalCall() }
        speaker.startConversation(
            instructions: Self.instructions(notes: context?.text ?? "", earlier: call?.lines ?? []),
            tools: toolbox.definitions(),
            pageImage: context?.imageData
        )
        return true
    }

    /// You changed the page since she last saw it: she gets a fresh look
    /// before your next words.
    private func showPageIfChanged() {
        guard let actions = pageActions() else { return }
        toolbox.actions = actions
        let version = actions.askPageVersion
        guard version != sentPageVersion else { return }
        sentPageVersion = version
        guard let context = pageContext() else { return }
        speaker.showPage(image: context.imageData, notes: context.text)
    }

    /// Runs the tools she called, one after another, and hands her the results.
    private func runTools(_ calls: [StudyPalSpeaker.FunctionCall]) {
        guard !calls.isEmpty else { return }
        Task {
            var outputs: [(callID: String, output: String)] = []
            for call in calls {
                let output = await toolbox.run(name: call.name, arguments: call.arguments)
                outputs.append((callID: call.callID, output: output))
            }
            speaker.finishCalls(outputs)
        }
    }

    /// Who she is on a call: her nature, how to talk on a call, her tools,
    /// what she remembers, and the page.
    private static func instructions(notes: String, earlier: [PalLine]) -> String {
        let typed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = [
            StudyPalCharacter.nature,
            """
            You're on a voice call with them now. Their words reach you as text from speech recognition, so allow for small slips. Talk the way you would out loud: short, natural sentences, usually one to three, unless they ask for more. No lists, headings, markdown or symbols; say math in words. Speak the language they use.
            """,
            """
            You know their page: a picture of it comes first, and their typed notes are below. When they change it during the call, you get a fresh picture. Work out what they're studying, tie your answers to what they wrote, use their terms, gently point out mistakes, and help them understand rather than just handing over answers.
            """,
            """
            You can work on their page with your tools: add_note writes a typed note (write it the way their notes are written), draw_picture draws an illustration or diagram, offer_choices shows options on screen when the choice is theirs, and get_page_items, move_item, resize_item, edit_text and delete_item change typed notes and pictures. Their handwriting can't be changed. Only change the page when they ask, and say briefly what you did. Before something slow, like drawing, tell them you're on it.
            """,
            StudyPalCharacter.memoryNote(),
        ]
        if !earlier.isEmpty {
            let name = StudyPalCharacter.name ?? "You"
            let lines = earlier.suffix(30).map { "\($0.isStudent ? "Student" : name): \(String($0.text.prefix(600)))" }
            sections.append("Your connection dropped for a moment during this call. What you'd both said so far; carry on from it without starting over:\n" + lines.joined(separator: "\n"))
        }
        sections.append("Their typed notes on this page:\n" + (typed.isEmpty ? "(none yet)" : String(typed.prefix(6_000))))
        return sections.joined(separator: "\n\n")
    }

    private func cue(_ reaction: StudyPalReaction) {
        palCue = palCue.next(reaction)
    }

    /// She settles where you let go. A flick carries her a little further
    /// the way it went.
    private func sitDown(at point: CGPoint, velocity: CGSize, in size: CGSize) {
        let x = point.x + velocity.width * 0.1
        let y = point.y + velocity.height * 0.1
        seatX = Double(min(max(x / max(size.width, 1), 0), 1))
        seatY = Double(min(max(y / max(size.height, 1), 0), 1))
    }

    /// The panel stays where you drop it, kept on screen with its top in reach.
    private func movePanel(by translation: CGSize, in size: CGSize) {
        let offset = Layout.clampPanel(
            CGSize(width: panelX + translation.width, height: panelY + translation.height),
            in: size
        )
        panelX = offset.width
        panelY = offset.height
        panelDrag = .zero
    }

    /// Where everything goes.
    /// - She sits at her spot, kept on screen and above the keyboard.
    /// - Composing: the compose box opens beside her, on the roomier side.
    ///   If the keyboard pushes it up, she rises with it.
    /// - Chatting: the panel is where you put it (at first, the top right).
    ///   If she's under it, she moves just clear of it.
    /// - The Voice/Chat switch sits beside her, the call pill under her and
    ///   a note over her head.
    fileprivate struct Layout {
        var pal: CGSize
        var palCenter: CGPoint
        var palFits: Bool
        var composeWidth: CGFloat
        var composeCenter: CGPoint
        /// The compose box grows out from her side.
        var composeAnchor: UnitPoint
        /// How far the panel is from the top-right corner, kept on screen.
        var panelOffset: CGSize
        var noticeCenter: CGPoint
        /// The call pill, under her feet (or over her head near the bottom).
        var callPillCenter: CGPoint
        /// The Voice/Chat switch, beside her on the roomier side.
        var switchCenter: CGPoint

        static let panelWidth: CGFloat = 380

        /// Keeps a moved panel on screen: all of it across, and its top
        /// (where you drag it) within reach.
        static func clampPanel(_ offset: CGSize, in size: CGSize) -> CGSize {
            let leftmost = min(0, -(size.width - 24 - panelWidth))
            let lowest = max(0, size.height - 160)
            return CGSize(
                width: min(max(offset.width, leftmost), 0),
                height: min(max(offset.height, 0), lowest)
            )
        }

        init(size: CGSize, bottomInset: CGFloat, mode: Mode, seat share: CGPoint, panelOffset: CGSize) {
            let roomy = size.width >= 760
            let pal = roomy ? CGSize(width: 260, height: 186) : CGSize(width: 190, height: 136)
            self.pal = pal
            palFits = size.width >= pal.width + 24 && size.height >= pal.height + 48
            self.panelOffset = Self.clampPanel(panelOffset, in: size)
            // Her wing tips tuck in beside the compose box and the panel.
            let overlap: CGFloat = roomy ? 36 : 26
            // Her frame leaves room for her wings to flap, so it can hang a
            // little past the edge of the page.
            let hang = pal.width * 0.05
            let bottom = size.height - bottomInset
            let seat = CGPoint(
                x: min(max(share.x * size.width, pal.width / 2 - hang), size.width - pal.width / 2 + hang),
                y: min(max(share.y * size.height, pal.height / 2 + 4), max(pal.height / 2 + 4, bottom - pal.height / 2 - 4))
            )

            // From her middle to her tucked-in wing tip.
            let reach = pal.width / 2 - overlap
            let roomLeft = seat.x - reach - 16
            let roomRight = size.width - seat.x - reach - 16
            let composeHalfHeight: CGFloat = 30
            let composeY = min(max(seat.y, composeHalfHeight + 12), bottom - composeHalfHeight - 12)
            let composesBeside = palFits && max(roomLeft, roomRight) >= 260
            if composesBeside {
                let onLeft = roomLeft >= roomRight
                composeWidth = min(480, onLeft ? roomLeft : roomRight)
                composeCenter = CGPoint(
                    x: onLeft ? seat.x - reach - composeWidth / 2 : seat.x + reach + composeWidth / 2,
                    y: composeY
                )
                composeAnchor = onLeft ? .trailing : .leading
            } else {
                // A narrow window: the compose box alone, at the top.
                composeWidth = min(480, size.width - 32)
                composeCenter = CGPoint(x: size.width / 2, y: 44)
                composeAnchor = .top
            }

            let center: CGPoint
            switch mode {
            case .composing where composesBeside:
                center = CGPoint(x: seat.x, y: composeY)
            case .chatting:
                // The panel, as placed: full height below its top.
                let panel = CGRect(
                    x: size.width - 12 - Self.panelWidth + self.panelOffset.width,
                    y: 12 + self.panelOffset.height,
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
                } else {
                    center = seat
                }
            default:
                center = seat
            }
            palCenter = center

            let above = center.y - pal.height * 0.5 - 30
            noticeCenter = CGPoint(
                x: min(max(center.x, 176), size.width - 176),
                y: above > 50 ? above : center.y + pal.height * 0.5 + 30
            )
            let below = center.y + pal.height * 0.36 + 24
            callPillCenter = CGPoint(
                x: min(max(center.x, 130), size.width - 130),
                y: below + 24 < bottom ? below : center.y - pal.height * 0.42 - 24
            )
            // Just past her wing tip, on whichever side has room.
            let side = pal.width * 0.42 + 24
            let switchX = center.x + side + 22 < size.width ? center.x + side : center.x - side
            switchCenter = CGPoint(x: switchX, y: center.y)
        }
    }
}
