import UIKit

/// Original paragraph 129: shaking capybara, tearing heart, then a red X.
/// Timing is a short Demo presentation, pending the frozen reference recording.
/// The persisted board owns the final X; this view never changes game state.
final class BoardMistakeFeedbackView: UIView {
    let cellIndex: Int
    private let reduceMotion: Bool
    private let presentation = CALayer()
    private let cellRim = CAShapeLayer()
    private let face = CALayer()
    private let leftHeart = CAShapeLayer()
    private let rightHeart = CAShapeLayer()
    private let crossOutline = CAShapeLayer()
    private let cross = CAShapeLayer()
    private var transitionTask: DispatchWorkItem?
    private var cleanupTask: DispatchWorkItem?

    init(cellIndex: Int, frame: CGRect, tileColor: UIColor, reduceMotion: Bool) {
        self.cellIndex = cellIndex
        self.reduceMotion = reduceMotion
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = tileColor
        layer.cornerRadius = max(3, frame.width * 0.05)
        // Keep this opaque tile fixed even while its contents shake, so the
        // already-committed underlying X cannot flash through a moving edge.
        presentation.frame = bounds
        layer.addSublayer(presentation)
        cellRim.frame = bounds
        cellRim.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: layer.cornerRadius).cgPath
        cellRim.fillColor = UIColor.clear.cgColor
        cellRim.strokeColor = UIColor(CapyPalette.markOutline).withAlphaComponent(0.35).cgColor
        cellRim.lineWidth = 1.2; cellRim.opacity = 0
        presentation.addSublayer(cellRim)

        face.frame = bounds.insetBy(dx: bounds.width * 0.07, dy: bounds.height * 0.07)
        face.name = "mistake-face-startled"
        face.contents = CapyExpressionArtwork.image(.startled)?.cgImage
        face.contentsGravity = .resizeAspect
        face.opacity = 0
        presentation.addSublayer(face)

