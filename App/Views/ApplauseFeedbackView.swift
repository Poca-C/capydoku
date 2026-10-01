import SwiftUI
import UIKit

/// Original vector decoration for R0229-01 and Original [136, 248–250, 254].
/// Root owns the actual award and placement; this view never delays an action.
struct ApplauseFeedbackView: UIViewRepresentable {
    let eventID: UUID?
    let enabled: Bool
    let reduceMotion: Bool
    let lowPower: Bool

    func makeUIView(context: Context) -> ApplauseFeedbackUIView { ApplauseFeedbackUIView() }
    func updateUIView(_ view: ApplauseFeedbackUIView, context: Context) {
        view.configure(eventID: eventID, enabled: enabled, reduceMotion: reduceMotion, lowPower: lowPower)
    }
    static func dismantleUIView(_ view: ApplauseFeedbackUIView, coordinator: ()) { view.cancel() }
}

/// Two small rounded capybara paws, drawn locally rather than using an emoji or
/// reference artwork. All geometry and timings below are provisional Demo values.
final class ApplauseFeedbackUIView: UIView {
    private let artwork = CALayer()
    private let leftPaw = CALayer(), rightPaw = CALayer()
    private var bodies = [CAShapeLayer]()
    // Root keys this view by session ID, keeping this ledger local to one board
    // (normally at most ten finds) while rejecting every old ID from that board.
    private var consumedEvents = Set<UUID>()
    private var pendingEvent: UUID?
    private var cleanup: DispatchWorkItem?
    private var cleanupGeneration = UUID()
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var hasMounted = false
    private var hasConfigured = false
    private var enabled = false, reduceMotion = false, lowPower = false
    private(set) var activeEventID: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
        artwork.name = "applause-artwork"; artwork.opacity = 0
        artwork.bounds = CGRect(x: 0, y: 0, width: 34, height: 30)
        layer.addSublayer(artwork)
        makePaw(leftPaw, name: "applause-left", center: CGPoint(x: 9.5, y: 15), mirrored: false)
        makePaw(rightPaw, name: "applause-right", center: CGPoint(x: 24.5, y: 15), mirrored: true)
        NotificationCenter.default.addObserver(self, selector: #selector(suspend), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(policyChanged), name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(policyChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { cleanup?.cancel(); NotificationCenter.default.removeObserver(self) }

    func configure(eventID: UUID?, enabled: Bool, reduceMotion: Bool, lowPower: Bool) {
        let changedPolicy = hasConfigured && (self.reduceMotion != reduceMotion || self.lowPower != lowPower)
        hasConfigured = true
        self.enabled = enabled; self.reduceMotion = reduceMotion; self.lowPower = lowPower
        let fresh = eventID.map { consumedEvents.insert($0).inserted } ?? false
        if changedPolicy { cancel() }
        guard eventID != nil, enabled, applicationActive, !isHidden else { cancel(); return }
        guard fresh, let eventID else { return }
        cancel()
        // UIViewRepresentable can configure before its first mount. Keep only
        // that initial visible event; detached/reopened views consume old cues.
        guard window != nil || !hasMounted else { return }
        pendingEvent = eventID
        startPendingIfPossible()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        artwork.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = max(0, min(bounds.width / 34, bounds.height / 30))
        artwork.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
        startPendingIfPossible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancel() }
        else { hasMounted = true; startPendingIfPossible() }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil { cancel() }
        super.willMove(toSuperview: newSuperview)
    }

    override var isHidden: Bool { didSet { if isHidden { cancel() } } }

    func cancel() {
        cleanupGeneration = UUID(); cleanup?.cancel(); cleanup = nil
        pendingEvent = nil; activeEventID = nil
        removeAnimations(artwork)
        // The model is always transparent, including during a static outline.
        // Removing any presentation immediately reveals the untouched UI below.
    }

