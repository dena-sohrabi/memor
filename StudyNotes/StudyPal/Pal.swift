import SwiftUI
import UserNotifications

/// The one study pal in Memor, shared by every window: her mind
/// (`PalBrain`), her ears (`StudyPalListener`), her voice
/// (`StudyPalSpeaker`), live calls with her (`PalCall`), and the state of
/// her chat card.
///
/// - Hold her and let go to pick Voice or Chat.
/// - Voice: tap her to talk. With a Live server set up, that's a live
///   call: just talk, and she answers right away; anything about your
///   pages goes to her mind, and she says its answer. Tap her again to
///   hang up. Without one, it's a voice message: talk, then tap again to
///   send, and she says her reply out loud. Either way no words show on
///   screen, except a short line over her head while she uses a tool
///   ("Creating an image…").
/// - Chat: she only writes. A compose box sits beside her, and her replies
///   show in her chat card.
/// - Circle something on a page and it goes to her right away, or with the
///   voice message you're in the middle of.
/// - She's always there, in the window you're using.
@MainActor
@Observable
final class Pal {
    static let shared = Pal()

    let brain = PalBrain()
    let speaker = StudyPalSpeaker()
    let listener = StudyPalListener()
    let call = PalCall()

    /// Her chat card is open.
    var isPaletteOpen = false
    /// Waiting for you to circle something on a page.
    private(set) var isCircling = false
    /// Something circled, waiting to go with your next message.
    private(set) var attachedCircle: PalCircle?

    nonisolated static let modeKey = "studyPal.mode"

    /// Voice or Chat, from the menu you get by holding her. Voice: you
    /// talk to her by tapping her, she answers out loud, and nothing shows
    /// as text (her card stays closed). Chat: she only writes, for when you
    /// can't talk out loud; a compose box sits beside her, and tapping her
    /// puts the cursor in it.
    var isVoiceMode = (UserDefaults.standard.string(forKey: Pal.modeKey) ?? "voice") != "chat" {
        didSet {
            UserDefaults.standard.set(isVoiceMode ? "voice" : "chat", forKey: Self.modeKey)
            if isVoiceMode {
                // The talk carries on; it just isn't shown.
                isPaletteOpen = false
            } else {
                hush()
                call.end()
            }
        }
    }

    /// Asks the compose box beside her to put the cursor in its field
    /// (Chat mode).
    private(set) var typingRequests = 0

    /// She can think: there's a key for her mind (Claude or GPT).
    private(set) var hasKey = PalMind.current != nil
    /// A Live server is set up: tapping her in Voice mode calls her.
    private(set) var hasLiveCalls = LiveServerStore.isSetUp

    /// A key was added or removed, her mind changed, or the Live server
    /// was set up or removed, in Settings. The next talk uses it.
    func keyChanged() {
        hasKey = PalMind.current != nil
        hasLiveCalls = LiveServerStore.isSetUp
    }

    /// A message, on its way to her.
    private struct Outgoing {
        let text: String
        let spoken: Bool
        let circle: PalCircle?
        /// In a call, the hand-off it answers.
        var delegation: String?
    }

    /// Where the reply being written goes in a call.
    private enum CallReply {
        /// To the hand-off it answers.
        case delegation(String)
        /// Said on its own (a circle, or Try Again, in a call).
        case say
    }

    /// The reply being written is read out loud.
    @ObservationIgnored private var speaksReply = false
    /// The reply being written is said in the call.
    @ObservationIgnored private var callReply: CallReply?
    /// Sent while she was still answering: it goes once she's stopped.
    @ObservationIgnored private var queued: Outgoing?
    /// The message she's answering now.
    @ObservationIgnored private var inFlight: Outgoing?
    @ObservationIgnored private weak var circlingPage: PalPage?

