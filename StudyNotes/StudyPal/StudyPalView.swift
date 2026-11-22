import GLTFKit2
import SceneKit
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// What the study pal is doing, from the state of the chat.
enum StudyPalMood: Equatable {
    /// Breathing, floating, blinking, and now and then fidgeting.
    case idle
    /// Claude is working: she gazes up and holds the thought.
    case thinking
    /// An answer is streaming in: she talks.
    case talking
}

/// A one-off reaction to the chat, played over her mood.
enum StudyPalReaction: Equatable {
    /// Hello, when Ask Claude opens.
    case wave
    /// The user started typing, or she started listening.
    case listen
    /// An answer is done.
    case nod
    /// Claude changed the page.
    case delight
    /// Something went wrong.
    case sad
    /// The user tapped her.
    case poke
}

/// A reaction to play. A cue with a new `id` plays again.
struct StudyPalCue: Equatable {
    var id = 0
    var reaction = StudyPalReaction.wave

    func next(_ reaction: StudyPalReaction) -> StudyPalCue {
        StudyPalCue(id: id + 1, reaction: reaction)
    }
}

/// Lets the SwiftUI side reach her live scene, for touches that play out
/// frame by frame (scratching her, carrying her).
@MainActor
final class StudyPalLink {
    weak var view: StudyPalSceneView?
}

/// The study pal: a soft pink creature with gray wings, live in 3D. She
/// thinks while Claude works, talks while the answer comes in, and reacts
/// to the chat and to being tapped, scratched or carried around.
/// VoiceOver skips her.
struct StudyPalView: UIViewRepresentable {
    var mood: StudyPalMood
    var cue: StudyPalCue
    var link: StudyPalLink?

    func makeUIView(context: Context) -> StudyPalSceneView {
        let view = StudyPalSceneView()
        link?.view = view
        return view
    }

    func updateUIView(_ view: StudyPalSceneView, context: Context) {
        link?.view = view
        view.setMood(mood)
        view.play(cue)
    }

    static func dismantleUIView(_ view: StudyPalSceneView, coordinator: ()) {
        view.tearDown()
    }
}

/// Renders the creature from `CreamCreature.glb` and plays its animation
/// clips the way her kit describes: `Idle` and `Blink` all the time,
/// `ThinkIn` / `Thinking` / `ThinkOut` around Claude's work, `Speak` while
/// an answer streams, and the gestures, wing and feather clips as reactions.
///
/// Each clip has its own channel on the model (breath, blink, mouth, arm,
/// wings, body gesture, feathers), so several play at once. Only one body
/// gesture (Listen, Nod, Delight) plays at a time.
///
/// On top of the clips, every frame:
/// - She flies whenever she moves: her wings beat, she bobs, and she leans
///   into the way she's going and swings back when she stops.
/// - She looks at where you're writing or touching, and glances around now
///   and then when you're not.
/// - Her feathers breathe, and ripple while she flies.
/// - She leans into a scratch, eyes shut, cooing softly.
final class StudyPalSceneView: UIView {
    private let sceneView = SCNView(frame: .zero, options: nil)
    private let voice = StudyPalVoice()
    /// The animations play on the scene's root node: their key paths name
    /// the model's nodes from there ("/Breath.position").
    private var root: SCNNode?
    /// The whole creature. No clip moves this node, so it's free for her
    /// leaning, turning and bobbing.
    private var creature: SCNNode?
    private var eyes: SCNNode?
    private var wings: [SCNNode] = []
    private var clips: [String: SCNAnimation] = [:]
    /// The key each clip last started under. A clip that starts again
    /// fades over from the one still playing.
    private var playingKeys: [String: String] = [:]
    private var playCount = 0
    private var mood = StudyPalMood.idle
    private var playedCueID: Int?
    /// A reaction that arrived before the model finished loading.
    private var pendingCue: StudyPalCue?
    /// Bumped on every mood change, so a delayed step of an older mood
    /// (like starting the thinking loop) doesn't run.
    private var generation = 0
    private var lastReaction = Date.distantPast
    private var pokeCount = 0
    private var loadTask: Task<Void, Never>?
    private var blinkTask: Task<Void, Never>?
    private var fidgetTask: Task<Void, Never>?

