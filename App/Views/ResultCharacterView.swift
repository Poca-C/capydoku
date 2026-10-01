import SwiftUI
import UIKit

enum ResultCelebrationVariant: String, CaseIterable {
    case joyfulBounce, proudCrown
}

/// Result decoration has its own event identity. Restored results pass nil;
/// buttons and gameplay never wait for this finite presentation to finish.
struct ResultCharacterView: View {
    let won: Bool
    let variant: ResultCelebrationVariant
    let size: CGFloat
    let animationID: UUID?
    var presentationEnabled = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.capyMotionOverride) private var motionOverride

    var body: some View {
        ResultCharacterBridge(won: won, variant: variant, animationID: animationID,
            reduceMotion: motionOverride ?? systemReduceMotion,
            presentationEnabled: presentationEnabled && scenePhase == .active)
            .frame(width: size, height: size)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct ResultCharacterBridge: UIViewRepresentable {
    let won: Bool
    let variant: ResultCelebrationVariant
    let animationID: UUID?
    let reduceMotion: Bool
    let presentationEnabled: Bool

    func makeUIView(context: Context) -> ResultCharacterUIView { ResultCharacterUIView() }
    func updateUIView(_ view: ResultCharacterUIView, context: Context) {
        view.configure(won: won, variant: variant, animationID: animationID,
                       reduceMotion: reduceMotion, presentationEnabled: presentationEnabled)
    }
    static func dismantleUIView(_ view: ResultCharacterUIView, coordinator: ()) { view.cancelPresentation() }
}

/// Core Animation supplies bounded, interruptible motion without a display
/// timer or a loop. The underlying model layers are always the static result.
final class ResultCharacterUIView: UIView {
    private let character = CALayer()
    private var rigLayers: [ResultRigPart: CALayer] = [:]
    private var rigReady = false
    private let prepareRig: () -> Bool
    private let groundShadow = CAShapeLayer()
    private let crown = CALayer()
    private var crownStars: [CAShapeLayer] = []
    private var wingStars: [CAShapeLayer] = []
    private var sighs: [CAShapeLayer] = []
    private let mouthOrigin = CALayer()
    private var won = true
    private var variant = ResultCelebrationVariant.joyfulBounce
    private var reduceMotion = false
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var presentationEnabled = true
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var hasAttached = false
    private var lastBounds = CGRect.zero
    private var consumedEvents = Set<UUID>()
    private var pendingEvent: UUID?
    private var generation = UUID()
    private var presentationStartTime: TimeInterval = 0
    private var cleanup: DispatchWorkItem?
    private(set) var activeEventID: UUID?
    private(set) var playedEventCount = 0
    // Host tests use the real layers with a deterministic completion clock.
    var schedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    override convenience init(frame: CGRect) {
        self.init(frame: frame, prepareRig: ResultCharacterArtwork.prewarmRig)
    }

    init(frame: CGRect, prepareRig: @escaping () -> Bool) {
        self.prepareRig = prepareRig
        super.init(frame: frame)
        isUserInteractionEnabled = false; isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = .clear; clipsToBounds = true
        groundShadow.name = "result-ground-shadow"
        groundShadow.fillColor = UIColor(CapyPalette.ink).withAlphaComponent(0.12).cgColor
        layer.addSublayer(groundShadow)
        character.name = "result-character"; character.contentsGravity = .resizeAspect
        layer.addSublayer(character)
        // Fixed depth throughout every performance: shoulder roots disappear
        // naturally behind the torso; elbows/paws never pop across a z-order swap.
        let partOrder: [ResultRigPart] = [.leftUpperArm,.rightUpperArm,.torso,.leftFoot,.rightFoot,
            .leftForearm,.rightForearm,.happyHead,.sadHead,.star,.leftPaw,.rightPaw]
        for part in partOrder {
            let piece = CALayer(); piece.name = part.layerName; piece.contentsGravity = .resize
            character.addSublayer(piece); rigLayers[part] = piece
        }
        crown.name = "result-star-crown"; layer.addSublayer(crown)
        for index in 0..<3 {
            let star = CAShapeLayer(); star.name = "result-crown-star-\(index)"
            star.fillColor = UIColor(CapyPalette.orange).cgColor
            star.strokeColor = UIColor(CapyPalette.paper).cgColor; star.lineWidth = 1
            crown.addSublayer(star); crownStars.append(star)
        }
        for index in 0..<4 {
            let star = CAShapeLayer(); star.name = "result-bounce-star-\(index)"
            star.fillColor = UIColor(index.isMultiple(of: 2) ? CapyPalette.orange : CapyPalette.paper).cgColor
            star.strokeColor = UIColor(CapyPalette.orange).cgColor; star.lineWidth = 0.8
            star.opacity = 0; layer.addSublayer(star); wingStars.append(star)
        }
        mouthOrigin.name = "result-mouth-origin"
        for index in 0..<3 {
            let sigh = CAShapeLayer(); sigh.name = "result-sigh-\(index)"
            sigh.fillColor = UIColor(CapyPalette.paper).withAlphaComponent(0.9).cgColor
            sigh.opacity = 0; mouthOrigin.addSublayer(sigh); sighs.append(sigh)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(suspend), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerStateChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        updateArtwork()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { cleanup?.cancel(); NotificationCenter.default.removeObserver(self) }

    func configure(won: Bool, variant: ResultCelebrationVariant, animationID: UUID?,
                   reduceMotion: Bool, presentationEnabled: Bool,
                   lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) {
        let appearanceChanged = self.won != won || self.variant != variant
        if appearanceChanged { cancelPresentation() }
        self.won = won; self.variant = variant; self.reduceMotion = reduceMotion
        self.presentationEnabled = presentationEnabled; self.lowPower = lowPower
        updateArtwork()
        guard let animationID else { cancelPresentation(); return }
        guard canAnimate else {
            consumedEvents.insert(animationID); cancelPresentation(); return
        }
        if let pendingEvent, pendingEvent != animationID { consumedEvents.insert(pendingEvent) }
        if activeEventID != nil && activeEventID != animationID { cancelPresentation() }
        guard !consumedEvents.contains(animationID) else { return }
        pendingEvent = animationID
        playPendingEventIfPossible()
    }

    private var canAnimate: Bool {
        presentationEnabled && applicationActive && !reduceMotion && !lowPower
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            if hasAttached { cancelPresentation() }
        } else {
            hasAttached = true
            playPendingEventIfPossible()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if lastBounds != bounds {
            if activeEventID != nil { cancelPresentation() }
            lastBounds = bounds; layoutArtwork()
        }
        playPendingEventIfPossible()
    }

    func cancelPresentation() {
        if let pendingEvent { consumedEvents.insert(pendingEvent) }
        pendingEvent = nil; activeEventID = nil; generation = UUID()
        cleanup?.cancel(); cleanup = nil
        for target in allLayers { target.removeAllAnimations() }
    }

    @objc private func suspend() { applicationActive = false; cancelPresentation() }
    @objc private func resume() { applicationActive = true /* An interrupted result is never replayed. */ }
    @objc private func powerStateChanged() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if lowPower { cancelPresentation() }
    }
    @objc private func systemMotionChanged() {
        if UIAccessibility.isReduceMotionEnabled { cancelPresentation() }
    }

    private var allLayers: [CALayer] { [layer, character, groundShadow, crown, mouthOrigin] + Array(rigLayers.values) + crownStars + wingStars + sighs }

    private var performance: ResultCharacterPerformance {
        won ? (variant == .joyfulBounce ? .joyfulRaise : .starHug) : .gentleRetry
    }

    private func updateArtwork() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rigReady = prepareRig()
        if rigReady {
            character.contents = nil
            for (part,piece) in rigLayers { piece.contents = ResultCharacterArtwork.rigImage(part)?.cgImage }
            applyRigPose(ResultRigMotion.pose(performance, phase:1))
        } else {
            // Only a missing/invalid component atlas uses the old complete art.
            // A successful rig never switches to this image at completion.
            character.contents = (ResultCharacterArtwork.poses(for: performance).last
                ?? CapyExpressionArtwork.image(won ? .happy : .neutral))?.cgImage
            for piece in rigLayers.values { piece.opacity = 0 }
        }
        crown.opacity = won && variant == .proudCrown ? 1 : 0
        layoutSighs()
        CATransaction.commit()
    }

    private func applyRigPose(_ pose: ResultRigPose) {
        for (part,piece) in rigLayers {
            guard let state = pose.parts[part] else { piece.opacity = 0; continue }
            piece.opacity = 1
            piece.bounds = CGRect(origin:.zero,size:CGSize(width:state.size.width * character.bounds.width,
                                                          height:state.size.height * character.bounds.height))
            piece.position = CGPoint(x:state.center.x * character.bounds.width, y:state.center.y * character.bounds.height)
            piece.setAffineTransform(CGAffineTransform(rotationAngle:state.rotation))
        }
    }

    private func layoutArtwork() {
        let side = min(bounds.width, bounds.height)
        let origin = CGPoint(x: bounds.midX - side / 2, y: bounds.midY - side / 2)
        func square(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat) -> CGRect {
            CGRect(x: origin.x + side * x, y: origin.y + side * y, width: side * width, height: side * width)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The articulated forearms need room for their full rotated rectangles.
        // Keep the same ground contact while leaving a margin at the cheer apex.
        // Keep squash/lean grounded at the shared foot baseline in the atlas.
        // Centre scaling made the feet float whenever an anticipation compressed.
        character.anchorPoint = CGPoint(x: 0.5, y: 0.96)
        let footprint: CGFloat = rigReady ? 0.76 : 0.80
        character.frame = square((1 - footprint) / 2, 0.898 - footprint * 0.96, footprint)
        if rigReady { applyRigPose(ResultRigMotion.pose(performance, phase:1)) }
        groundShadow.frame = CGRect(x: origin.x + side * 0.28, y: origin.y + side * 0.865, width: side * 0.44, height: side * 0.055)
        groundShadow.path = UIBezierPath(ovalIn: groundShadow.bounds).cgPath
        crown.frame = bounds
        for (index, star) in crownStars.enumerated() {
            let width: CGFloat = index == 1 ? 0.13 : 0.09
            star.frame = square(CGFloat(index) * 0.17 + 0.29 - width / 2, index == 1 ? 0.015 : 0.08, width)
            star.path = starPath(in: star.bounds).cgPath
        }
        let positions: [(CGFloat, CGFloat)] = [(0.055, 0.31), (0.10, 0.60), (0.85, 0.32), (0.83, 0.63)]
        for (index, star) in wingStars.enumerated() {
            star.frame = square(positions[index].0, positions[index].1, 0.065)
            star.path = starPath(in: star.bounds).cgPath
        }
        layoutSighs()
        CATransaction.commit()
    }

    private func layoutSighs() {
        // Marked on the actual padded sad-head cutout, at the right mouth corner.
        // A head child inherits both the nod and the whole-body motion. The
        // complete-image fallback has its own calibrated mouth location.
        let owner = rigReady ? (rigLayers[.sadHead] ?? character) : character
        let mouth = rigReady ? CGPoint(x: 0.835, y: 0.815) : CGPoint(x: 0.805, y: 0.446)
        if mouthOrigin.superlayer !== owner { owner.addSublayer(mouthOrigin) }
        mouthOrigin.position = CGPoint(x: owner.bounds.width * mouth.x, y: owner.bounds.height * mouth.y)
        let side = min(bounds.width, bounds.height)
        for (index, sigh) in sighs.enumerated() {
            let width = side * CGFloat(0.023 + Double(index) * 0.014)
            sigh.frame = CGRect(x: side * CGFloat(index) * 0.036, y: -side * CGFloat(index) * 0.022,
                                width: width, height: width)
            sigh.path = UIBezierPath(ovalIn: sigh.bounds).cgPath
        }
    }

    private func starPath(in bounds: CGRect) -> UIBezierPath {
        let path = UIBezierPath(), radius = min(bounds.width, bounds.height) / 2
        for vertex in 0..<10 {
            let angle = CGFloat(vertex) * .pi / 5 - .pi / 2
            let r = radius * (vertex.isMultiple(of: 2) ? 1 : 0.44)
            let point = CGPoint(x: bounds.midX + cos(angle) * r, y: bounds.midY + sin(angle) * r)
            if vertex == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.close(); return path
    }

    private func playPendingEventIfPossible() {
        guard let event = pendingEvent else { return }
        guard canAnimate else { consumedEvents.insert(event); cancelPresentation(); return }
        guard let window, !window.isHidden, !isHidden, alpha > 0, !bounds.isEmpty else { return }
        guard lastBounds == bounds else { setNeedsLayout(); return }
        pendingEvent = nil; consumedEvents.insert(event)
        activeEventID = event; playedEventCount += 1
        generation = UUID(); let token = generation
        presentationStartTime = CACurrentMediaTime()
        let duration = won ? (variant == .joyfulBounce ? 1.05 : 1.20) : 0.92
        playRig(duration: duration)
        if won && variant == .joyfulBounce { playBounce(duration: duration) }
        else if won { playCrown(duration: duration) }
        else { playSigh(duration: duration) }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.cancelPresentation()
        }
        cleanup = work; schedule(duration + 0.03, work)
    }

    private func playRig(duration: TimeInterval) {
        guard rigReady else { return }
        let poses = ResultRigMotion.samples(performance)
        let times = ResultRigMotion.phases.map { NSNumber(value:Double($0)) }
        for (part,piece) in rigLayers {
            let states = poses.compactMap { $0.parts[part] }
            guard states.count == poses.count else { continue }
            let position = CAKeyframeAnimation(keyPath:"position")
            position.values = states.map { NSValue(cgPoint:CGPoint(x:$0.center.x * character.bounds.width,
                                                                   y:$0.center.y * character.bounds.height)) }
            let rotation = CAKeyframeAnimation(keyPath:"transform.rotation.z")
            rotation.values = ResultRigMotion.unwrapped(states.map(\.rotation))
            for (key,animation) in [("result-rig-position",position),("result-rig-rotation",rotation)] {
                animation.keyTimes = times; animation.duration = duration
                animation.calculationMode = .linear
                animation.beginTime = piece.convertTime(presentationStartTime, from:nil)
                piece.add(animation,forKey:key)
            }
        }
    }

    private func keyframes(_ target: CALayer, key: String, values: [CGFloat], times: [NSNumber], duration: TimeInterval,
                           easing: [CAMediaTimingFunctionName]? = nil) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values; animation.keyTimes = times; animation.duration = duration
        // Ease individual phases, not the whole timeline: contents swaps must
        // stay aligned with takeoff/contact instead of a globally warped clock.
        animation.timingFunctions = (easing ?? Array(repeating: .easeInEaseOut, count: times.count - 1))
            .map { CAMediaTimingFunction(name: $0) }
        animation.beginTime = target.convertTime(presentationStartTime, from: nil)
        target.add(animation, forKey: "result-\(key)")
    }

    private func playBounce(duration: TimeInterval) {
        let side = min(bounds.width, bounds.height)
        keyframes(character, key: "transform.translation.y", values: [0, 0, -side * 0.07, 0, -side * 0.045, 0, 0],
                  times: [0, 0.12, 0.36, 0.50, 0.67, 0.84, 1], duration: duration,
                  easing: [.easeInEaseOut, .easeOut, .easeIn, .easeOut, .easeIn, .easeOut])
        let contacts: [NSNumber] = [0, 0.12, 0.23, 0.36, 0.50, 0.56, 0.60, 0.67, 0.84, 0.92, 1]
        keyframes(character, key: "transform.scale.x", values: [1, 1.025, 0.985, 0.99, 1.045, 1.015, 0.99, 0.995, 1.03, 0.995, 1],
                  times: contacts, duration: duration)
        keyframes(character, key: "transform.scale.y", values: [1, 0.95, 1.035, 1.015, 0.91, 0.97, 1.025, 1.012, 0.94, 1.005, 1],
                  times: contacts, duration: duration)
        keyframes(character, key: "transform.rotation.z", values: [0, -0.025, 0.025, -0.020, 0.016, 0],
                  times: [0, 0.12, 0.36, 0.56, 0.76, 1], duration: duration)
        keyframes(groundShadow, key: "transform.scale", values: [1, 0.70, 1.10, 0.78, 1.06, 1],
                  times: [0, 0.36, 0.50, 0.67, 0.84, 1], duration: duration)
        for (index, star) in wingStars.enumerated() {
            keyframes(star, key: "opacity", values: [0, 1, 0.4, 1, 0], times: [0, 0.34, 0.50, 0.73, 1], duration: duration)
            keyframes(star, key: "transform.rotation.z", values: [0, index < 2 ? -0.4 : 0.4, 0], times: [0, 0.55, 1], duration: duration)
            keyframes(star, key: "transform.translation.y", values: [side * 0.02, -side * 0.025, 0], times: [0, 0.55, 1], duration: duration)
        }
    }

    private func playCrown(duration: TimeInterval) {
        // The outer sway accompanies continuous hand/star joint trajectories.
        keyframes(character, key: "transform.rotation.z", values: [0, -0.065, 0.065, 0.04, -0.04, 0],
                  times: [0, 0.10, 0.34, 0.54, 0.80, 1], duration: duration)
        keyframes(character, key: "transform.scale.x", values: [1, 1.02, 0.99, 1.008, 1.015, 1],
                  times: [0, 0.10, 0.32, 0.52, 0.80, 1], duration: duration)
        keyframes(character, key: "transform.scale.y", values: [1, 0.97, 1.025, 0.99, 1.02, 1],
                  times: [0, 0.10, 0.32, 0.52, 0.80, 1], duration: duration)
        for (index, star) in crownStars.enumerated() {
            let peak = NSNumber(value: 0.20 + Double(index) * 0.08)
            keyframes(star, key: "transform.scale", values: [0.35, 1.12, 0.93, 1], times: [0, peak, 0.72, 1], duration: duration)
            keyframes(star, key: "opacity", values: [0, 1, 0.75, 1], times: [0, peak, 0.72, 1], duration: duration)
        }
    }

    private func playSigh(duration: TimeInterval) {
        let side = min(bounds.width, bounds.height)
        keyframes(character, key: "transform.rotation.z", values: [0, -0.016, 0.04, 0.04, -0.012, 0],
                  times: [0, 0.08, 0.34, 0.56, 0.87, 1], duration: duration)
        keyframes(character, key: "transform.scale.x", values: [1, 0.995, 1.025, 1.025, 0.995, 1],
                  times: [0, 0.08, 0.32, 0.56, 0.88, 1], duration: duration)
        keyframes(character, key: "transform.scale.y", values: [1, 1.01, 0.94, 0.94, 1.015, 1],
                  times: [0, 0.08, 0.32, 0.56, 0.88, 1], duration: duration)
        for (index, sigh) in sighs.enumerated() {
            keyframes(sigh, key: "opacity", values: [0, 0, 0.9, 0],
                      times: [0, NSNumber(value: 0.18 + Double(index) * 0.07), 0.58, 1], duration: duration)
            keyframes(sigh, key: "transform.translation.x", values: [0, side * 0.035], times: [0, 1], duration: duration)
            keyframes(sigh, key: "transform.translation.y", values: [0, -side * 0.025], times: [0, 1], duration: duration)
            keyframes(sigh, key: "transform.scale", values: [0.6, 1.08], times: [0, 1], duration: duration)
        }
    }
}
