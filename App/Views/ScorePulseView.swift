import SwiftUI
import UIKit

/// Original [127, 136, 252, 254]: commit the number immediately; a finite
/// acknowledgement must neither wait for another effect nor hold up input.
struct ScorePulseView: UIViewRepresentable {
    let score: Int
    let sessionID: UUID
    let pulseID: UUID?
    let fontSize: CGFloat
    let reduceMotion: Bool
    let presentationEnabled: Bool

    func makeUIView(context: Context) -> ScorePulseLabel { ScorePulseLabel() }
    func updateUIView(_ view: ScorePulseLabel, context: Context) {
        view.configure(score: score, sessionID: sessionID, pulseID: pulseID,
                       fontSize: fontSize, reduceMotion: reduceMotion,
                       presentationEnabled: presentationEnabled)
    }
}

/// One replaceable Core Animation pulse, with an identity model transform.
/// Retriggering samples the current visible scale; no delayed reset can cancel
/// a newer award and no animation completion owns the displayed score.
final class ScorePulseLabel: UILabel {
    static let animationKey = "score-award-pulse"
    private var sessionID: UUID?
    private var lastPulseID: UUID?
    private var applicationActive = UIApplication.shared.applicationState == .active

    override init(frame: CGRect) {
        super.init(frame: frame)
        textAlignment = .center
        textColor = UIColor(CapyPalette.ink)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "score"
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NotificationCenter.default.addObserver(self, selector: #selector(suspend), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(score: Int, sessionID: UUID, pulseID: UUID?, fontSize: CGFloat,
                   reduceMotion: Bool, presentationEnabled: Bool,
                   lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) {
        // Font/text update synchronously, including while all motion is gated.
        text = String(score)
        let base = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: fontSize) } ?? base
        let sameSession = self.sessionID == sessionID
        let newPulse = pulseID != nil && lastPulseID != pulseID
        self.sessionID = sessionID
        if let pulseID { lastPulseID = pulseID }
        // First mount/restoration, covered updates and detached views consume
        // their snapshot. Becoming visible again never replays an old award.
        guard sameSession, pulseID != nil, presentationEnabled, applicationActive,
              !reduceMotion, !lowPower, window != nil else {
            cancelPulse()
            return
        }
        guard newPulse else { return }
        playPulse()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelPulse() }
    }

    private func playPulse() {
        let current = CGFloat(layer.presentation()?.transform.m11 ?? 1)
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        // A brief release before the peak makes a second award recognizable
        // even when it arrives at the preceding pulse's maximum size.
        pulse.values = [max(0.98, min(1.12, current)), 0.99, 1.12, 0.99, 1]
        pulse.keyTimes = [0, 0.10, 0.38, 0.75, 1]
        pulse.timingFunctions = [.init(name: .easeOut), .init(name: .easeOut),
                                 .init(name: .easeInEaseOut), .init(name: .easeOut)]
        pulse.duration = 0.32
        pulse.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.add(pulse, forKey: Self.animationKey)
    }

    private func cancelPulse() {
        layer.removeAnimation(forKey: Self.animationKey)
        // The animation never modifies the model layer, so removal and normal
        // completion both restore the original size without another timer.
    }

    @objc private func suspend() { applicationActive = false; cancelPulse() }
    @objc private func resume() { applicationActive = true }
    @objc private func powerChanged() {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { cancelPulse() }
    }
    @objc private func motionChanged() {
        if UIAccessibility.isReduceMotionEnabled { cancelPulse() }
    }
}