    // Touch
    private var isCarried = false
    private var isScratched = false
    private var scratchStrokes = 0
    /// Where your finger is across her while you scratch her: -1 at her
    /// left, 1 at her right, as you see her.
    private var scratchSide: Float = 0
    private let touchWatcher = TouchWatcher()
    /// The last place you touched or wrote, in window points, and when.
    private var gazePoint: CGPoint?
    private var gazeTime: CFTimeInterval = 0
    private var glance: (yaw: Float, pitch: Float) = (0, 0)
    private var nextGlance: CFTimeInterval = 0

    // Motion
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var lastPosition: CGPoint?
    /// How fast she's moving across the screen, smoothed, in points a second.
    private var velocity = CGPoint.zero
    private var isFlying = false
    /// Eases between 0 (sitting) and 1 (flying).
    private var flight: Float = 0
    private var slowSince: CFTimeInterval?
    private var roll = Sway()
    private var yaw = Sway()
    private var pitch = Sway()
    private var eyesClosed: CGFloat = 0

    nonisolated private static let loopingClips: Set<String> = ["Idle", "Thinking", "Speak"]
    /// Her fur: tinted soft pink. Her eyes, mouth, brows and wings keep
    /// their colors.
    nonisolated private static let coatMaterials: Set<String> = ["Cream blond undercoat", "Cream blond down", "Ivory guard hairs"]
    private static let bodyGestures = ["Listen", "Nod", "Delight"]
    private static let featherExpressions = ["CuriousFeathers", "HappyFeathers", "SadFeathers"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        sceneView.frame = bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.backgroundColor = .clear
        sceneView.isOpaque = false
        sceneView.antialiasingMode = .multisampling4X
        // Smooth while she moves; she drops to 30 fps when she's only
        // breathing, which leaves the GPU to the canvas and your Pencil.
        sceneView.preferredFramesPerSecond = 60
        sceneView.rendersContinuously = true
        sceneView.isPlaying = true
        sceneView.alpha = 0
        addSubview(sceneView)
        touchWatcher.onTouch = { [weak self] point in
            self?.gazePoint = point
            self?.gazeTime = CACurrentMediaTime()
        }
        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func tearDown() {
        generation += 1
        loadTask?.cancel()
        blinkTask?.cancel()
        fidgetTask?.cancel()
        stopMotion()
        touchWatcher.view?.removeGestureRecognizer(touchWatcher)
        voice.shutDown()
        root?.removeAllAnimations()
        sceneView.isPlaying = false
        sceneView.scene = nil
        clips.removeAll()
        playingKeys.removeAll()
        root = nil
        creature = nil
        eyes = nil
        wings = []
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        touchWatcher.view?.removeGestureRecognizer(touchWatcher)
        newWindow?.addGestureRecognizer(touchWatcher)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startMotion() } else { stopMotion() }
    }

    // MARK: Loading

