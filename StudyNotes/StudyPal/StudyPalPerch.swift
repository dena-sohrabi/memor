import SwiftUI
import UIKit

/// The study pal where she sits, and what your finger does to her:
/// - tap her;
/// - rub her back and forth to scratch her. With Apple Pencil Pro you feel
///   each rub in the pencil, a soft purr under your hand (the iPad's screen
///   itself can't vibrate). Keep at it and hearts float up from her;
/// - press and hold, or drag her straight off, to carry her somewhere
///   else. She lifts a little while carried and swings as you move her.
///
/// The parent decides where she sits. It also places the coordinate space
/// named `space` over the whole area she moves in.
struct StudyPalPerch: View {
    static let space = "studyPalPerch"

    let center: CGPoint
    let size: CGSize
    let mood: StudyPalMood
    let cue: StudyPalCue
    let onTap: () -> Void
    /// You let go of her here, moving this fast (points a second).
    let onDrop: (_ point: CGPoint, _ velocity: CGSize) -> Void

    private enum Touch {
        case none
        /// Down, and not yet a tap, a scratch or a carry.
        case pressing
        case carrying
        case scratching
    }

    @State private var link = StudyPalLink()
    @State private var touch = Touch.none
    @State private var rub = Rub(at: .zero)
    @State private var holdTask: Task<Void, Never>?
    @State private var lastTranslation = CGSize.zero
    /// How far your finger had gone when she was picked up. She keeps that
    /// distance from it, rather than jumping under it.
    @State private var grabTranslation = CGSize.zero
    @State private var carryOffset = CGSize.zero
    @GestureState private var isTouching = false
    /// Hearts floating up while you keep scratching her.
    @State private var hearts: [ScratchHeart] = []
    @State private var scratchStarted: Date?
    @State private var lastHeart = Date.distantPast
    /// Taps in Apple Pencil Pro as you rub her with it.
    @State private var pencilFeedback: UICanvasFeedbackGenerator?

    private var isLifted: Bool { touch == .carrying }

    var body: some View {
        ZStack {
            // Her shadow on the page. Lifted, she's higher up, so it falls
            // further away, smaller and softer.
            Ellipse()
                .fill(.black.opacity(isLifted ? 0.07 : 0.15))
                .frame(width: size.width * (isLifted ? 0.28 : 0.34), height: size.height * 0.08)
                .blur(radius: isLifted ? 9 : 5)
                .offset(y: size.height * (isLifted ? 0.38 : 0.27))
                .allowsHitTesting(false)
            StudyPalView(mood: mood, cue: cue, link: link)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                .overlay {
                    // Touches land on her body and the roots of her wings. The
                    // page around her keeps working.
                    Color.clear
                        .frame(width: size.width * 0.64, height: size.height * 0.6)
                        .contentShape(Ellipse())
                        .gesture(touchGesture)
                }
                .scaleEffect(isLifted ? 1.08 : 1)
                .offset(y: isLifted ? -8 : 0)
            ForEach(hearts) { heart in
                FloatingHeart(heart: heart)
            }
            .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isLifted)
        .position(x: center.x + carryOffset.width, y: center.y + carryOffset.height)
        .onChange(of: isTouching) { _, touching in
            // The system took the touch away without ending it.
            if !touching { finish(nil) }
        }
        .accessibilityHidden(true)
    }

    /// Measured in the parent's space, not hers: she moves under the finger,
    /// and measuring from her own frame would make her shake.
    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($isTouching) { _, touching, _ in touching = true }
            .onChanged { changed($0) }
            .onEnded { finish($0) }
    }

    private func changed(_ value: DragGesture.Value) {
        lastTranslation = value.translation
        let distance = hypot(value.translation.width, value.translation.height)
        switch touch {
        case .none:
            touch = .pressing
            rub = Rub(at: value.startLocation)
            holdTask?.cancel()
            holdTask = Task {
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled, touch == .pressing else { return }
                pickUp()
            }
        case .pressing:
            if distance > 10 { holdTask?.cancel() }
            if rub.turnsBack(at: value.location) {
                // Back and forth: that's a scratch.
                touch = .scratching
                scratchStarted = .now
                link.view?.beginScratch()
                link.view?.scratch(at: side(of: value.location))
                purr(at: value.location)
            } else if distance > 44 {
                // Straight off in one direction: she's being moved.
                pickUp()
            }
        case .carrying:
            // She flies after your finger, a moment behind it.
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.78)) {
                carryOffset = CGSize(
                    width: value.translation.width - grabTranslation.width,
                    height: value.translation.height - grabTranslation.height
                )
            }
        case .scratching:
            if rub.turnsBack(at: value.location) {
                link.view?.scratchStroke()
                purr(at: value.location)
            }
            link.view?.scratch(at: side(of: value.location))
        }
    }

    /// One rub: a tap in Apple Pencil Pro under your hand, and once you've
    /// kept scratching a moment, a heart floating up from her.
    private func purr(at location: CGPoint) {
        let local = CGPoint(x: location.x - center.x - carryOffset.width, y: location.y - center.y - carryOffset.height)
        if let view = link.view {
            if pencilFeedback == nil { pencilFeedback = UICanvasFeedbackGenerator(view: view) }
            pencilFeedback?.alignmentOccurred(at: CGPoint(x: view.bounds.midX + local.x, y: view.bounds.midY + local.y))
        }
        let now = Date.now
        guard let scratchStarted, now.timeIntervalSince(scratchStarted) > 0.7,
              now.timeIntervalSince(lastHeart) > 0.18, hearts.count < 12 else { return }
        lastHeart = now
        // From her head, around where your finger is.
        let reach = size.width * 0.22
        let heart = ScratchHeart(start: CGPoint(x: min(max(local.x, -reach), reach), y: -size.height * 0.2))
        hearts.append(heart)
        Task {
            try? await Task.sleep(for: .seconds(ScratchHeart.lifetime))
            hearts.removeAll { $0.id == heart.id }
        }
    }

    private func pickUp() {
        holdTask?.cancel()
        touch = .carrying
        grabTranslation = lastTranslation
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        link.view?.setCarried(true)
    }

    /// The touch ended (`value`), or was cancelled (`nil`).
    private func finish(_ value: DragGesture.Value?) {
        holdTask?.cancel()
        holdTask = nil
        let ended = touch
        touch = .none
        switch ended {
        case .none:
            break
        case .pressing:
            guard let value else { break }
            if hypot(value.translation.width, value.translation.height) <= 10 {
                onTap()
            } else {
                link.view?.pet()
            }
        case .scratching:
            scratchStarted = nil
            link.view?.endScratch()
        case .carrying:
            link.view?.setCarried(false)
            let point = CGPoint(x: center.x + carryOffset.width, y: center.y + carryOffset.height)
            withAnimation(.spring(duration: 0.6, bounce: 0.2)) {
                onDrop(point, value?.velocity ?? .zero)
                carryOffset = .zero
            }
        }
    }

    /// Where a point is across her: -1 at her left edge, 1 at her right.
    private func side(of point: CGPoint) -> CGFloat {
        (point.x - center.x - carryOffset.width) / (size.width * 0.32)
    }
}

