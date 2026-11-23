import SwiftUI
import UserNotifications

/// The one study pal in Memor, shared by every window: her mind
/// (`PalBrain`), her ears (`StudyPalListener`) and her voice
/// (`StudyPalSpeaker`), and the state of her chat card.
///
/// - A switch beside her picks Voice or Chat. In Voice mode, talk to her
///   with voice messages: tap her (or the mic) and talk, and it's sent when
///   you pause, or hold the mic and let go to send; she says her replies
///   out loud, and no words show on screen. In Chat mode, she only writes:
///   a compose box sits beside her, and her replies show in her chat card.
/// - Or say "Hey" and her name, and what you want.
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
    /// Listens for "Hey <her name>".
    let wake = PalWakeListener()

    /// Her chat card is open.
    var isPaletteOpen = false
    /// Waiting for you to circle something on a page.
    private(set) var isCircling = false
    /// Something circled, waiting to go with your next message.
    private(set) var attachedCircle: PalCircle?

    nonisolated static let modeKey = "studyPal.mode"

    /// Voice or Chat, from the switch beside her. Voice: she says her
    /// replies out loud, the mic is beside her, she listens for "Hey" and
    /// her name, and nothing shows as text (her card stays closed). Chat:
    /// she only writes, for when you can't talk out loud; a compose box
    /// sits beside her, and tapping her puts the cursor in it.
    var isVoiceMode = (UserDefaults.standard.string(forKey: Pal.modeKey) ?? "voice") != "chat" {
        didSet {
            UserDefaults.standard.set(isVoiceMode ? "voice" : "chat", forKey: Self.modeKey)
            if isVoiceMode {
                // The talk carries on; it just isn't shown.
                isPaletteOpen = false
            } else {
                hush()
                wake.stopNow()
            }
        }
    }

    /// Asks the compose box beside her to put the cursor in its field
    /// (Chat mode).
    private(set) var typingRequests = 0

    /// Opens windows for her (set by the window she's in).
    @ObservationIgnored var openWindow: OpenWindowAction?

    /// She can think: there's a key for her mind (Claude or GPT).
    private(set) var hasKey = PalMind.current != nil

    /// A key was added or removed, or her mind changed, in Settings. The
    /// next talk uses it.
    func keyChanged() {
        hasKey = PalMind.current != nil
    }

    /// A message, on its way to her.
    private struct Outgoing {
        let text: String
        let spoken: Bool
        let circle: PalCircle?
    }

    /// The reply being written is read out loud.
    @ObservationIgnored private var speaksReply = false
    /// Sent while she was still answering: it goes once she's stopped.
    @ObservationIgnored private var queued: Outgoing?
    @ObservationIgnored private weak var circlingPage: PalPage?

    private init() {
        brain.onReply = { [weak self] text, isComplete in
            guard let self else { return }
            if self.speaksReply {
                self.speaker.feed(text, isComplete: isComplete)
                if isComplete { self.speaksReply = false }
            }
            if isComplete, let next = self.queued {
                self.queued = nil
                // Once this answer has wound down.
                Task { self.deliver(next) }
            }
        }
        listener.onHeard = { [weak self] text in
            self?.send(text, spoken: true)
        }
        // What you're studying goes along when you talk, so its words are
        // heard right.
        let context: () -> SpeechContext = {
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
        listener.context = context
        wake.context = context
        wake.onWake = { [weak self] in
            self?.hush()
        }
        wake.onCommand = { [weak self] text in
            self?.send(text, spoken: true)
        }
        // Only in Voice mode, while Memor is on screen, and while nobody
        // else is using the microphone or speaker.
        wake.shouldListen = { [weak self] in
            guard let self else { return false }
            let onScreen = UIApplication.shared.applicationState == .active
            return self.isVoiceMode && onScreen && self.hasKey && !self.listener.isListening && !self.speaker.isTalking
        }
        wake.startWatching()
        UNUserNotificationCenter.current().delegate = PalNotificationDelegate.shared
    }

    // MARK: Talking

    /// Sends a message to her, with anything circled. If she's in the
    /// middle of an answer, she stops and takes this one instead.
    func send(_ text: String, spoken: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachedCircle != nil else { return }
        // Answering options she showed isn't a new message.
        if brain.pendingChoice != nil, attachedCircle == nil {
            brain.answerChoice(saying: text)
            return
        }
        var message = Outgoing(text: text, spoken: spoken, circle: attachedCircle)
        attachedCircle = nil
        if brain.isWorking {
            // Two messages while she's answering go together.
            if let earlier = queued {
                message = Outgoing(
                    text: [earlier.text, message.text].filter { !$0.isEmpty }.joined(separator: "\n"),
                    spoken: earlier.spoken || message.spoken,
                    circle: earlier.circle ?? message.circle
                )
            }
            queued = message
            interrupt()
        } else {
            deliver(message)
        }
    }

    /// Try Again, read aloud if the message was a voice message.
    func retry() {
        speaksReply = isVoiceMode && speaker.isAvailable
        if speaksReply { speaker.begin(answering: "") }
        brain.retry()
    }

    private func deliver(_ message: Outgoing) {
        guard !brain.isWorking else {
            queued = message
            return
        }
        // In Voice mode she says every reply out loud; in Chat mode, none.
        speaksReply = isVoiceMode && speaker.isAvailable
        if speaksReply {
            speaker.begin(answering: message.text)
        } else {
            speaker.stop()
        }
        brain.send(message.text, circle: message.circle, spoken: message.spoken)
    }

    /// Stops her: her answer and her voice.
    func interrupt() {
        speaksReply = false
        speaker.stop()
        brain.cancel()
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

    /// You pressed the mic, or tapped her in Voice mode. `holding`: let go
    /// to send; otherwise it's sent when you pause, or when you tap again.
    func startRecording(holding: Bool) {
        hush()
        // The microphone is yours now, not her name-listening.
        wake.stopNow()
        if isVoiceMode { speaker.warmUp() }
        listener.start(holding: holding)
    }

    /// The press turned out to be a tap: she listens until you pause or
    /// tap again, or gives up after a while if you say nothing.
    func recordingBecameTap() {
        listener.becameTap()
    }

    /// Done talking: what you said is sent once it's worked out.
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

    /// Memor went to the background: she keeps what's worth remembering.
    func appWentToBackground() {
        listener.cancel()
        brain.rememberTalk()
    }
}
