import UIKit

/// A presentation of the supplied tutorial targets, never a puzzle solver.
/// Real touches still belong to the board's original three recognizers.
final class BoardTutorialGuideView: UIView {
    let action: String
    let targetCells: Set<Int>
    let targetFrames: [CGRect]
    let gestureStart: CGPoint?
    let gestureEnd: CGPoint?
    let reduceMotion: Bool
    let boardRect: CGRect
    private let hand = CALayer()
    private let touchRing = CAShapeLayer()

    init(frame: CGRect, boardRect: CGRect, size: Int, targetCells: Set<Int>, action: String, reduceMotion: Bool) {
        self.action = action; self.boardRect = boardRect; self.reduceMotion = reduceMotion
        let count = (1...16).contains(size) ? size * size : 0
        let targets = targetCells.filter { (0..<count).contains($0) }
        self.targetCells = targets
        let side = boardRect.width / CGFloat(max(1, size))
        let frames = targets.sorted().map { index in
            CGRect(x: boardRect.minX + CGFloat(index % size) * side,
                   y: boardRect.minY + CGFloat(index / size) * side, width: side, height: side)
        }
        targetFrames = frames
        let centers = frames.map { CGPoint(x: $0.midX, y: $0.midY) }
        let aligned = centers.count >= 2 && (centers.allSatisfy { abs($0.x - centers[0].x) < 0.1 }
            || centers.allSatisfy { abs($0.y - centers[0].y) < 0.1 })
        if action == "swipe" && aligned {
            gestureStart = centers.first; gestureEnd = centers.last
        } else if action == "tap" || action == "doubleTap" {
            gestureStart = centers.first; gestureEnd = centers.first
        } else { gestureStart = nil; gestureEnd = nil }
        super.init(frame: frame)
        isUserInteractionEnabled = false; isAccessibilityElement = false; accessibilityElementsHidden = true
        backgroundColor = .clear
        let mask = CAShapeLayer(); mask.path = UIBezierPath(roundedRect: boardRect, cornerRadius: 4).cgPath
        layer.mask = mask
        let dim = UIBezierPath(rect: boardRect)
        for rect in frames { dim.append(UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 3)) }
        let shade = CAShapeLayer(); shade.name = "tutorial-focus-shade"; shade.path = dim.cgPath
        shade.fillRule = .evenOdd; shade.fillColor = UIColor(CapyPalette.ink).withAlphaComponent(0.26).cgColor
        layer.addSublayer(shade)
        guard let start = gestureStart, let end = gestureEnd else { return }
        let radius = max(5, min(12, side * 0.16))
        touchRing.name = "tutorial-touch-ring"; touchRing.bounds = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
        touchRing.position = start; touchRing.path = UIBezierPath(ovalIn: touchRing.bounds).cgPath
        touchRing.fillColor = UIColor.white.withAlphaComponent(0.78).cgColor
        touchRing.strokeColor = UIColor(CapyPalette.orange).cgColor; touchRing.lineWidth = 2
        layer.addSublayer(touchRing)
        if action == "swipe" {
            let path = UIBezierPath(); path.move(to: start); path.addLine(to: end)
            let track = CAShapeLayer(); track.name = "tutorial-swipe-track"; track.path = path.cgPath
            track.fillColor = UIColor.clear.cgColor; track.strokeColor = UIColor.white.cgColor
            track.lineWidth = 2.5; track.lineDashPattern = [4, 4]; track.lineCap = .round
            layer.insertSublayer(track, below: touchRing)
            // A static arrow remains intelligible with Reduce Motion enabled.
            let direction = CGVector(dx: end.x - start.x, dy: end.y - start.y)
            let length = max(1, hypot(direction.dx, direction.dy))
            let dx = direction.dx / length, dy = direction.dy / length, tip = min(6, side * 0.2)
            let arrow = UIBezierPath(); arrow.move(to: CGPoint(x: end.x - dx * tip - dy * tip, y: end.y - dy * tip + dx * tip))
            arrow.addLine(to: end); arrow.addLine(to: CGPoint(x: end.x - dx * tip + dy * tip, y: end.y - dy * tip - dx * tip))
            let arrowLayer = CAShapeLayer(); arrowLayer.name = "tutorial-swipe-direction"; arrowLayer.path = arrow.cgPath
            arrowLayer.fillColor = UIColor.clear.cgColor; arrowLayer.strokeColor = UIColor.white.cgColor; arrowLayer.lineWidth = 2.5
            layer.addSublayer(arrowLayer)
        }
        let iconSide = max(18, min(29, side * 0.5))
        hand.name = "tutorial-hand"; hand.bounds = CGRect(x: 0, y: 0, width: iconSide, height: iconSide)
        hand.anchorPoint = CGPoint(x: 0.24, y: 0.10); hand.position = handPosition(for: start)
        hand.contents = UIImage(systemName: "hand.point.up.left.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: iconSide, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal).cgImage
        hand.contentsGravity = .resizeAspect; hand.shadowColor = UIColor(CapyPalette.markOutline).cgColor
        hand.shadowOffset = .zero; hand.shadowRadius = 1.5; hand.shadowOpacity = 0.8
        layer.addSublayer(hand)
        if action == "doubleTap" && reduceMotion {
            let second = CAShapeLayer(); second.name = "tutorial-double-tap-static"
            second.path = UIBezierPath(ovalIn: CGRect(x: start.x - radius - 4, y: start.y - radius - 4, width: radius * 2 + 8, height: radius * 2 + 8)).cgPath
            second.fillColor = UIColor.clear.cgColor; second.strokeColor = UIColor(CapyPalette.orange).cgColor; second.lineWidth = 1.5
            layer.insertSublayer(second, below: hand)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func handPosition(for touch: CGPoint) -> CGPoint {
        // Keep the hand and its outline inside the board, including bottom/right
        // edge targets on 10x10 boards. The ring and path still use real centers.
        let safe = boardRect.insetBy(dx: 3, dy: 3)
        let left = safe.minX + hand.bounds.width * hand.anchorPoint.x
        let right = safe.maxX - hand.bounds.width * (1 - hand.anchorPoint.x)
        let top = safe.minY + hand.bounds.height * hand.anchorPoint.y
        let bottom = safe.maxY - hand.bounds.height * (1 - hand.anchorPoint.y)
        return CGPoint(x: min(max(touch.x, left), right), y: min(max(touch.y, top), bottom))
    }

    func play() {
        guard !reduceMotion, let start = gestureStart, let end = gestureEnd else { return }
        if action == "swipe" {
            for target in [hand, touchRing] {
                let from = target === hand ? handPosition(for: start) : start
                let to = target === hand ? handPosition(for: end) : end
                let movement = CAKeyframeAnimation(keyPath: "position")
                movement.values = [NSValue(cgPoint: from), NSValue(cgPoint: from), NSValue(cgPoint: to), NSValue(cgPoint: to)]
                movement.keyTimes = [0, 0.15, 0.73, 1]; movement.duration = 1.65; movement.repeatCount = .infinity
                movement.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                target.add(movement, forKey: "tutorial-swipe")
            }
        } else {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = action == "doubleTap" ? [1, 0.82, 1, 0.82, 1, 1] : [1, 0.82, 1, 1]
            scale.keyTimes = action == "doubleTap" ? [0, 0.12, 0.22, 0.32, 0.42, 1] : [0, 0.13, 0.3, 1]
            scale.duration = 1.65; scale.repeatCount = .infinity; hand.add(scale, forKey: "tutorial-tap")
            let pulse = scale.copy() as! CAKeyframeAnimation
            pulse.values = action == "doubleTap" ? [0.75, 1.18, 0.75, 1.18, 0.75, 0.75] : [0.75, 1.18, 0.75, 0.75]
            touchRing.add(pulse, forKey: "tutorial-touch")
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            layer.removeAllAnimations(); layer.sublayers?.forEach { $0.removeAllAnimations() }
        }
        super.willMove(toSuperview: newSuperview)
    }
}