/// A heart from scratching her: its own size, color, drift and tilt.
private struct ScratchHeart: Identifiable {
    static let lifetime = 1.4
    private static let colors: [Color] = [
        .pink,
        Color(red: 1, green: 0.42, blue: 0.6),
        Color(red: 1, green: 0.32, blue: 0.45),
        Color(red: 0.98, green: 0.58, blue: 0.72),
    ]

    let id = UUID()
    /// Where it starts, from her middle.
    let start: CGPoint
    let size = CGFloat.random(in: 14...26)
    let rise = CGFloat.random(in: 60...110)
    let sway = CGFloat.random(in: -22...22)
    let tilt = Double.random(in: -18...18)
    let color = Self.colors.randomElement() ?? .pink
}

/// A heart that pops up, floats away with a little sway and fades. With
/// Reduce Motion, it fades in and out where it is.
private struct FloatingHeart: View {
    let heart: ScratchHeart

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOff = false

    private struct Motion {
        var scale: CGFloat = 0.2
        var x: CGFloat = 0
        var y: CGFloat = 0
        var tilt: Double = 0
        var opacity: Double = 0
    }

    var body: some View {
        let rise: CGFloat = reduceMotion ? 0 : -heart.rise
        let sway: CGFloat = reduceMotion ? 0 : heart.sway
        Image(systemName: "heart.fill")
            .font(.system(size: heart.size, weight: .bold))
            .foregroundStyle(heart.color.gradient)
            .shadow(color: heart.color.opacity(0.35), radius: 4, y: 1)
            .keyframeAnimator(initialValue: Motion(), trigger: isOff) { content, motion in
                content
                    .scaleEffect(motion.scale)
                    .rotationEffect(.degrees(motion.tilt))
                    .offset(x: heart.start.x + motion.x, y: heart.start.y + motion.y)
                    .opacity(motion.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                    LinearKeyframe(0.85, duration: 1.1)
                }
                KeyframeTrack(\.y) {
                    CubicKeyframe(rise, duration: 1.4)
                }
                KeyframeTrack(\.x) {
                    CubicKeyframe(sway, duration: 0.7)
                    CubicKeyframe(-sway * 0.4, duration: 0.7)
                }
                KeyframeTrack(\.tilt) {
                    CubicKeyframe(heart.tilt, duration: 1.4)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.15)
                    LinearKeyframe(1, duration: 0.75)
                    LinearKeyframe(0, duration: 0.5)
                }
            }
            .onAppear { isOff = true }
    }
}

/// Notices a finger turning back on itself: rubbing rather than dragging.
private struct Rub {
    private struct Axis {
        /// The farthest the finger has gone in its current direction.
        var extreme: CGFloat
        /// 1 or -1 once it's moving, 0 before.
        var direction: CGFloat = 0

        /// Whether the finger just came back at least 7 points from its
        /// farthest point.
        mutating func move(to value: CGFloat) -> Bool {
            let delta = value - extreme
            if direction == 0 {
                if abs(delta) > 7 {
                    direction = delta > 0 ? 1 : -1
                    extreme = value
                }
                return false
            }
            if delta * direction >= 0 {
                extreme = value
                return false
            }
            guard abs(delta) > 7 else { return false }
            direction = -direction
            extreme = value
            return true
        }
    }

    private var x: Axis
    private var y: Axis

    init(at point: CGPoint) {
        x = Axis(extreme: point.x)
        y = Axis(extreme: point.y)
    }

    mutating func turnsBack(at point: CGPoint) -> Bool {
        let turnedX = x.move(to: point.x)
        let turnedY = y.move(to: point.y)
        return turnedX || turnedY
    }
}
