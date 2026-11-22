import SwiftUI

/// Voice or Chat, beside the study pal. Voice: tap her and talk, like a
/// call. Chat: tap her and type (or dictate), and answers show in the chat
/// panel, for when you can't talk out loud.
struct AskModeSwitch: View {
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

/// Where a spoken chat with the study pal is, so you always know whose turn
/// it is: a small glass pill by her, like a call's.
enum AskCallPhase: Equatable {
    /// She's listening: your turn to talk.
    case listening
    /// You've stopped; she's working out her answer.
    case thinking
    /// She's saying her answer. Tap her to cut in.
    case talking
    /// She's showing options and waiting for your pick.
    case choosing
    /// On the call, between turns.
    case waiting
}

struct AskCallPill: View {
    let phase: AskCallPhase
    /// How loud you are while she listens, 0 to 1.
    let level: Float
    let isCall: Bool
    let onHangUp: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 22, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            Button(action: onHangUp) {
                Image(systemName: isCall ? "phone.down.fill" : "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.red.gradient, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCall ? "Hang Up" : "Stop")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .animation(.easeInOut(duration: 0.2), value: phase)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch phase {
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .talking: "Talking"
        case .choosing: "Your pick"
        case .waiting: "On a call"
        }
    }

    private var detail: String {
        switch phase {
        case .listening: "Go ahead, I'm all ears"
        case .thinking: "One moment…"
        case .talking: "Tap me to cut in"
        case .choosing: "Tap one, or tell me"
        case .waiting: "Tap me to talk"
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch phase {
        case .listening:
            // Bars that follow your voice.
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(Color.green)
                        .frame(width: 3, height: barHeight(index))
                }
            }
            .animation(.easeOut(duration: 0.12), value: level)
        case .thinking:
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative.reversing)
        case .talking:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative)
        case .choosing:
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
        case .waiting:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        }
    }

    /// A little bounce from your voice, each bar a bit different.
    private func barHeight(_ index: Int) -> CGFloat {
        let shape: [CGFloat] = [0.55, 1, 0.8, 0.45]
        let loud = CGFloat(max(level, 0.08))
        return 4 + 14 * loud * shape[index]
    }
}
