import SwiftUI

/// Choose the study pal's speaking voice. Tap a voice to hear her say a
/// line in it; the one you tapped last is the one she uses. Each sample is
/// a small request to OpenAI.
struct VoicePicker: View {
    @AppStorage(StudyPalSpeaker.voiceKey) private var chosen = StudyPalSpeaker.defaultVoice
    @State private var sampler = StudyPalSpeaker()

    private static let sample = "Hi! I'm your study pal. Tap me and ask me anything about your notes."

    var body: some View {
        List {
            Section {
                ForEach(StudyPalSpeaker.voices, id: \.self) { voice in
                    Button {
                        chosen = voice
                        sampler.voiceOverride = voice
                        sampler.preview(Self.sample)
                    } label: {
                        HStack {
                            Text(voice.capitalized)
                                .foregroundStyle(.primary)
                            if StudyPalSpeaker.recommendedVoices.contains(voice) {
                                Text("Recommended")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if chosen == voice {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Chosen")
                            }
                        }
                    }
                }
            } footer: {
                if let problem = sampler.problem {
                    Text(problem)
                } else {
                    Text("Tap a voice to hear her. OpenAI's voices are tuned for English. You can also try them at openai.fm.")
                }
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { sampler.stop() }
    }
}
