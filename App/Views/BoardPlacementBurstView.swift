import UIKit

/// A sparse, finite celebration in board coordinates. Only committed finds
/// create it; particles carry no score, answer, inventory or touch behavior.
/// Demo timing is intentionally provisional, not a measured reference value.
final class BoardPlacementBurstView: UIView {
    let cellIndex: Int
    let duration: TimeInterval = 0.62
    let particleCount = 12
    private(set) var trajectories: [[CGPoint]] = []
    private(set) var particleRadii: [CGFloat] = []
    private var particles: [CAShapeLayer] = []
    private var cleanup: DispatchWorkItem?
    private var generation = UUID()

    init(cellIndex: Int, frame: CGRect, boardRect: CGRect, cellRect: CGRect, regionColor: UIColor) {
        self.cellIndex = cellIndex
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; clipsToBounds = true
        isUserInteractionEnabled = false; isAccessibilityElement = false; accessibilityElementsHidden = true
        let origin = CGPoint(x: cellRect.midX, y: cellRect.midY)
        let unit = cellRect.width
        let palette = [2, 4, 8, 9].map { UIColor(CapyPalette.regionColors[$0]) }
        for index in 0..<particleCount {
            let star = index.isMultiple(of: 2)
            let side = min(star ? 9 : 8, max(3, unit * (star ? 0.13 : 0.10)))
            let shape = CAShapeLayer()
            shape.name = star ? "placement-star-\(index)" : "placement-region-\(index)"
            shape.bounds = CGRect(x: 0, y: 0, width: side, height: star ? side : side * 0.72)
            let path = UIBezierPath()
            if star {
                for vertex in 0..<8 {
                    let angle = CGFloat(vertex) * .pi / 4 - .pi / 2
                    let radius = side * (vertex.isMultiple(of: 2) ? 0.5 : 0.17)
                    let point = CGPoint(x: side / 2 + cos(angle) * radius, y: side / 2 + sin(angle) * radius)
                    if vertex == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            } else {
                path.move(to: CGPoint(x: 0, y: side * 0.17))
                path.addLine(to: CGPoint(x: side * 0.76, y: 0))
                path.addLine(to: CGPoint(x: side, y: side * 0.48))
                path.addLine(to: CGPoint(x: side * 0.28, y: side * 0.72))
            }
            path.close(); shape.path = path.cgPath
            shape.fillColor = (star ? palette[(index / 2) % palette.count] : regionColor).cgColor
            shape.strokeColor = UIColor(CapyPalette.paper).withAlphaComponent(star ? 0.9 : 0.6).cgColor
            shape.lineWidth = 0.65; shape.opacity = 0
            let radius = hypot(shape.bounds.width, shape.bounds.height) / 2 + shape.lineWidth
            let angle = CGFloat(index) * .pi * 2 / CGFloat(particleCount) - .pi * 0.9
            let raw = (0...20).map { sample -> CGPoint in
                let t = CGFloat(sample) / 20
                return CGPoint(x: cos(angle) * unit * (0.22 + 1.45 * t),
                               y: sin(angle) * unit * 0.22 - (abs(sin(angle)) * 1.45 + 0.26) * unit * t + unit * 1.8 * t * t)
            }
            // Scale the whole arc rather than clamp individual points, so an
            // edge particle never sticks to a boundary or changes direction.
            let allowed = boardRect.insetBy(dx: radius + 1, dy: radius + 1)
            var scale: CGFloat = 1
            for delta in raw {
                if delta.x > 0 { scale = min(scale, (allowed.maxX - origin.x) / delta.x) }
                if delta.x < 0 { scale = min(scale, (allowed.minX - origin.x) / delta.x) }
                if delta.y > 0 { scale = min(scale, (allowed.maxY - origin.y) / delta.y) }
                if delta.y < 0 { scale = min(scale, (allowed.minY - origin.y) / delta.y) }
            }
            scale = max(0, scale)
            let points = raw.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) }
            trajectories.append(points); particleRadii.append(radius)
            shape.position = points.last ?? origin
            layer.addSublayer(shape); particles.append(shape)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func play() {
        cleanup?.cancel()
        let token = UUID(); generation = token
        let now = CACurrentMediaTime()
        for (index, particle) in particles.enumerated() {
            particle.removeAllAnimations()
            let travel = CAKeyframeAnimation(keyPath: "position")
            travel.values = trajectories[index].map { NSValue(cgPoint: $0) }
            travel.calculationMode = .linear
            travel.duration = duration; travel.beginTime = particle.convertTime(now, from: nil)
            particle.add(travel, forKey: "placement-flight")
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 0.92, 0.8, 0]; opacity.keyTimes = [0, 0.08, 0.5, 1]
            opacity.duration = duration; opacity.beginTime = travel.beginTime
            particle.add(opacity, forKey: "placement-fade")
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = index.isMultiple(of: 2) ? 0.55 : -1.25
            spin.duration = duration; spin.beginTime = travel.beginTime
            particle.add(spin, forKey: "placement-spin")
            let size = CAKeyframeAnimation(keyPath: "transform.scale")
            size.values = [0.35, 1, 0.45]; size.keyTimes = [0, 0.18, 1]
            size.duration = duration; size.beginTime = travel.beginTime
            particle.add(size, forKey: "placement-size")
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == token else { return }
            removeFromSuperview()
        }
        cleanup = work; DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            generation = UUID(); cleanup?.cancel(); cleanup = nil
            layer.removeAllAnimations(); particles.forEach { $0.removeAllAnimations() }
        }
        super.willMove(toSuperview: newSuperview)
    }
}