    private init() {
        brain.onReply = { [weak self] text, isComplete in
            guard let self else { return }
            if isComplete { self.inFlight = nil }
            if let reply = self.callReply {
                // In a call, the whole answer goes at once, to be said.
                if isComplete {
                    self.callReply = nil
                    self.finishInCall(text, reply)
                }
            } else if self.speaksReply {
                self.speaker.feed(text, isComplete: isComplete)
                if isComplete { self.speaksReply = false }
            }
            if isComplete, let next = self.queued {
                self.queued = nil
                // Once this answer has wound down.
                Task { self.deliver(next) }
            }
        }
        // What she wrote before using a tool ("Drawing it now.") is said
        // right away, not after the tool, which can take a minute. In a
        // call, the call is told quietly instead: it has already said
        // something while her mind works.
        brain.onPause = { [weak self] text in
            guard let self else { return }
            if case .delegation(let id) = self.callReply {
                self.call.note("Your mind is working on it, and said so far: " + text, for: id)
                return
            }
            guard self.speaksReply else { return }
            self.speaker.feed(text, isComplete: false, isPausing: true)
        }
        listener.onHeard = { [weak self] text in
            self?.send(text, spoken: true)
        }
        // What you're studying goes along when you talk, so its words are
        // heard right.
        listener.context = {
            let pages = PalWorkspace.shared.visiblePages
            let text = pages.map { $0.palVocabularyText() }.joined(separator: "\n")
            var seen = Set<String>()
            let titles = pages.map(\.palItemTitle).filter { seen.insert($0).inserted }
            let name = StudyPalCharacter.name
            return SpeechContext(
                keywords: SpeechVocabulary.hints(from: text, name: name),
                prompt: SpeechVocabulary.prompt(name: name, studying: titles)
            )
        }
        call.context = listener.context
        call.onDelegate = { [weak self] id, request in
            self?.answerInCall(id, request: request)
        }
        call.isMindWorking = { [weak self] in
            self?.brain.isWorking ?? false
        }
        UNUserNotificationCenter.current().delegate = PalNotificationDelegate.shared
    }

    // MARK: Talking

    /// Sends a message to her, with anything circled. If she's in the
    /// middle of an answer, she stops and takes this one instead.
    func send(_ text: String, spoken: Bool = false, delegation: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachedCircle != nil else { return }
        // Answering options she showed isn't a new message.
        if brain.pendingChoice != nil, attachedCircle == nil {
            brain.answerChoice(saying: text)
            return
        }
        var message = Outgoing(text: text, spoken: spoken, circle: attachedCircle, delegation: delegation)
        attachedCircle = nil
        if brain.isWorking {
            // Two messages while she's answering go together, answering
            // the later hand-off. In a call, so does the one she's on:
            // you paused, she handed it off, and you went on ("explain
            // this graph" … "the second peak"), so the new hand-off is
            // the rest of the same thought.
            let earlier = queued ?? (message.delegation != nil && inFlight?.delegation != nil ? inFlight : nil)
            if let earlier {
                message = Outgoing(
                    text: [earlier.text, message.text].filter { !$0.isEmpty }.joined(separator: "\n"),
                    spoken: earlier.spoken || message.spoken,
                    circle: earlier.circle ?? message.circle,
                    delegation: message.delegation ?? earlier.delegation
                )
            }
            queued = message
            interrupt()
        } else {
            deliver(message)
        }
    }

    /// Try Again, read aloud if the message was a voice message (said in
    /// the call, if one's on).
    func retry() {
        guard brain.canRetry, !brain.isWorking else { return }
        if call.isOn {
            speaksReply = false
            callReply = .say
        } else {
            callReply = nil
            speaksReply = isVoiceMode && speaker.isAvailable
            if speaksReply { speaker.begin(answering: "") }
        }
        brain.retry()
    }

    private func deliver(_ message: Outgoing) {
        guard !brain.isWorking else {
            queued = message
            return
        }
        if call.isOn {
            // In a call, the call says it.
            speaksReply = false
            speaker.stop()
            callReply = message.delegation.map { .delegation($0) } ?? .say
        } else {
            // In Voice mode she says every reply out loud; in Chat mode, none.
            callReply = nil
            speaksReply = isVoiceMode && speaker.isAvailable
            if speaksReply {
                speaker.begin(answering: message.text)
            } else {
                speaker.stop()
            }
        }
        inFlight = message
        brain.send(message.text, circle: message.circle, spoken: message.spoken)
        // It didn't start (no key for her mind): the call hears why, now,
        // since no answer is coming.
        if !brain.isWorking, let reply = callReply {
            callReply = nil
            inFlight = nil
            finishInCall("", reply)
        }
    }

    /// Stops her: her answer and her voice. In a call, the stopped answer
    /// goes nowhere (a newer hand-off gets the next one).
    func interrupt() {
        speaksReply = false
        callReply = nil
        speaker.stop()
        brain.cancel()
    }

    // MARK: Calls

