import SwiftUI

/// What the study pal is doing, as one line with no background, like the
/// step updates in ChatGPT or Claude: an icon, and words with a light
/// sweeping across them while it goes on ("Creating an image…"). Over her
/// head it has a soft halo of the page's color, so it reads over
/// handwriting and PDFs; in her card it doesn't need one.
struct PalStatusLine: View {
    let activity: PalActivity
    /// The words sit straight on a page, not in her card.
    var hasHalo = true

    var body: some View {
        HStack(spacing: 7) {
            if let symbol = activity.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }
            Text(activity.text)
                .lineLimit(1)
                .modifier(PalShimmer())
        }
        .font(.callout.weight(.medium))
        .shadow(color: halo, radius: 2)
        .shadow(color: halo, radius: 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var halo: Color {
        hasHalo ? Color(uiColor: .systemBackground).opacity(0.9) : .clear
    }
}

/// A light sweeping across text, left to right, over and over, while
/// something's going on. With Reduce Motion on, the text stays still.
private struct PalShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One sweep, in seconds.
    private static let cycle: TimeInterval = 1.8

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { timeline in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        let phase = CGFloat(time.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle)
                        content
                            .foregroundStyle(.primary)
                            .mask {
                                GeometryReader { proxy in
                                    let band = max(proxy.size.width * 0.4, 48)
                                    LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
                                        .frame(width: band)
                                        .offset(x: -band + (proxy.size.width + band) * phase)
                                }
                            }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}
