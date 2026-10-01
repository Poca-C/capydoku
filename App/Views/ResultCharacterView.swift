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
    private let groundShadow = CAShapeLayer()
    private let crown = CALayer()
    private var crownStars: [CAShapeLayer] = []
    private var wingStars: [CAShapeLayer] = []
    private var sighs: [CAShapeLayer] = []
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
    private var cleanup: DispatchWorkItem?
    private(set) var activeEventID: UUID?
    private(set) var playedEventCount = 0
    // Host tests use the real layers with a deterministic completion clock.
    var schedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = .clear; clipsToBounds = true
        groundShadow.name = "result-ground-shadow"
        groundShadow.fillColor = UIColor(CapyPalette.ink).withAlphaComponent(0.12).cgColor
        layer.addSublayer(groundShadow)
        character.name = "result-character"; character.contentsGravity = .resizeAspect
        layer.addSublayer(character)
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
        for index in 0..<3 {
            let sigh = CAShapeLayer(); sigh.name = "result-sigh-\(index)"
            sigh.fillColor = UIColor(CapyPalette.paper).withAlphaComponent(0.9).cgColor
            sigh.opacity = 0; layer.addSublayer(sigh); sighs.append(sigh)
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

    private var allLayers: [CALayer] { [layer, character, groundShadow, crown] + crownStars + wingStars + sighs }

    private var performance: ResultCharacterPerformance {
        won ? (variant == .joyfulBounce ? .joyfulRaise : .starHug) : .gentleRetry
    }

    private func updateArtwork() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        character.contents = (ResultCharacterArtwork.poses(for: performance).last
            ?? CapyExpressionArtwork.image(won ? .happy : .neutral))?.cgImage
        crown.opacity = won && variant == .proudCrown ? 1 : 0
        CATransaction.commit()
    }

    private func layoutArtwork() {
        let side = min(bounds.width, bounds.height)
        let origin = CGPoint(x: bounds.midX - side / 2, y: bounds.midY - side / 2)
        func square(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat) -> CGRect {
            CGRect(x: origin.x + side * x, y: origin.y + side * y, width: side * width, height: side * width)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Motion uses the spare margin around this 80% character footprint.
        character.frame = square(0.10, 0.13, 0.80)
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
        for (index, sigh) in sighs.enumerated() {
            let width = CGFloat(0.023 + Double(index) * 0.014)
            sigh.frame = square(0.77 + CGFloat(index) * 0.036, 0.48 - CGFloat(index) * 0.022, width)
            sigh.path = UIBezierPath(ovalIn: sigh.bounds).cgPath
        }
        CATransaction.commit()
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
        let duration = won ? (variant == .joyfulBounce ? 1.05 : 1.20) : 0.92
        playPoses(duration: duration)
        if won && variant == .joyfulBounce { playBounce(duration: duration) }
        else if won { playCrown(duration: duration) }
        else { playSigh(duration: duration) }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.cancelPresentation()
        }
        cleanup = work; schedule(duration + 0.03, work)
    }

    private func playPoses(duration: TimeInterval) {
        let poses = ResultCharacterArtwork.poses(for: performance)
        guard poses.count == 3 else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = performance.poseIndices.compactMap { poses[$0].cgImage }
        animation.keyTimes = performance.poseTimes
        animation.calculationMode = .discrete
        animation.duration = duration
        character.add(animation, forKey: "result-pose-sequence")
    }

    private func keyframes(_ target: CALayer, key: String, values: [CGFloat], times: [NSNumber], duration: TimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values; animation.keyTimes = times; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(animation, forKey: "result-\(key)")
    }

    private func playBounce(duration: TimeInterval) {
        let side = min(bounds.width, bounds.height)
        keyframes(character, key: "transform.translation.y", values: [0, 2, -side * 0.07, 0, -side * 0.045, 0, 0],
                  times: [0, 0.10, 0.27, 0.43, 0.61, 0.78, 1], duration: duration)
        keyframes(character, key: "transform.scale", values: [1, 0.97, 1.03, 0.97, 1.02, 1, 1],
                  times: [0, 0.10, 0.27, 0.43, 0.61, 0.78, 1], duration: duration)
        keyframes(character, key: "transform.rotation.z", values: [0, -0.055, 0.055, -0.04, 0.035, 0],
                  times: [0, 0.23, 0.42, 0.61, 0.78, 1], duration: duration)
        keyframes(groundShadow, key: "transform.scale", values: [1, 0.70, 1, 0.78, 1],
                  times: [0, 0.27, 0.43, 0.61, 1], duration: duration)
        for (index, star) in wingStars.enumerated() {
            keyframes(star, key: "opacity", values: [0, 1, 0.4, 1, 0], times: [0, 0.24, 0.43, 0.67, 1], duration: duration)
            keyframes(star, key: "transform.rotation.z", values: [0, index < 2 ? -0.4 : 0.4, 0], times: [0, 0.55, 1], duration: duration)
            keyframes(star, key: "transform.translation.y", values: [side * 0.02, -side * 0.025, 0], times: [0, 0.55, 1], duration: duration)
        }
    }

    private func playCrown(duration: TimeInterval) {
        keyframes(character, key: "transform.rotation.z", values: [0, -0.085, 0.085, -0.04, 0.025, 0],
                  times: [0, 0.20, 0.44, 0.64, 0.81, 1], duration: duration)
        keyframes(character, key: "transform.scale", values: [1, 1.035, 1.02, 1], times: [0, 0.24, 0.72, 1], duration: duration)
        for (index, star) in crownStars.enumerated() {
            let peak = NSNumber(value: 0.20 + Double(index) * 0.08)
            keyframes(star, key: "transform.scale", values: [0.35, 1.12, 0.93, 1], times: [0, peak, 0.72, 1], duration: duration)
            keyframes(star, key: "opacity", values: [0, 1, 0.75, 1], times: [0, peak, 0.72, 1], duration: duration)
        }
    }

    private func playSigh(duration: TimeInterval) {
        let side = min(bounds.width, bounds.height)
        keyframes(character, key: "transform.translation.y", values: [0, side * 0.022, side * 0.022, 0],
                  times: [0, 0.28, 0.70, 1], duration: duration)
        keyframes(character, key: "transform.rotation.z", values: [0, 0.04, -0.025, 0.022, 0],
                  times: [0, 0.23, 0.43, 0.63, 1], duration: duration)
        keyframes(character, key: "transform.scale.y", values: [1, 0.97, 0.97, 1], times: [0, 0.28, 0.70, 1], duration: duration)
        for (index, sigh) in sighs.enumerated() {
            keyframes(sigh, key: "opacity", values: [0, 0, 0.9, 0],
                      times: [0, NSNumber(value: 0.18 + Double(index) * 0.07), 0.58, 1], duration: duration)
            keyframes(sigh, key: "transform.translation.x", values: [0, side * 0.035], times: [0, 1], duration: duration)
            keyframes(sigh, key: "transform.translation.y", values: [0, -side * 0.025], times: [0, 1], duration: duration)
            keyframes(sigh, key: "transform.scale", values: [0.6, 1.08], times: [0, 1], duration: duration)
        }
    }
}
