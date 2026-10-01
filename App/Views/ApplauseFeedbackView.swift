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
    private let contactAccent = CAShapeLayer()
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
        // A small accent at the shared contact makes the two inward beats
        // readable at actual phone size, without increasing the view's frame.
        contactAccent.name = "applause-contact-accent"; contactAccent.frame = artwork.bounds
        let accent = UIBezierPath()
        for (start, end) in [(CGPoint(x: 13.5, y: 4.2), CGPoint(x: 11.8, y: 2)),
                             (CGPoint(x: 17, y: 3.5), CGPoint(x: 17, y: 1)),
                             (CGPoint(x: 20.5, y: 4.2), CGPoint(x: 22.2, y: 2))] {
            accent.move(to: start); accent.addLine(to: end)
        }
        contactAccent.path = accent.cgPath; contactAccent.fillColor = UIColor.clear.cgColor
        contactAccent.strokeColor = UIColor(CapyPalette.actionOrange).cgColor
        contactAccent.lineWidth = 1.4; contactAccent.lineCap = .round; contactAccent.opacity = 0
        artwork.addSublayer(contactAccent)
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
        bodies.forEach { $0.fillColor = simplified ? UIColor.clear.cgColor : UIColor(CapyPalette.orangeLight).cgColor }
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
            animate(contactAccent, key: "opacity", values: [0, 0, 1, 1, 0, 0, 1, 1, 0, 0],
                    times: [0, 0.12, 0.18, 0.27, 0.35, 0.52, 0.58, 0.67, 0.75, 1], duration: duration, start: now)
        }
        let token = UUID(); cleanupGeneration = token
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.cleanupGeneration == token, self.activeEventID == event else { return }
            self.cancel()
        }
        cleanup = work; DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func makePaw(_ paw: CALayer, name: String, center: CGPoint, mirrored: Bool) {
        paw.name = name; paw.bounds = CGRect(x: 0, y: 0, width: 13, height: 22); paw.position = center
        let outline = UIBezierPath()
        outline.move(to: CGPoint(x: 3.2, y: 21))
        outline.addCurve(to: CGPoint(x: 1, y: 16), controlPoint1: CGPoint(x: 1.8, y: 20.2), controlPoint2: CGPoint(x: 1, y: 18))
        outline.addLine(to: CGPoint(x: 0.8, y: 6))
        outline.addCurve(to: CGPoint(x: 3.3, y: 3.8), controlPoint1: CGPoint(x: 0.65, y: 4.1), controlPoint2: CGPoint(x: 2.3, y: 3))
        outline.addCurve(to: CGPoint(x: 6.3, y: 2.1), controlPoint1: CGPoint(x: 3.5, y: 1.1), controlPoint2: CGPoint(x: 5.3, y: 0.5))
        outline.addCurve(to: CGPoint(x: 9.1, y: 3.6), controlPoint1: CGPoint(x: 7.6, y: 1.3), controlPoint2: CGPoint(x: 9.2, y: 1.8))
        outline.addCurve(to: CGPoint(x: 10, y: 10.2), controlPoint1: CGPoint(x: 10, y: 4.7), controlPoint2: CGPoint(x: 9.5, y: 8.1))
        outline.addCurve(to: CGPoint(x: 12.4, y: 10.9), controlPoint1: CGPoint(x: 11, y: 8.6), controlPoint2: CGPoint(x: 13.4, y: 9.1))
        outline.addCurve(to: CGPoint(x: 11, y: 17.3), controlPoint1: CGPoint(x: 13.1, y: 13), controlPoint2: CGPoint(x: 12, y: 16.1))
        outline.addCurve(to: CGPoint(x: 8.6, y: 20.6), controlPoint1: CGPoint(x: 10.5, y: 19), controlPoint2: CGPoint(x: 9.7, y: 20))
        outline.addCurve(to: CGPoint(x: 3.2, y: 21), controlPoint1: CGPoint(x: 7.3, y: 21.4), controlPoint2: CGPoint(x: 4.6, y: 21.6))
        outline.close()
        let fingers = UIBezierPath()
        for (x, y) in [(CGFloat(3.5), CGFloat(4.2)), (6.3, 2.8), (8.8, 4.4)] {
            fingers.move(to: CGPoint(x: x, y: y))
            fingers.addQuadCurve(to: CGPoint(x: x + 0.15, y: 8.2), controlPoint: CGPoint(x: x + 0.45, y: 6))
        }
        fingers.move(to: CGPoint(x: 10, y: 10.2))
        fingers.addQuadCurve(to: CGPoint(x: 8.6, y: 14), controlPoint: CGPoint(x: 8.1, y: 11.1))
        if mirrored {
            let mirror = CGAffineTransform(translationX: 13, y: 0).scaledBy(x: -1, y: 1)
            outline.apply(mirror); fingers.apply(mirror)
        }
        for (path, filled) in [(outline, true), (fingers, false)] {
            let shape = CAShapeLayer(); shape.name = filled ? "paw-body" : "paw-finger-arcs"
            shape.frame = paw.bounds; shape.path = path.cgPath
            shape.fillColor = filled ? UIColor(CapyPalette.orangeLight).cgColor : UIColor.clear.cgColor
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