    private func startPendingIfPossible() {
        guard let event = pendingEvent, enabled, applicationActive, !isHidden,
              window != nil, bounds.width > 0, bounds.height > 0 else { return }
        pendingEvent = nil; activeEventID = event
        let simplified = reduceMotion || lowPower
        let duration: TimeInterval = simplified ? 0.20 : 0.56
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bodies.forEach { $0.fillColor = simplified ? UIColor.clear.cgColor : UIColor(CapyPalette.regionColors[2]).cgColor }
        CATransaction.commit()
        let now = artwork.convertTime(CACurrentMediaTime(), from: nil)
        if simplified {
            animate(artwork, key: "opacity", values: [0.9, 0.9], times: [0, 1], duration: duration, start: now)
        } else {
            animate(artwork, key: "opacity", values: [0, 1, 1, 0], times: [0, 0.12, 0.78, 1], duration: duration, start: now)
            // Two brief inward contacts, each followed by a release; no loop.
            let times: [NSNumber] = [0, 0.22, 0.42, 0.62, 0.82, 1]
            for (paw, direction) in [(leftPaw, CGFloat(1)), (rightPaw, CGFloat(-1))] {
                animate(paw, key: "transform.translation.x", values: [0, 2.7 * direction, 0.25 * direction, 2.7 * direction, 0, 0],
                        times: times, duration: duration, start: now)
                animate(paw, key: "transform.rotation.z", values: [0, 0.11 * direction, 0, 0.11 * direction, 0, 0],
                        times: times, duration: duration, start: now)
            }
        }
        let token = UUID(); cleanupGeneration = token
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.cleanupGeneration == token, self.activeEventID == event else { return }
            self.cancel()
        }
        cleanup = work; DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func makePaw(_ paw: CALayer, name: String, center: CGPoint, mirrored: Bool) {
        paw.name = name; paw.bounds = CGRect(x: 0, y: 0, width: 11, height: 18); paw.position = center
        let outline = UIBezierPath()
        outline.move(to: CGPoint(x: 3, y: 16.9))
        outline.addCurve(to: CGPoint(x: 1.2, y: 11), controlPoint1: CGPoint(x: 1.6, y: 15.8), controlPoint2: CGPoint(x: 1.1, y: 13.2))
        outline.addCurve(to: CGPoint(x: 1.2, y: 4.1), controlPoint1: CGPoint(x: 1.2, y: 8.8), controlPoint2: CGPoint(x: 0.6, y: 5.1))
        outline.addCurve(to: CGPoint(x: 3.1, y: 2.4), controlPoint1: CGPoint(x: 1.3, y: 2.5), controlPoint2: CGPoint(x: 2.1, y: 1.9))
        outline.addCurve(to: CGPoint(x: 5.5, y: 1.4), controlPoint1: CGPoint(x: 3.4, y: 0.9), controlPoint2: CGPoint(x: 4.8, y: 0.5))
        outline.addCurve(to: CGPoint(x: 8.1, y: 2.7), controlPoint1: CGPoint(x: 6.4, y: 0.8), controlPoint2: CGPoint(x: 7.9, y: 1.1))
        outline.addCurve(to: CGPoint(x: 8.7, y: 7.5), controlPoint1: CGPoint(x: 8.7, y: 3.9), controlPoint2: CGPoint(x: 8.1, y: 6.2))
        outline.addCurve(to: CGPoint(x: 10, y: 8.8), controlPoint1: CGPoint(x: 9.5, y: 6.5), controlPoint2: CGPoint(x: 10.7, y: 7.5))
        outline.addCurve(to: CGPoint(x: 8.3, y: 15.9), controlPoint1: CGPoint(x: 10.6, y: 11.1), controlPoint2: CGPoint(x: 9.5, y: 14.9))
        outline.addCurve(to: CGPoint(x: 3, y: 16.9), controlPoint1: CGPoint(x: 7.1, y: 17), controlPoint2: CGPoint(x: 4.5, y: 17.3))
        outline.close()
        let fingers = UIBezierPath()
        for x in [CGFloat(3.3), 5.6, 7.6] {
            fingers.move(to: CGPoint(x: x, y: 3.5))
            fingers.addQuadCurve(to: CGPoint(x: x + 0.05, y: 6.1), controlPoint: CGPoint(x: x + 0.35, y: 4.7))
        }
        if mirrored {
            let mirror = CGAffineTransform(translationX: 11, y: 0).scaledBy(x: -1, y: 1)
            outline.apply(mirror); fingers.apply(mirror)
        }
        for (path, filled) in [(outline, true), (fingers, false)] {
            let shape = CAShapeLayer(); shape.name = filled ? "paw-body" : "paw-finger-arcs"
            shape.frame = paw.bounds; shape.path = path.cgPath
            shape.fillColor = filled ? UIColor(CapyPalette.regionColors[2]).cgColor : UIColor.clear.cgColor
            shape.strokeColor = UIColor(CapyPalette.ink).cgColor; shape.lineWidth = filled ? 1.05 : 0.85
            shape.lineJoin = .round; shape.lineCap = .round; paw.addSublayer(shape)
            if filled { bodies.append(shape) }
        }
        artwork.addSublayer(paw)
    }

    private func animate(_ layer: CALayer, key: String, values: [CGFloat], times: [NSNumber], duration: TimeInterval, start: TimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: key); animation.values = values; animation.keyTimes = times
        animation.duration = duration; animation.beginTime = start; animation.fillMode = .backwards
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(0, values.count - 1))
        layer.add(animation, forKey: "applause-\(key)")
    }

    private func removeAnimations(_ root: CALayer) { root.removeAllAnimations(); root.sublayers?.forEach(removeAnimations) }
    @objc private func suspend() { applicationActive = false; cancel() }
    @objc private func resume() { applicationActive = true }
    @objc private func policyChanged() { cancel() }
}
