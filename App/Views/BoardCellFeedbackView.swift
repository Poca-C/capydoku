import UIKit

/// A transient cover keeps the already-committed full-size board drawing from
/// swallowing its own pop/stroke animation. It never intercepts a game gesture.
/// All durations are provisional Demo presentation values, not frozen timings.
final class BoardCellFeedbackView: UIView {
    enum Kind { case found, markAdded, markRemoved }
    let cellIndex: Int
    let kind: Kind
    let duration: TimeInterval
    private let reduceMotion: Bool
    private let symbol = CALayer()
    private let crossOutline = CAShapeLayer()
    private let cross = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let glow = CAGradientLayer()
    private var stars: [CAShapeLayer] = []
    private var cleanupTask: DispatchWorkItem?

    init(cellIndex: Int, kind: Kind, frame: CGRect, tileColor: UIColor, reduceMotion: Bool, errorMark: Bool = false) {
        self.cellIndex = cellIndex; self.kind = kind; self.reduceMotion = reduceMotion
        duration = reduceMotion ? 0.10 : kind == .found ? 0.32 : kind == .markAdded ? 0.16 : 0.13
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = tileColor
        layer.cornerRadius = max(3, bounds.width * 0.05)

        if kind == .found {
            if !reduceMotion { makeFoundAccents() }
            symbol.frame = bounds.insetBy(dx: bounds.width * 0.07, dy: bounds.height * 0.07)
            symbol.name = "found-face-happy"
            symbol.contents = CapyExpressionArtwork.image(.happy)?.cgImage
            symbol.contentsGravity = .resizeAspect
            layer.addSublayer(symbol)
            ring.frame = bounds.insetBy(dx: bounds.width * 0.07, dy: bounds.height * 0.07)
            ring.path = UIBezierPath(ovalIn: ring.bounds).cgPath
            ring.fillColor = UIColor.clear.cgColor
            ring.strokeColor = UIColor(CapyPalette.orange).withAlphaComponent(0.85).cgColor
            ring.lineWidth = max(2, bounds.width * 0.045)
            ring.opacity = reduceMotion ? 0.7 : 0
            layer.insertSublayer(ring, below: symbol)
        } else {
            let inset = bounds.insetBy(dx: bounds.width * 0.23, dy: bounds.height * 0.23)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: inset.minX, y: inset.minY)); path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
            path.move(to: CGPoint(x: inset.maxX, y: inset.minY)); path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
            for target in [crossOutline, cross] {
                target.frame = bounds; target.path = path.cgPath
                target.fillColor = UIColor.clear.cgColor; target.lineCap = .round
                target.lineWidth = max(3.2, bounds.width * 0.11) + (target === crossOutline ? 2 : 0)
                target.strokeColor = target === crossOutline ? UIColor(CapyPalette.markOutline).cgColor
                    : errorMark ? UIColor(CapyPalette.life).cgColor : UIColor.white.cgColor
                // For undo, the committed board is already empty. Keep that
                // final state while the presentation layer erases the X.
                target.strokeEnd = kind == .markRemoved ? 0 : 1
                layer.addSublayer(target)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func play() {
        cleanupTask?.cancel()
        if !reduceMotion {
            if kind == .found {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [0.28, 1.14, 0.96, 1]; pop.keyTimes = [0, 0.5, 0.8, 1]
                pop.duration = duration; pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
                symbol.add(pop, forKey: "found-pop")
                animate(symbol, key: "opacity", from: 0.25, to: 1, duration: 0.10)
                animate(ring, key: "opacity", from: 0.85, to: 0, duration: duration)
                animate(ring, key: "transform.scale", from: 0.55, to: 1.25, duration: duration)
                playFoundAccents()
            } else {
                for target in [crossOutline, cross] {
                    if kind == .markAdded {
                        animate(target, key: "strokeEnd", from: 0, to: 1, duration: duration)
                        animate(target, key: "transform.scale", from: 0.84, to: 1, duration: duration)
                    } else {
                        // A decreasing strokeEnd reverses the two-stroke path:
                        // the second diagonal retracts, then the first one.
                        animate(target, key: "strokeEnd", from: 1, to: 0, duration: duration)
                    }
                }
            }
        }
        let cleanup = DispatchWorkItem { [weak self] in self?.removeFromSuperview() }
        cleanupTask = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: cleanup)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            cleanupTask?.cancel(); cleanupTask = nil
            layer.removeAllAnimations()
            layer.sublayers?.forEach { $0.removeAllAnimations() }
        }
        super.willMove(toSuperview: newSuperview)
    }

    private func makeFoundAccents() {
        glow.name = "found-local-glow"
        glow.frame = bounds.insetBy(dx: bounds.width * 0.025, dy: bounds.height * 0.025)
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
        glow.colors = [UIColor(CapyPalette.orange).withAlphaComponent(0.32).cgColor,
                       UIColor(CapyPalette.orange).withAlphaComponent(0.16).cgColor,
                       UIColor(CapyPalette.orange).withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.55, 1]; glow.opacity = 0
        layer.addSublayer(glow)
        let points = [CGPoint(x: 0.16, y: 0.24), CGPoint(x: 0.77, y: 0.16),
                      CGPoint(x: 0.84, y: 0.73), CGPoint(x: 0.24, y: 0.83)]
        let side = min(10, max(3, bounds.width * 0.115))
        for (index, point) in points.enumerated() {
            let star = CAShapeLayer()
            star.name = "found-local-star-\(index)"
            star.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            star.position = CGPoint(x: bounds.width * point.x, y: bounds.height * point.y)
            let path = UIBezierPath()
            for vertex in 0..<8 {
                let angle = CGFloat(vertex) * .pi / 4 - .pi / 2
                let radius = side * (vertex.isMultiple(of: 2) ? 0.5 : 0.19)
                let point = CGPoint(x: side / 2 + cos(angle) * radius, y: side / 2 + sin(angle) * radius)
                if vertex == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.close(); star.path = path.cgPath
            star.fillColor = UIColor(index.isMultiple(of: 2) ? CapyPalette.orange : CapyPalette.paper).cgColor
            star.strokeColor = UIColor(CapyPalette.orange).withAlphaComponent(0.7).cgColor
            star.lineWidth = 0.6; star.opacity = 0; star.zPosition = 1
            layer.addSublayer(star); stars.append(star)
        }
    }

    private func playFoundAccents() {
        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [0, 1, 0]; light.keyTimes = [0, 0.32, 1]; light.duration = duration
        glow.add(light, forKey: "found-light")
        for (index, star) in stars.enumerated() {
            let visible = CAKeyframeAnimation(keyPath: "opacity")
            visible.values = [0, 1, 1, 0]
            visible.keyTimes = [0, NSNumber(value: 0.15 + Double(index) * 0.035), 0.53, 1]
            visible.duration = duration; star.add(visible, forKey: "found-sparkle")
            let travel = CABasicAnimation(keyPath: "position")
            travel.fromValue = NSValue(cgPoint: CGPoint(x: bounds.midX + (star.position.x - bounds.midX) * 0.64,
                                                       y: bounds.midY + (star.position.y - bounds.midY) * 0.64))
            travel.toValue = NSValue(cgPoint: star.position); travel.duration = duration
            travel.timingFunction = CAMediaTimingFunction(name: .easeOut)
            star.add(travel, forKey: "found-local-travel")
            animate(star, key: "transform.scale", from: 0.4, to: 1, duration: duration)
        }
    }

    private func animate(_ target: CALayer, key: String, from: CGFloat, to: CGFloat, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from; animation.toValue = to; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        target.add(animation, forKey: key)
    }
}

/// Immediate contact acknowledgement, with no recognizer delay or model write.
final class BoardPressedCellView: UIView {
    let cellIndex: Int
    init(cellIndex: Int, frame: CGRect) {
        self.cellIndex = cellIndex
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = UIColor.white.withAlphaComponent(0.26)
        layer.cornerRadius = max(3, frame.width * 0.05)
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.72).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