    /// You tapped her in Voice mode, with a Live server set up: she picks up.
    func startCall() {
        // An answer to a voice message still on its way: the call says it.
        if brain.isWorking, speaksReply { callReply = .say }
        hush()
        listener.cancel()
        call.start()
    }

    /// You tapped her again, or switched to Chat: she hangs up.
    func endCall() {
        call.end()
    }

    /// In the call, she handed what you said to her mind.
    private func answerInCall(_ id: String, request: String) {
        guard !request.isEmpty else {
            if brain.isWorking, case .delegation = callReply {
                // The same thing again: the answer that's coming goes here.
                callReply = .delegation(id)
            } else {
                call.answer("I didn't catch that. Could you say it again?", for: id)
            }
            return
        }
        // Answering options she showed: the turn that showed them goes on.
        if brain.pendingChoice != nil {
            callReply = .delegation(id)
            brain.answerChoice(saying: request)
            return
        }
        send(request, spoken: true, delegation: id)
    }

    /// Her mind's answer, finished: the call says it. If the call ended
    /// while her mind worked, it's read out loud instead (Voice mode shows
    /// no words, so it would be lost).
    private func finishInCall(_ text: String, _ reply: CallReply) {
        // Stopped for something newer: that one gets the answer.
        if text.hasSuffix(" …") { return }
        guard call.isOn else {
            if !text.isEmpty, isVoiceMode, speaker.isAvailable {
                speaker.begin(answering: "")
                speaker.feed(text, isComplete: true)
            }
            return
        }
        var said = text
        if said.isEmpty {
            // A hand-off always gets an answer, or the call waits in silence.
            guard case .delegation = reply else { return }
            said = brain.errorText.map { "That didn't work. " + $0 } ?? "Done, it's on your page."
        }
        switch reply {
        case .delegation(let id): call.answer(said, for: id)
        case .say: call.say(said)
        }
    }

    /// Stops her voice, and lets her finish writing.
    func hush() {
        speaksReply = false
        speaker.stop()
    }

    /// Puts the cursor in the compose box beside her (Chat mode).
    func startTyping() {
        typingRequests += 1
    }

    // MARK: Voice messages

    /// You tapped the mic in her card, or tapped her in Voice mode without
    /// a Live server: she listens until you tap again to send
    /// (`finishRecording`), however long you pause.
    func startRecording() {
        hush()
        if isVoiceMode { speaker.warmUp() }
        listener.start()
    }

    /// You tapped again: what you said is sent once it's worked out.
    func finishRecording() {
        listener.release()
    }

    func cancelRecording() {
        listener.cancel()
    }

    // MARK: Circling

    /// The next loop you draw on `page` (or the page you're using) goes to her.
    func startCircling(on page: PalPage? = nil) {
        guard let page = page ?? PalWorkspace.shared.focusedPage else { return }
        circlingPage?.palStopCircling()
        circlingPage = page
        page.palStartCircling()
        isCircling = true
    }

    func stopCircling() {
        circlingPage?.palStopCircling()
        circlingPage = nil
        isCircling = false
    }

    /// You drew a loop: it goes to her right away, unless you're in the
    /// middle of a voice message (then it goes with it). In Chat mode her
    /// card opens, and if she's busy it waits there; in Voice mode it
    /// takes over from what she was doing, and she answers out loud.
    func circled(_ circle: PalCircle) {
        circlingPage = nil
        isCircling = false
        attachedCircle = circle
        if !isVoiceMode { isPaletteOpen = true }
        guard !listener.isListening, hasKey else { return }
        guard isVoiceMode || !brain.isWorking else { return }
        send("", spoken: false)
    }

    func removeAttachment() {
        attachedCircle = nil
    }

    // MARK: Her card

    /// Opens her chat card. Only in Chat mode: Voice mode shows no words.
    func openPalette() {
        guard !isVoiceMode else { return }
        isPaletteOpen = true
    }

    /// Closes her card. She stays, and writes down what's worth remembering.
    func closePalette() {
        isPaletteOpen = false
        stopCircling()
        brain.rememberTalk()
    }

    func startNewTopic() {
        interrupt()
        attachedCircle = nil
        brain.startNewTalk()
    }

    /// A window went to the background: she keeps what's worth
    /// remembering. (A call hangs up only when all of Memor does: see
    /// `PalCall`.)
    func appWentToBackground() {
        listener.cancel()
        brain.rememberTalk()
    }
}