        let heartRect = bounds.insetBy(dx: bounds.width * 0.18, dy: bounds.height * 0.18)
        let heart = UIBezierPath()
        heart.move(to: CGPoint(x: 0.5, y: 0.93))
        heart.addCurve(to: CGPoint(x: 0.06, y: 0.38), controlPoint1: CGPoint(x: 0.39, y: 0.79), controlPoint2: CGPoint(x: 0.06, y: 0.59))
        heart.addCurve(to: CGPoint(x: 0.5, y: 0.23), controlPoint1: CGPoint(x: 0.06, y: 0.08), controlPoint2: CGPoint(x: 0.37, y: 0.05))
        heart.addCurve(to: CGPoint(x: 0.94, y: 0.38), controlPoint1: CGPoint(x: 0.63, y: 0.05), controlPoint2: CGPoint(x: 0.94, y: 0.08))
        heart.addCurve(to: CGPoint(x: 0.5, y: 0.93), controlPoint1: CGPoint(x: 0.94, y: 0.59), controlPoint2: CGPoint(x: 0.61, y: 0.79))
        heart.close()
        heart.apply(CGAffineTransform(scaleX: heartRect.width, y: heartRect.height))
        for (half, isLeft) in [(leftHeart, true), (rightHeart, false)] {
            half.frame = heartRect
            half.path = heart.cgPath
            half.fillColor = UIColor(CapyPalette.life).cgColor
            half.opacity = 0
            let mask = CAShapeLayer()
            mask.frame = half.bounds
            let edge: CGFloat = isLeft ? 0 : 1
            let cut = UIBezierPath()
            cut.move(to: CGPoint(x: edge, y: 0))
            for point in [CGPoint(x: 0.50, y: 0), CGPoint(x: 0.50, y: 0.25), CGPoint(x: 0.43, y: 0.41),
                          CGPoint(x: 0.57, y: 0.57), CGPoint(x: 0.47, y: 0.72), CGPoint(x: 0.50, y: 1), CGPoint(x: edge, y: 1)] {
                cut.addLine(to: point)
            }
            cut.close()
            cut.apply(CGAffineTransform(scaleX: heartRect.width, y: heartRect.height))
            mask.path = cut.cgPath
            half.mask = mask
            presentation.addSublayer(half)
        }
        let r = bounds.insetBy(dx: bounds.width * 0.23, dy: bounds.height * 0.23)
        let x = UIBezierPath()
        x.move(to: CGPoint(x: r.minX, y: r.minY)); x.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        x.move(to: CGPoint(x: r.maxX, y: r.minY)); x.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        // Match PuzzleGridUIView.drawX exactly, including the warm outline.
        // Otherwise removing this transient cover changes the red X's weight.
        for target in [crossOutline, cross] {
            target.frame = bounds; target.path = x.cgPath
            target.lineWidth = max(3.2, bounds.width * 0.11) + (target === crossOutline ? 2 : 0)
            target.lineCap = .round
            target.strokeColor = target === crossOutline ? UIColor(CapyPalette.markOutline).cgColor : UIColor(CapyPalette.life).cgColor
            target.fillColor = UIColor.clear.cgColor; target.opacity = 0
            presentation.addSublayer(target)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func play() {
        transitionTask?.cancel(); cleanupTask?.cancel()
        if reduceMotion {
            // A static split-heart/X sequence preserves meaning without shake,
            // scale, rotation or travelling particles.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            leftHeart.opacity = 1; rightHeart.opacity = 1
            leftHeart.setAffineTransform(CGAffineTransform(translationX: -2, y: 0))
            rightHeart.setAffineTransform(CGAffineTransform(translationX: 2, y: 0))
            CATransaction.commit()
            let transition = DispatchWorkItem { [weak self] in
                guard let self, self.superview != nil else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.leftHeart.opacity = 0; self.rightHeart.opacity = 0
                self.crossOutline.opacity = 1; self.cross.opacity = 1
                CATransaction.commit()
            }
            transitionTask = transition
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: transition)
        } else {
            // Original [252]: shake this cell's presentation, not the board's
            // frame, hit targets or persisted geometry. Settle within 0.25s.
            let travel = min(2.4, bounds.width * 0.035)
            animate(presentation, key: "transform.translation.x",
                    values: [0, -travel, travel, -travel * 0.6, travel * 0.3, 0, 0],
                    times: [0, 0.05, 0.11, 0.18, 0.25, 0.31, 1])
            animate(cellRim, key: "opacity", values: [0, 1, 0.6, 0, 0], times: [0, 0.05, 0.18, 0.31, 1])
            animate(face, key: "opacity", values: [1, 1, 0, 0], times: [0, 0.22, 0.34, 1])
            animate(face, key: "transform.rotation.z", values: [0, -0.10, 0.10, -0.07, 0.06, 0, 0], times: [0, 0.07, 0.14, 0.21, 0.28, 0.34, 1])
            for (half, direction) in [(leftHeart, -1.0), (rightHeart, 1.0)] {
                animate(half, key: "opacity", values: [0, 0, 1, 1, 0, 0], times: [0, 0.20, 0.30, 0.58, 0.85, 1])
                animate(half, key: "transform.translation.x", values: [0, 0, direction * bounds.width * 0.12, direction * bounds.width * 0.12], times: [0, 0.35, 0.75, 1])
                animate(half, key: "transform.rotation.z", values: [0, 0, direction * 0.17, direction * 0.17], times: [0, 0.35, 0.75, 1])
            }
            for target in [crossOutline, cross] {
                target.opacity = 1
                animate(target, key: "opacity", values: [0, 0, 1, 1], times: [0, 0.60, 0.88, 1])
            }
        }
        let cleanup = DispatchWorkItem { [weak self] in self?.removeFromSuperview() }
        cleanupTask = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: cleanup)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            transitionTask?.cancel(); transitionTask = nil
            cleanupTask?.cancel(); cleanupTask = nil
            layer.removeAllAnimations(); presentation.removeAllAnimations()
            presentation.sublayers?.forEach { $0.removeAllAnimations() }
        }
        super.willMove(toSuperview: newSuperview)
    }

    private func animate(_ target: CALayer, key: String, values: [CGFloat], times: [NSNumber]) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values; animation.keyTimes = times; animation.duration = 0.78
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(animation, forKey: key)
    }
}
