import SwiftUI
import UIKit

/// Finite, bounded celebration around the character. No timers redraw the
/// screen, no particles intercept taps, and a restored result stays still.
struct ResultAtmosphereView: UIViewRepresentable {
    let won: Bool
    let eventID: UUID?
    let enabled: Bool
    let reduceMotion: Bool
    func makeUIView(context: Context) -> ResultAtmosphereUIView { ResultAtmosphereUIView() }
    func updateUIView(_ view: ResultAtmosphereUIView, context: Context) {
        view.configure(won: won, eventID: eventID, enabled: enabled, reduceMotion: reduceMotion)
    }
    static func dismantleUIView(_ view: ResultAtmosphereUIView, coordinator: ()) { view.cancel() }
}

final class ResultAtmosphereUIView: UIView {
    private let glow = CAGradientLayer()
    private let rays = CAShapeLayer()
    private var particles: [CAShapeLayer] = []
    private var consumed = Set<UUID>()
    private var pending: UUID?
    private var cleanup: DispatchWorkItem?
    private var generation = UUID()
    private var enabled = false
    private var won = false
    private var reduceMotion = false
    private var appActive = UIApplication.shared.applicationState == .active
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var attached = false
    private var previousBounds = CGRect.zero
    private(set) var activeEventID: UUID?
    private(set) var playedEvents = 0
    var particleCount: Int { particles.count }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; accessibilityElementsHidden = true; clipsToBounds = true
        glow.type = .radial; glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
        glow.locations = [0, 0.48, 1]; layer.addSublayer(glow)
        rays.fillColor = UIColor(CapyPalette.orangeLight).withAlphaComponent(0.10).cgColor
        layer.addSublayer(rays)
        let colors = [UIColor(CapyPalette.orange), UIColor(CapyPalette.paper), UIColor(red: 0.63, green: 0.86, blue: 0.70, alpha: 1), UIColor(red: 1, green: 0.61, blue: 0.44, alpha: 1)]
        for index in 0..<28 {
            let part = CAShapeLayer(); part.name = "result-confetti-\(index)"
            part.fillColor = colors[index % colors.count].cgColor; part.opacity = 0
            let size: CGFloat = index.isMultiple(of: 3) ? 7 : 5
            part.bounds = CGRect(x: 0, y: 0, width: size, height: size * 1.55)
            part.path = UIBezierPath(roundedRect: part.bounds, cornerRadius: 1.8).cgPath
            layer.addSublayer(part); particles.append(part)
        }
        for name in [UIApplication.willResignActiveNotification, .NSProcessInfoPowerStateDidChange, UIAccessibility.reduceMotionStatusDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(suspend(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { cleanup?.cancel(); NotificationCenter.default.removeObserver(self) }

    func configure(won: Bool, eventID: UUID?, enabled: Bool, reduceMotion: Bool) {
        self.won = won; self.enabled = enabled; self.reduceMotion = reduceMotion
        updateStaticArtwork()
        guard let eventID else { cancel(); return }
        guard enabled && won && !reduceMotion && !lowPower && appActive else {
            consumed.insert(eventID); cancel(); return
        }
        guard !consumed.contains(eventID) else { return }
        if pending != eventID { cancel(); pending = eventID }
        playIfReady()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds != previousBounds {
            if activeEventID != nil { cancel() }
            previousBounds = bounds; updateStaticArtwork()
        }
        playIfReady()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { attached = true; playIfReady() }
        else if attached { cancel() }
    }
    private func updateStaticArtwork() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds
        glow.colors = [UIColor(CapyPalette.orangeLight).withAlphaComponent(won ? 0.36 : 0.10).cgColor,
                       UIColor(CapyPalette.orange).withAlphaComponent(won ? 0.12 : 0.035).cgColor, UIColor.clear.cgColor]
        rays.frame = bounds; rays.isHidden = !won || reduceMotion || lowPower
        let center = CGPoint(x: bounds.midX, y: bounds.midY), radius = max(bounds.width, bounds.height) * 0.62
        let path = UIBezierPath()
        for index in 0..<12 {
            let angle = Double(index) * .pi / 6
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + cos(angle - 0.055) * radius, y: center.y + sin(angle - 0.055) * radius))
            path.addLine(to: CGPoint(x: center.x + cos(angle + 0.055) * radius, y: center.y + sin(angle + 0.055) * radius))
            path.close()
        }
        rays.path = path.cgPath
        CATransaction.commit()
    }
    private func playIfReady() {
        guard let event = pending, let window, !window.isHidden, !bounds.isEmpty, enabled, won,
              appActive, !reduceMotion, !lowPower else { return }
        pending = nil; consumed.insert(event); activeEventID = event; playedEvents += 1
        generation = UUID(); let token = generation
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = -0.14; turn.toValue = 0; turn.duration = 1.4
        turn.timingFunction = CAMediaTimingFunction(name: .easeOut); rays.add(turn, forKey: "sunrise")
        for (index, particle) in particles.enumerated() {
            let left = index.isMultiple(of: 2), fraction = Double(index / 2) / 13
            let origin = CGPoint(x: center.x + (left ? -18 : 18), y: center.y + 18)
            let end = CGPoint(x: bounds.width * (left ? 0.08 + fraction * 0.25 : 0.92 - fraction * 0.25),
                              y: bounds.height * (0.46 + fraction * 0.49))
            let control = CGPoint(x: bounds.width * (left ? 0.01 + fraction * 0.24 : 0.99 - fraction * 0.24),
                                  y: bounds.height * (0.02 + fraction * 0.15))
            particle.position = end
            let path = UIBezierPath(); path.move(to: origin); path.addQuadCurve(to: end, controlPoint: control)
            let travel = CAKeyframeAnimation(keyPath: "position"); travel.path = path.cgPath
            let visible = CAKeyframeAnimation(keyPath: "opacity"); visible.values = [0, 1, 1, 0]; visible.keyTimes = [0, 0.08, 0.68, 1]
            let spin = CABasicAnimation(keyPath: "transform.rotation.z"); spin.fromValue = 0; spin.toValue = left ? -4.5 : 4.5
            let group = CAAnimationGroup(); group.animations = [travel, visible, spin]; group.duration = 1.2
            group.beginTime = CACurrentMediaTime() + Double(index % 5) * 0.035
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            particle.add(group, forKey: "confetti")
        }
        let work = DispatchWorkItem { [weak self] in
            guard self?.generation == token else { return }; self?.cancel()
        }
        cleanup = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
    func cancel() {
        if let pending { consumed.insert(pending) }
        pending = nil; activeEventID = nil; generation = UUID(); cleanup?.cancel(); cleanup = nil
        rays.removeAllAnimations(); particles.forEach { $0.removeAllAnimations() }
    }
    @objc private func suspend(_ notification: Notification) {
        if notification.name == UIApplication.willResignActiveNotification { appActive = false }
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if !appActive || lowPower || UIAccessibility.isReduceMotionEnabled { cancel() }
        updateStaticArtwork()
    }
    @objc private func resume() { appActive = true }
}
