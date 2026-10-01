import UIKit

/// A transient cover keeps the already-committed full-size board drawing from
/// swallowing its own pop/stroke animation. It never intercepts a game gesture.
/// All durations are provisional Demo presentation values, not frozen timings.
final class BoardCellFeedbackView: UIView {
    enum Kind { case found, markAdded, markRemoved }
    let cellIndex: Int
    let kind: Kind
    private(set) var duration: TimeInterval
    private let reduceMotion: Bool
    private let settlesToRest: Bool
    private let accentDuration: TimeInterval
    private var startedAt: TimeInterval?
    private let symbol = CALayer()
    private let crossOutline = CAShapeLayer()
    private let cross = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var glow: CAGradientLayer?
    private var heart: CAShapeLayer?
    private var stars: [CAShapeLayer] = []
    private var fragments: [CAShapeLayer] = []
    private var cleanupTask: DispatchWorkItem?

    init(cellIndex: Int, kind: Kind, frame: CGRect, tileColor: UIColor, reduceMotion: Bool, lowPower: Bool = false, errorMark: Bool = false, localParticles: Bool = true, settlesToRest: Bool = true) {
        self.cellIndex = cellIndex; self.kind = kind; self.reduceMotion = reduceMotion
        self.settlesToRest = kind == .found && settlesToRest && !reduceMotion && !lowPower
        accentDuration = reduceMotion ? 0.10 : kind == .found ? 0.32 : kind == .markAdded ? 0.16 : 0.13
        duration = self.settlesToRest ? 0.60 : accentDuration
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = tileColor
        layer.cornerRadius = max(3, bounds.width * 0.05)

        if kind == .found {
            if !reduceMotion && !lowPower { makeFoundAccents(tileColor: tileColor, particles: localParticles) }
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
        startedAt = CACurrentMediaTime()
        if !reduceMotion {
            if kind == .found {
                playFoundPop()
                animate(symbol, key: "opacity", from: 0.25, to: 1, duration: 0.10)
                animate(ring, key: "opacity", from: 0.85, to: 0, duration: accentDuration)
                animate(ring, key: "transform.scale", from: 0.55, to: 1.25, duration: accentDuration)
                playFoundAccents()
                if settlesToRest { playExpressionSettle() }
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
        scheduleCleanup(after: duration)
    }

    private func playFoundPop() {
        // Rise from the lower part of the tile, stretch on the way up, then
        // land with a small squash and settle. A uniform zoom has no weight.
        // Every complete transformed rectangle stays inside the old 1.14x
        // envelope, including translation; reward routes keep their clearance.
        let poses: [(CGFloat, CGFloat, CGFloat)] = [
            (0.28, 0.28, 0.23), (0.93, 1.08, -0.024),
            (1.075, 0.94, 0.014), (0.985, 1.025, -0.006), (1, 1, 0)
        ]
        let pop = CAKeyframeAnimation(keyPath: "transform")
        pop.values = poses.map { x, y, lift in
            var transform = CATransform3DMakeScale(x, y, 1)
            transform.m42 = symbol.bounds.height * lift
            return NSValue(caTransform3D: transform)
        }
        pop.keyTimes = [0, 0.35, 0.64, 0.84, 1]
        pop.duration = accentDuration
        // Keep each phase on the same clock as the ring/heart; a global
        // timingFunction would warp all five authored beats together.
        pop.timingFunctions = [CAMediaTimingFunctionName.easeOut, .easeIn, .easeOut, .easeInEaseOut]
            .map { CAMediaTimingFunction(name: $0) }
        symbol.add(pop, forKey: "found-pop")
    }

    private func playExpressionSettle() {
        guard let happy = CapyExpressionArtwork.image(.happy)?.cgImage,
              let blink = CapyExpressionArtwork.image(.blink)?.cgImage,
              let neutral = CapyExpressionArtwork.image(.neutral)?.cgImage else { return }
        // A single image layer closes the smile before reopening its eyes.
        // Keep neutral visible before removing this opaque tile, so removal
        // reveals the identical board face instead of changing expression.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        symbol.contents = neutral
        let expression = CAKeyframeAnimation(keyPath: "contents")
        expression.values = [happy, blink, neutral, neutral]
        expression.keyTimes = [0, 0.70, NSNumber(value: 0.52 / 0.60), 1]
        expression.calculationMode = .discrete; expression.duration = duration
        symbol.add(expression, forKey: "found-expression-settle")
        CATransaction.commit()
    }

    /// A later find can complete the board while this earlier face is settling.
    /// Preserve only any unfinished original pop, then reveal the scene's happy
    /// face. Never cover the whole-board cheer with a late blink/neutral image.
    func handoffToCelebration() {
        guard kind == .found, let startedAt else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        symbol.removeAnimation(forKey: "found-expression-settle")
        symbol.contents = CapyExpressionArtwork.image(.happy)?.cgImage
        CATransaction.commit()
        duration = accentDuration
        let remaining = startedAt + duration - CACurrentMediaTime()
        if remaining <= 0 { removeFromSuperview() }
        else { scheduleCleanup(after: remaining) }
    }

    private func scheduleCleanup(after delay: TimeInterval) {
        cleanupTask?.cancel()
        let cleanup = DispatchWorkItem { [weak self] in self?.removeFromSuperview() }
        cleanupTask = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: cleanup)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            cleanupTask?.cancel(); cleanupTask = nil
            startedAt = nil
            layer.removeAllAnimations()
            layer.sublayers?.forEach { $0.removeAllAnimations() }
        }
        super.willMove(toSuperview: newSuperview)
    }

    private func makeFoundAccents(tileColor: UIColor, particles: Bool) {
        let glow = CAGradientLayer()
        self.glow = glow
        glow.name = "found-local-glow"
        glow.frame = bounds.insetBy(dx: bounds.width * 0.025, dy: bounds.height * 0.025)
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
        glow.colors = [UIColor(CapyPalette.orange).withAlphaComponent(0.32).cgColor,
                       UIColor(CapyPalette.orange).withAlphaComponent(0.16).cgColor,
                       UIColor(CapyPalette.orange).withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.55, 1]; glow.opacity = 0
        layer.addSublayer(glow)
        // OBS-02/03: a small affection heart, colored sparkles and confetti
        // matching this region. These are original vectors, not copied assets.
        let points: [CGPoint] = particles ? [CGPoint(x: 0.17, y: 0.18), CGPoint(x: 0.86, y: 0.43),
                      CGPoint(x: 0.71, y: 0.84), CGPoint(x: 0.15, y: 0.73)] : []
        let colors = [2, 4, 8, 9].map { UIColor(CapyPalette.regionColors[$0]) }
        let side = min(9, max(2.5, bounds.width * 0.105))
        for (index, point) in points.enumerated() {
            let star = CAShapeLayer()
            star.name = "found-local-star-\(index)"
            star.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            star.position = bounded(CGPoint(x: bounds.width * point.x, y: bounds.height * point.y), margin: side / 2 + 0.7)
            let path = UIBezierPath()
            for vertex in 0..<8 {
                let angle = CGFloat(vertex) * .pi / 4 - .pi / 2
                let radius = side * (vertex.isMultiple(of: 2) ? 0.5 : 0.19)
                let point = CGPoint(x: side / 2 + cos(angle) * radius, y: side / 2 + sin(angle) * radius)
                if vertex == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.close(); star.path = path.cgPath
            star.fillColor = colors[index].cgColor
            star.strokeColor = UIColor(CapyPalette.paper).cgColor
            star.lineWidth = 0.6; star.opacity = 0; star.zPosition = 1
            layer.addSublayer(star); stars.append(star)
        }
        let fragmentPoints: [CGPoint] = particles ? [CGPoint(x: 0.12, y: 0.42), CGPoint(x: 0.41, y: 0.14),
                              CGPoint(x: 0.86, y: 0.76), CGPoint(x: 0.39, y: 0.87)] : []
        let fragmentSide = min(7, max(2.5, bounds.width * 0.075))
        for (index, point) in fragmentPoints.enumerated() {
            let fragment = CAShapeLayer(); fragment.name = "found-region-fragment-\(index)"
            fragment.bounds = CGRect(x: 0, y: 0, width: fragmentSide * 0.66, height: fragmentSide)
            let radius = hypot(fragment.bounds.width, fragment.bounds.height) / 2 + 0.7
            fragment.position = bounded(CGPoint(x: bounds.width * point.x, y: bounds.height * point.y), margin: radius)
            fragment.path = UIBezierPath(roundedRect: fragment.bounds.insetBy(dx: 0.3, dy: 0.3), cornerRadius: 0.6).cgPath
            fragment.fillColor = tileColor.cgColor
            fragment.strokeColor = UIColor(CapyPalette.markOutline).withAlphaComponent(0.5).cgColor
            fragment.lineWidth = 0.6; fragment.opacity = 0; fragment.zPosition = 1
            layer.addSublayer(fragment); fragments.append(fragment)
        }
        let heartSide = min(14, max(4, bounds.width * 0.21))
        let heart = CAShapeLayer()
        self.heart = heart
        heart.name = "found-local-heart"
        heart.bounds = CGRect(x: 0, y: 0, width: heartSide, height: heartSide)
        heart.position = bounded(CGPoint(x: bounds.width * 0.74, y: bounds.height * 0.18), margin: heartSide * 0.54 + 0.7)
        let heartPath = UIBezierPath()
        heartPath.move(to: CGPoint(x: 0.5, y: 0.91))
        heartPath.addCurve(to: CGPoint(x: 0.07, y: 0.37), controlPoint1: CGPoint(x: 0.33, y: 0.76), controlPoint2: CGPoint(x: 0.07, y: 0.56))
        heartPath.addCurve(to: CGPoint(x: 0.5, y: 0.25), controlPoint1: CGPoint(x: 0.07, y: 0.10), controlPoint2: CGPoint(x: 0.37, y: 0.08))
        heartPath.addCurve(to: CGPoint(x: 0.93, y: 0.37), controlPoint1: CGPoint(x: 0.63, y: 0.08), controlPoint2: CGPoint(x: 0.93, y: 0.10))
        heartPath.addCurve(to: CGPoint(x: 0.5, y: 0.91), controlPoint1: CGPoint(x: 0.93, y: 0.56), controlPoint2: CGPoint(x: 0.67, y: 0.76))
        heartPath.close(); heartPath.apply(CGAffineTransform(scaleX: heartSide, y: heartSide))
        heart.path = heartPath.cgPath
        // Soft pink and an intact silhouette separate affection from the red,
        // split-heart loss signal. This never changes the HUD life count.
        heart.fillColor = UIColor(CapyPalette.regionColors[9]).cgColor
        heart.strokeColor = UIColor(CapyPalette.paper).cgColor; heart.lineWidth = 0.9
        heart.opacity = 0; heart.zPosition = 2; layer.addSublayer(heart)
    }

    private func playFoundAccents() {
        guard let glow, let heart else { return }
        let light = CAKeyframeAnimation(keyPath: "opacity")
        light.values = [0, 1, 0]; light.keyTimes = [0, 0.32, 1]; light.duration = accentDuration
        glow.add(light, forKey: "found-light")
        for (index, star) in stars.enumerated() {
            let visible = CAKeyframeAnimation(keyPath: "opacity")
            visible.values = [0, 1, 1, 0]
            visible.keyTimes = [0, NSNumber(value: 0.15 + Double(index) * 0.035), 0.53, 1]
            visible.duration = accentDuration; star.add(visible, forKey: "found-sparkle")
            let travel = CABasicAnimation(keyPath: "position")
            travel.fromValue = NSValue(cgPoint: CGPoint(x: bounds.midX + (star.position.x - bounds.midX) * 0.64,
                                                       y: bounds.midY + (star.position.y - bounds.midY) * 0.64))
            travel.toValue = NSValue(cgPoint: star.position); travel.duration = accentDuration
            travel.timingFunction = CAMediaTimingFunction(name: .easeOut)
            star.add(travel, forKey: "found-local-travel")
            animate(star, key: "transform.scale", from: 0.4, to: 1, duration: accentDuration)
        }
        for (index, fragment) in fragments.enumerated() {
            let visible = CAKeyframeAnimation(keyPath: "opacity")
            visible.values = [0, 1, 0.9, 0]; visible.keyTimes = [0, 0.19, 0.58, 1]
            visible.duration = accentDuration; fragment.add(visible, forKey: "found-fragment-visible")
            let travel = CABasicAnimation(keyPath: "position")
            let radius = hypot(fragment.bounds.width, fragment.bounds.height) / 2 + 0.7
            let start = bounded(CGPoint(x: bounds.midX + (fragment.position.x - bounds.midX) * 0.55,
                                        y: bounds.midY + (fragment.position.y - bounds.midY) * 0.55), margin: radius)
            travel.fromValue = NSValue(cgPoint: start); travel.toValue = NSValue(cgPoint: fragment.position)
            travel.duration = accentDuration; travel.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fragment.add(travel, forKey: "found-fragment-travel")
            let direction: CGFloat = index.isMultiple(of: 2) ? -1 : 1
            animate(fragment, key: "transform.rotation.z", from: direction * 0.15, to: direction * 1.1, duration: accentDuration)
        }
        let affection = CAKeyframeAnimation(keyPath: "opacity")
        affection.values = [0, 0, 1, 1, 0]; affection.keyTimes = [0, 0.13, 0.32, 0.68, 1]
        affection.duration = accentDuration; heart.add(affection, forKey: "found-heart-visible")
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.48, 1.08, 1, 0.92]; pop.keyTimes = [0, 0.4, 0.68, 1]
        pop.duration = accentDuration; heart.add(pop, forKey: "found-heart-pop")
        let float = CABasicAnimation(keyPath: "position")
        float.fromValue = NSValue(cgPoint: bounded(CGPoint(x: heart.position.x, y: heart.position.y + min(5, bounds.height * 0.10)),
                                                   margin: heart.bounds.width * 0.54 + 0.7))
        float.toValue = NSValue(cgPoint: heart.position); float.duration = accentDuration
        float.timingFunction = CAMediaTimingFunction(name: .easeOut)
        heart.add(float, forKey: "found-heart-lift")
    }

    private func bounded(_ point: CGPoint, margin: CGFloat) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX + margin), bounds.maxX - margin),
                y: min(max(point.y, bounds.minY + margin), bounds.maxY - margin))
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