    /// SceneKit objects aren't Sendable, but these are made off the main
    /// thread, handed over once, and from then on used only on it.
    private struct LoadedModel: @unchecked Sendable {
        let scene: SCNScene
        let clips: [String: SCNAnimation]
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "CreamCreature", withExtension: "glb") else { return }
        loadTask = Task { [weak self] in
            // The model is about 14 MB; reading it would stall the page.
            let model = await Task.detached(priority: .userInitiated) { StudyPalSceneView.loadModel(from: url) }.value
            guard let self, !Task.isCancelled, let model else { return }
            self.show(model)
        }
    }

    nonisolated private static func loadModel(from url: URL) -> LoadedModel? {
        guard let asset = try? GLTFAsset(url: url) else { return nil }
        let source = GLTFSCNSceneSource(asset: asset)
        guard let scene = source.defaultScene else { return nil }
        var clips: [String: SCNAnimation] = [:]
        for animation in source.animations {
            let base = animation.animationPlayer.animation
            clips[animation.name] = makeClip(from: base, loops: loopingClips.contains(animation.name))
            // While she flies, she keeps flapping.
            if animation.name == "WingFlutter" {
                clips["WingFlutterLoop"] = makeClip(from: base, loops: true)
            }
        }
        prepareMaterials(in: scene.rootNode)
        return LoadedModel(scene: scene, clips: clips)
    }

    /// GLTFKit2 makes every clip repeat forever. Reactions should play
    /// once, so each clip is rebuilt with its own repeat count, on the
    /// clock rather than the scene's time, with soft blends in and out.
    nonisolated private static func makeClip(from animation: SCNAnimation, loops: Bool) -> SCNAnimation {
        let group = CAAnimation(scnAnimation: animation)
        group.repeatDuration = 0
        group.repeatCount = loops ? .greatestFiniteMagnitude : 1
        let clip = SCNAnimation(caAnimation: group)
        clip.repeatCount = loops ? .greatestFiniteMagnitude : 1
        clip.usesSceneTimeBase = false
        clip.isRemovedOnCompletion = true
        clip.blendInDuration = 0.2
        clip.blendOutDuration = 0.25
        return clip
    }

    /// Makes every surface solid, her coat soft pink and velvety, her
    /// wings pearly, and her eyes glossy.
    ///
    /// GLTFKit2 writes the textures' alpha straight to the screen, even
    /// for surfaces glTF says are opaque or alpha-masked (cut out, but
    /// solid where they show). On a clear background that let the page
    /// show through her fur, so she looked like glass.
    ///
    /// - The pink keeps the coat's own light and shade (its brightness)
    ///   and swaps the cream for pink.
    /// - The velvet is a soft glow where the fur turns away from you, as
    ///   light catches the tips of real fur.
    /// - The pearl is a faint pink-to-blue sheen at the edges of the
    ///   feathers, there and gone as she moves.
    nonisolated private static func prepareMaterials(in root: SCNNode) {
        let solid = "_output.color.a = 1.0;"
        let pinkVelvet = """
        float studyPalShade = dot(_surface.diffuse.rgb, float3(0.2126, 0.7152, 0.0722));
        _surface.diffuse.rgb = saturate(studyPalShade * float3(1.42, 0.88, 0.98));
        float studyPalRim = 1.0 - saturate(dot(_surface.normal, _surface.view));
        _surface.emission.rgb += pow(studyPalRim, 3.0) * float3(1.0, 0.86, 0.9) * 0.14;
        """
        let pearl = """
        float studyPalEdge = pow(1.0 - abs(dot(_surface.normal, _surface.view)), 3.0);
        _surface.emission.rgb += studyPalEdge * mix(float3(1.0, 0.86, 0.94), float3(0.8, 0.88, 1.0), studyPalEdge) * 0.12;
        """
        var done = Set<ObjectIdentifier>()
        root.enumerateHierarchy { node, _ in
            for material in node.geometry?.materials ?? [] where done.insert(ObjectIdentifier(material)).inserted {
                var modifiers = material.shaderModifiers ?? [:]
                func add(_ code: String, to entry: SCNShaderModifierEntryPoint) {
                    modifiers[entry] = [modifiers[entry], code].compactMap { $0 }.joined(separator: "\n")
                }
                if material.blendMode != .alpha { add(solid, to: .fragment) }
                let name = material.name ?? ""
                if coatMaterials.contains(name) { add(pinkVelvet, to: .surface) }
                if name == "Dove gray feathers" { add(pearl, to: .surface) }
                if name == "Ink eyes" {
                    // Wet, bright eyes.
                    material.roughness.contents = NSNumber(value: 0.15)
                    material.clearCoat.contents = NSNumber(value: 0.8)
                    material.clearCoatRoughness.contents = NSNumber(value: 0.05)
                }
                material.shaderModifiers = modifiers
            }
        }
    }

    private func show(_ model: LoadedModel) {
        let scene = model.scene
        let root = scene.rootNode
        // When she's small, the fine guard hairs don't show; the coat
        // underneath keeps her fluffy and is much lighter to draw.
        root.childNode(withName: "GuardHairs", recursively: true)?.isHidden = bounds.width < 220

        let camera = Self.makeCamera(framing: root)
        Self.addLights(to: scene)
        root.addChildNode(camera)
        sceneView.scene = scene
        sceneView.pointOfView = camera
        self.root = root
        creature = root.childNode(withName: "CreamCreature", recursively: false)
        eyes = root.childNode(withName: "Eyes", recursively: true)
        wings = ["WingLeft", "WingRight"].compactMap { root.childNode(withName: $0, recursively: true) }
        clips = model.clips

        restart("Idle")
        startBlinking()
        startFidgeting()
        enter(mood, from: .idle)
        if let pendingCue {
            self.pendingCue = nil
            play(pendingCue)
        }
        UIView.animate(withDuration: 0.3) { self.sceneView.alpha = 1 }
    }

    /// Frames her whole wingspan with room for a hop and raised wings. The
    /// model is Y up and faces +Z.
    private static func makeCamera(framing root: SCNNode) -> SCNNode {
        let (low, high) = root.boundingBox
        var width = CGFloat(high.x - low.x)
        var center = SCNVector3((low.x + high.x) / 2, (low.y + high.y) / 2, 0)
        if !(width.isFinite && width > 0.5) {
            width = 6
            center = SCNVector3(0, 0, 0)
        }
        let camera = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.fieldOfView = 38
        camera.zNear = 0.1
        camera.zFar = 200
        let node = SCNNode()
        node.camera = camera
        let distance = width * 1.2 / 2 / tan(camera.fieldOfView / 2 * .pi / 180)
        node.position = SCNVector3(center.x, center.y + 0.1, Float(distance))
        node.look(at: center)
        return node
    }

    /// A broad neutral key, a softer fill and a backlight that rims her
    /// fur and picks out the feathers, as she was lit in Blender.
    private static func addLights(to scene: SCNScene) {
        func addLight(_ type: SCNLight.LightType, intensity: CGFloat, color: UIColor, angles: SCNVector3 = SCNVector3(0, 0, 0)) {
            let light = SCNLight()
            light.type = type
            light.intensity = intensity
            light.color = color
            let node = SCNNode()
            node.light = light
            node.eulerAngles = angles
            scene.rootNode.addChildNode(node)
        }
        let warm = UIColor(red: 1, green: 0.97, blue: 0.94, alpha: 1)
        let cool = UIColor(red: 0.92, green: 0.95, blue: 1, alpha: 1)
        addLight(.directional, intensity: 900, color: warm, angles: SCNVector3(-0.55, 0.45, 0))
        addLight(.directional, intensity: 320, color: cool, angles: SCNVector3(-0.2, -0.7, 0))
        addLight(.directional, intensity: 650, color: warm, angles: SCNVector3(-0.4, .pi, 0))
        addLight(.ambient, intensity: 140, color: warm)
        scene.lightingEnvironment.contents = environmentImage()
        scene.lightingEnvironment.intensity = 1
    }

    /// Soft studio light from all around: bright and a little cool above,
    /// warm below, like a room with a window.
    private static func environmentImage() -> UIImage {
        let size = CGSize(width: 64, height: 32)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [
                UIColor(red: 0.97, green: 0.98, blue: 1, alpha: 1).cgColor,
                UIColor(red: 1, green: 0.98, blue: 0.96, alpha: 1).cgColor,
                UIColor(red: 0.78, green: 0.73, blue: 0.72, alpha: 1).cgColor,
            ] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) else { return }
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
    }

    // MARK: Mood

    func setMood(_ newMood: StudyPalMood) {
        guard newMood != mood else { return }
        let old = mood
        mood = newMood
        // She hums softly while she thinks.
        if newMood == .thinking {
            voice.startHumming()
        } else if old == .thinking {
            voice.stopHumming()
        }
        guard root != nil else { return }
        enter(newMood, from: old)
    }

    private func enter(_ mood: StudyPalMood, from old: StudyPalMood) {
        generation += 1
        let generation = generation
        switch mood {
        case .thinking:
            stop("Speak")
            // Thinking uses her body, brows and feathers, so other gestures
            // and expressions let go first.
            for name in Self.bodyGestures + Self.featherExpressions { stop(name) }
            restart("ThinkIn")
            // The entry ends in the loop's opening pose. The loop fades in
            // over the entry's last moment, so she never dips back to rest.
            after(max(duration(of: "ThinkIn") - 0.2, 0), generation) { $0.restart("Thinking") }
        case .talking:
            var delay: TimeInterval = 0
            if old == .thinking {
                leaveThinking()
                delay = duration(of: "ThinkOut") * 0.5
            }
            after(delay, generation) { $0.restart("Speak") }
        case .idle:
            if old == .thinking { leaveThinking() }
            stop("Speak")
        }
    }

    private func leaveThinking() {
        stop("ThinkIn", fade: 0.15)
        stop("Thinking", fade: 0.15)
        restart("ThinkOut")
    }

    /// Every 3 to 6 seconds, and now and then twice in a row.
    private func startBlinking() {
        blinkTask?.cancel()
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 3...6)))
                guard let self, !Task.isCancelled else { return }
                // Her eyes stay shut while you scratch her.
                guard !self.isScratched else { continue }
                self.restart("Blink")
                if Int.random(in: 0..<5) == 0 {
                    try? await Task.sleep(for: .milliseconds(320))
                    if !Task.isCancelled, !self.isScratched { self.restart("Blink") }
                }
            }
        }
    }

    /// Now and then, when nothing's going on, she does a little something:
    /// tilts her head, ruffles her feathers or stretches her wings.
    private func startFidgeting() {
        fidgetTask?.cancel()
        fidgetTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 7...13)))
                guard let self, !Task.isCancelled else { return }
                guard self.mood == .idle, !self.isCarried, !self.isScratched, !self.isFlying,
                      !UIAccessibility.isReduceMotionEnabled,
                      Date.now.timeIntervalSince(self.lastReaction) > 5 else { continue }
                switch Int.random(in: 0..<4) {
                case 0: self.restart("CuriousFeathers")
                case 1: self.restart("HappyFeathers")
                case 2: self.restart("WingFlutter")
                default:
                    self.gesture("Listen")
                    self.restart("CuriousFeathers")
                }
            }
        }
    }

    // MARK: Reactions

    func play(_ cue: StudyPalCue) {
        guard cue.id != playedCueID else { return }
        guard root != nil else {
            pendingCue = cue
            return
        }
        playedCueID = cue.id
        lastReaction = .now
        // The wave when a page opens (the first cue) is silent.
        switch cue.reaction {
        case .wave: if cue.id > 0 { voice.play(.hello) }
        case .listen: voice.play(.listening)
        case .delight: voice.play(.happy)
        case .sad: voice.play(.sad)
        case .poke: voice.play(Bool.random() ? .mrrp : .happy)
        case .nod: break
        }
        // Keep her calm for people who asked for less motion.
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let thinking = mood == .thinking
        switch cue.reaction {
        case .wave:
            // Arm and whole wings have their own channels, so she can wave
            // even while thinking.
            restart("Wave")
            if !isFlying { restart("WingFlutter") }
        case .listen where !thinking:
            gesture("Listen")
            restart("CuriousFeathers")
        case .nod where !thinking:
            gesture("Nod")
        case .delight where !thinking:
            gesture("Delight")
            restart("HappyFeathers")
        case .sad where !thinking:
            restart("SadFeathers")
        case .poke where !thinking:
            poke()
        case .delight, .poke:
            // While she thinks, only her wings are free.
            if !isFlying { restart("WingFlutter") }
        default:
            break
        }
    }

    /// Each tap gets a different response.
    private func poke() {
        pokeCount += 1
        switch pokeCount % 4 {
        case 1:
            gesture("Delight")
            restart("HappyFeathers")
        case 2:
            restart("Wave")
            if !isFlying { restart("WingFlutter") }
        case 3:
            gesture("Listen")
            restart("CuriousFeathers")
        default:
            gesture("Nod")
            if !isFlying { restart("WingFlutter") }
            restart("HappyFeathers")
        }
    }

    private func gesture(_ name: String) {
        for other in Self.bodyGestures where other != name { stop(other) }
        restart(name)
    }

    // MARK: Touch

    /// Picked up to be carried somewhere else: she takes off right away and
    /// flies under your finger. She lands once she's put down and settled.
    func setCarried(_ carried: Bool) {
        guard carried != isCarried else { return }
        isCarried = carried
        lastReaction = .now
        guard carried else { return }
        if !isFlying { takeOff() }
        if root != nil, mood != .thinking, !UIAccessibility.isReduceMotionEnabled {
            restart("CuriousFeathers")
        }
    }

    /// You started rubbing her: her eyes close happily, her feathers fan,
    /// and she coos.
    func beginScratch() {
        guard !isScratched else { return }
        isScratched = true
        scratchStrokes = 0
        lastReaction = .now
        voice.startCooing()
        guard root != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        restart("HappyFeathers")
    }

    /// Where your finger is: -1 at her left, 1 at her right, as you see
    /// her. She leans into it.
    func scratch(at side: CGFloat) {
        scratchSide = Float(min(max(side, -1), 1))
    }

    /// One rub back or forth.
    func scratchStroke() {
        scratchStrokes += 1
        lastReaction = .now
        guard root != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        if !isPlaying("HappyFeathers") { restart("HappyFeathers") }
        if scratchStrokes % 12 == 0, !isFlying { restart("WingFlutter") }
    }

    func endScratch() {
        guard isScratched else { return }
        isScratched = false
        scratchSide = 0
        lastReaction = .now
        voice.stopCooing()
        guard root != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        if mood != .thinking { gesture("Delight") }
        restart("HappyFeathers")
    }

    /// A single stroke, not quite a scratch.
    func pet() {
        lastReaction = .now
        voice.coo()
        guard root != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        restart("HappyFeathers")
    }

    // MARK: Flight

    private func takeOff() {
        isFlying = true
        slowSince = nil
        guard root != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        // Quicker beats than her flutter clip: she's working to stay up.
        restart("WingFlutterLoop", speed: 1.5)
    }

    private func land() {
        isFlying = false
        slowSince = nil
        stop("WingFlutterLoop", fade: 0.35)
        guard root != nil, !UIAccessibility.isReduceMotionEnabled, mood != .thinking else { return }
        // A soft landing bounce.
        gesture("Delight")
    }

    /// She takes off when she's carried or moving fast, and lands a moment
    /// after she slows down.
    private func updateFlight(speed: CGFloat, time: CFTimeInterval) {
        if isCarried || speed > 260 {
            slowSince = nil
            if !isFlying { takeOff() }
        } else if isFlying {
            guard speed < 40 else {
                slowSince = nil
                return
            }
            if let slowSince {
                if time - slowSince > 0.25 { land() }
            } else {
                slowSince = time
            }
        }
    }

    // MARK: Motion

    /// One angle that follows its target like a soft spring: she swings a
    /// little past it and settles, like something hanging from your hand.
    private struct Sway {
        var value: Float = 0
        var speed: Float = 0

        mutating func step(toward target: Float, dt: Float) {
            speed += (70 * (target - value) - 10 * speed) * dt
            value += speed * dt
        }
    }

    private func startMotion() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: MotionTarget(view: self), selector: #selector(MotionTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
        lastPosition = nil
    }

    private func stopMotion() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Every frame: how fast she's moving on screen, what she's looking at,
    /// and what your finger is doing set how she holds herself.
    fileprivate func step(at time: CFTimeInterval) {
        guard let creature, let window else { return }
        let dt = lastTimestamp > 0 ? min(max(time - lastTimestamp, 1.0 / 240), 1.0 / 20) : 1.0 / 60
        lastTimestamp = time

        let position = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
        if let lastPosition {
            let dx = position.x - lastPosition.x
            let dy = position.y - lastPosition.y
            // A jump (the window resized or turned) isn't her moving.
            let measured = hypot(dx, dy) > 240 ? CGPoint.zero : CGPoint(x: dx / dt, y: dy / dt)
            velocity.x += (measured.x - velocity.x) * 0.35
            velocity.y += (measured.y - velocity.y) * 0.35
        }
        lastPosition = position
        let speed = hypot(velocity.x, velocity.y)
        updateFlight(speed: speed, time: time)
        flight += ((isFlying ? 1 : 0) - flight) * Float(min(1, dt * 4))

        let motion: Float = UIAccessibility.isReduceMotionEnabled ? 0 : 1
        let vx = Float(min(max(velocity.x, -2400), 2400))
        let vy = Float(min(max(velocity.y, -2400), 2400))
        let look = lookAngles(from: position, in: window, time: time)
        // Moving right, she banks right (clockwise, a negative roll) and
        // turns that way; moving down, she looks down a touch.
        let rollTarget = (-vx * 0.00015 - scratchSide * 0.16) * motion
        let yawTarget = look.yaw + (vx * 0.0001 + scratchSide * 0.28) * motion
        let pitchTarget = look.pitch + vy * 0.00007 * motion
        roll.step(toward: rollTarget, dt: Float(dt))
        yaw.step(toward: yawTarget, dt: Float(dt))
        pitch.step(toward: pitchTarget, dt: Float(dt))
        creature.eulerAngles = SCNVector3(pitch.value, yaw.value, roll.value)
        // Flying, she bobs with her wing beats. (Time stays a Double: as a
        // Float it's too coarse once the iPad has been on a while.)
        let bob = Float(sin(time * 2 * .pi * 2.2)) * 0.07 * flight * motion
        creature.position = SCNVector3(0, bob, 0)

        breatheFeathers(at: time, motion: motion)

        // Her eyes close happily while you scratch her.
        let eyesTarget: CGFloat = isScratched ? 0.85 : 0
        if eyesClosed != eyesTarget {
            eyesClosed += (eyesTarget - eyesClosed) * min(1, CGFloat(dt) * 10)
            if abs(eyesTarget - eyesClosed) < 0.01 { eyesClosed = eyesTarget }
            eyes?.morpher?.setWeight(eyesClosed, forTargetAt: 0)
        }

        // Full frame rate while anything's going on; her breathing alone
        // looks the same at 30.
        let swinging = abs(roll.speed) + abs(yaw.speed) + abs(pitch.speed) > 0.01
        let busy = isCarried || isScratched || isFlying || swinging || mood != .idle
            || speed > 5
            || Date.now.timeIntervalSince(lastReaction) < 3
        let frameRate = busy ? 60 : 30
        if sceneView.preferredFramesPerSecond != frameRate {
            sceneView.preferredFramesPerSecond = frameRate
        }
    }

    /// Where she looks: at where you just touched or wrote, if it was in
    /// the last moment and she isn't busy with your finger; otherwise a
    /// little toward the middle of the page, glancing around now and then.
    private func lookAngles(from position: CGPoint, in window: UIWindow, time: CFTimeInterval) -> (yaw: Float, pitch: Float) {
        let facing = Float(0.5 - position.x / max(window.bounds.width, 1)) * 0.45
        guard !UIAccessibility.isReduceMotionEnabled else { return (facing, 0) }
        if !isCarried, !isScratched, let gazePoint, time - gazeTime < 1.6 {
            let dx = gazePoint.x - position.x
            let dy = gazePoint.y - position.y
            let yaw = Float(atan(dx / 380)) * 0.6
            let pitch = Float(atan(dy / 380)) * 0.45
            return (min(max(yaw, -0.5), 0.5), min(max(pitch, -0.35), 0.35))
        }
        if time >= nextGlance {
            nextGlance = time + Double.random(in: 2.5...6)
            if Bool.random() {
                glance = (yaw: 0, pitch: 0)
            } else {
                glance = (yaw: Float.random(in: -0.18...0.18), pitch: Float.random(in: -0.1...0.08))
            }
        }
        return (facing + glance.yaw, glance.pitch)
    }

    /// Her long and short feathers stir slowly as she breathes, and ripple
    /// while she flies, the short ones a beat behind the long ones. Any
    /// feather clip that plays takes over from this.
    private func breatheFeathers(at time: CFTimeInterval, motion: Float) {
        let slow = Float(sin(time * 1.6))
        let slowLate = Float(sin(time * 1.6 - 0.9))
        let fast = Float(sin(time * 13))
        let fastLate = Float(sin(time * 13 - 1.1))
        let primary = (0.05 + 0.05 * slow + flight * (0.12 + 0.12 * fast)) * motion
        let covert = (0.04 + 0.04 * slowLate + flight * (0.1 + 0.1 * fastLate)) * motion
        for wing in wings {
            // Fan, Tuck, PrimaryRipple, CovertRipple.
            guard let morpher = wing.morpher, morpher.targets.count >= 4 else { continue }
            morpher.setWeight(CGFloat(primary), forTargetAt: 2)
            morpher.setWeight(CGFloat(covert), forTargetAt: 3)
        }
    }

    // MARK: Clips

    /// Plays a clip from its start. If it's already playing, the old one
    /// fades out as the new one fades in, so she never snaps back to her
    /// resting pose in between.
    private func restart(_ name: String, speed: CGFloat = 1) {
        guard let root, let clip = clips[name] else { return }
        if let key = playingKeys[name] {
            root.removeAnimation(forKey: key, blendOutDuration: 0.2)
        }
        playCount += 1
        let key = "\(name).\(playCount)"
        let player = SCNAnimationPlayer(animation: clip)
        player.speed = speed
        root.addAnimationPlayer(player, forKey: key)
        player.play()
        playingKeys[name] = key
    }

    private func stop(_ name: String, fade: TimeInterval = 0.25) {
        guard let key = playingKeys.removeValue(forKey: name) else { return }
        root?.removeAnimation(forKey: key, blendOutDuration: fade)
    }

    private func isPlaying(_ name: String) -> Bool {
        guard let key = playingKeys[name] else { return false }
        return root?.animationPlayer(forKey: key) != nil
    }

    private func duration(of name: String) -> TimeInterval {
        clips[name]?.duration ?? 0.5
    }

    private func after(_ seconds: TimeInterval, _ generation: Int, _ action: @escaping @MainActor @Sendable (StudyPalSceneView) -> Void) {
        Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard let self, self.generation == generation else { return }
            action(self)
        }
    }
}

/// Holds the scene view weakly, since a display link keeps its target alive.
@MainActor
private final class MotionTarget: NSObject {
    weak var view: StudyPalSceneView?

    init(view: StudyPalSceneView) {
        self.view = view
    }

    @objc func step(_ link: CADisplayLink) {
        view?.step(at: link.timestamp)
    }
}

/// Sees every touch in the window without taking part: it never
/// recognizes, never delays and never cancels a touch, so drawing,
/// scrolling and buttons work just as before. The study pal uses it to
/// look at where you're writing or touching.
private final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouch: ((CGPoint) -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        report(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        report(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible { state = .failed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible { state = .failed }
    }

    private func report(_ touches: Set<UITouch>) {
        guard let touch = touches.first else { return }
        onTouch?(touch.location(in: nil))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
