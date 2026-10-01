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

    init(cellIndex: Int, kind: Kind, frame: CGRect, tileColor: UIColor, reduceMotion: Bool, errorMark: Bool = false) {
        self.cellIndex = cellIndex; self.kind = kind; self.reduceMotion = reduceMotion
        duration = reduceMotion ? 0.10 : kind == .found ? 0.32 : kind == .markAdded ? 0.16 : 0.13
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = tileColor
        layer.cornerRadius = max(3, bounds.width * 0.05)

        if kind == .found {
            symbol.frame = bounds.insetBy(dx: bounds.width * 0.07, dy: bounds.height * 0.07)
            symbol.contents = UIImage(named: "CapyFace")?.cgImage
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
                target.opacity = kind == .markRemoved ? 0 : 1
                layer.addSublayer(target)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func play() {
        if !reduceMotion {
            if kind == .found {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [0.28, 1.14, 0.96, 1]; pop.keyTimes = [0, 0.5, 0.8, 1]
                pop.duration = duration; pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
                symbol.add(pop, forKey: "found-pop")
                animate(symbol, key: "opacity", from: 0.25, to: 1, duration: 0.10)
                animate(ring, key: "opacity", from: 0.85, to: 0, duration: duration)
                animate(ring, key: "transform.scale", from: 0.55, to: 1.25, duration: duration)
            } else {
                for target in [crossOutline, cross] {
                    if kind == .markAdded {
                        animate(target, key: "strokeEnd", from: 0, to: 1, duration: duration)
                        animate(target, key: "transform.scale", from: 0.84, to: 1, duration: duration)
                    } else {
                        animate(target, key: "opacity", from: 1, to: 0, duration: duration)
                        animate(target, key: "transform.scale", from: 1, to: 0.72, duration: duration)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.removeFromSuperview() }
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
