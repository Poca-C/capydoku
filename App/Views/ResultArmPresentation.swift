import UIKit

/// The same complete sleeve is drawn behind and in front of the torso. The
/// front copy is exposed only around the forearm: it has no separate elbow cap
/// or inner outline. Both copies share their path, pigment and animation clock.
final class ResultArmPresentation {
    private let left = Sleeve(name: "left")
    private let right = Sleeve(name: "right")
    private var cachedPerformance: ResultCharacterPerformance?
    private var cachedSize = CGSize.zero
    private var tracks: [(left: ResultArmGeometry, right: ResultArmGeometry)] = []

    var backLayers: [CALayer] { [left.back.root, right.back.root] }
    var frontLayers: [CALayer] { [left.front.root, right.front.root] }

    func configure(performance: ResultCharacterPerformance, size: CGSize, enabled: Bool) {
        for root in backLayers + frontLayers { root.opacity = enabled ? 1 : 0 }
        guard enabled else { cancel(); return }
        guard size.width > 0, size.height > 0 else { return }
        if cachedPerformance != performance || cachedSize != size {
            cachedPerformance = performance; cachedSize = size
            tracks = ResultRigMotion.samples(performance).map {
                (ResultArmGeometry(arm: $0.leftArm, size: size),
                 ResultArmGeometry(arm: $0.rightArm, size: size))
            }
        }
        guard let final = tracks.last else { return }
        left.configure(final.left, size: size); right.configure(final.right, size: size)
    }

    func play(duration: TimeInterval, startTime: TimeInterval) {
        guard tracks.count == ResultRigMotion.sampleCount,
              left.back.root.opacity > 0 else { return }
        left.play(tracks.map(\.left), duration: duration, startTime: startTime)
        right.play(tracks.map(\.right), duration: duration, startTime: startTime)
    }

    func cancel() { left.cancel(); right.cancel() }

    private final class Sleeve {
        let back: Paint
        let front: Paint
        private let frontMask = CAShapeLayer()

        init(name: String) {
            back = Paint(name: "result-arm-\(name)-back")
            front = Paint(name: "result-arm-\(name)-front")
            frontMask.name = "result-arm-\(name)-forearm-mask"
            frontMask.fillColor = nil; frontMask.strokeColor = UIColor.white.cgColor
            frontMask.lineCap = .round; frontMask.lineJoin = .round
            front.root.mask = frontMask
        }

        func configure(_ geometry: ResultArmGeometry, size: CGSize) {
            back.configure(geometry, size: size); front.configure(geometry, size: size)
            frontMask.bounds = ResultArmGeometry.canvas(size)
            frontMask.position = CGPoint(x: size.width / 2, y: size.height / 2)
            frontMask.path = geometry.forearmWindow
            // This mask selects pixels from the complete sleeve. Extra margin
            // prevents antialiasing from cutting into its existing outer ink.
            frontMask.lineWidth = geometry.maximumWidth + geometry.outlineWidth + size.width * 0.012
        }

        func play(_ track: [ResultArmGeometry], duration: TimeInterval, startTime: TimeInterval) {
            back.play(track, duration: duration, startTime: startTime)
            front.play(track, duration: duration, startTime: startTime)
            ResultArmPresentation.animate(frontMask, paths: track.map(\.forearmWindow), duration: duration, startTime: startTime)
        }

        func cancel() { back.cancel(); front.cancel(); frontMask.removeAllAnimations() }
    }

    private final class Paint {
        let root = CALayer()
        private let outline = CAShapeLayer()
        private let pigment = CAGradientLayer()
        private let fillMask = CAShapeLayer()
        private let highlight = CAShapeLayer()

        init(name: String) {
            root.name = name
            outline.name = name + "-outline"
            outline.fillColor = UIColor(red: 0.25, green: 0.115, blue: 0.052, alpha: 1).cgColor
            outline.strokeColor = outline.fillColor
            outline.lineJoin = .round
            root.addSublayer(outline)
            pigment.name = name + "-pigment"
            pigment.colors = [UIColor(red: 1, green: 0.76, blue: 0.43, alpha: 1).cgColor,
                              UIColor(red: 0.93, green: 0.65, blue: 0.34, alpha: 1).cgColor,
                              UIColor(red: 0.82, green: 0.49, blue: 0.24, alpha: 1).cgColor]
            pigment.locations = [0, 0.54, 1]
            pigment.startPoint = CGPoint(x: 0.12, y: 0.12)
            pigment.endPoint = CGPoint(x: 0.86, y: 1)
            fillMask.name = name + "-fill-mask"
            fillMask.fillColor = UIColor.white.cgColor; fillMask.strokeColor = nil
            pigment.mask = fillMask
            root.addSublayer(pigment)
            highlight.name = name + "-highlight"
            highlight.fillColor = nil
            highlight.strokeColor = UIColor(red: 1, green: 0.84, blue: 0.56, alpha: 0.11).cgColor
            highlight.lineCap = .round; highlight.lineJoin = .round
            pigment.addSublayer(highlight)
        }

        func configure(_ geometry: ResultArmGeometry, size: CGSize) {
            let bounds = ResultArmGeometry.canvas(size)
            highlight.setAffineTransform(.identity)
            for layer in [root, outline, pigment, fillMask, highlight] {
                layer.bounds = bounds; layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
            }
            pigment.startPoint = CGPoint(x: (size.width * 0.12 - bounds.minX) / bounds.width,
                                         y: (size.height * 0.12 - bounds.minY) / bounds.height)
            pigment.endPoint = CGPoint(x: (size.width * 0.86 - bounds.minX) / bounds.width,
                                       y: (size.height - bounds.minY) / bounds.height)
            outline.path = geometry.contour; outline.lineWidth = geometry.outlineWidth
            fillMask.path = geometry.contour
            highlight.path = geometry.centerline; highlight.lineWidth = size.width * 0.014
            highlight.setAffineTransform(CGAffineTransform(translationX: -size.width * 0.016,
                                                         y: -size.height * 0.009))
        }

        func play(_ track: [ResultArmGeometry], duration: TimeInterval, startTime: TimeInterval) {
            for shape in [outline, fillMask] {
                ResultArmPresentation.animate(shape, paths: track.map(\.contour), duration: duration, startTime: startTime)
            }
            ResultArmPresentation.animate(highlight, paths: track.map(\.centerline), duration: duration, startTime: startTime)
        }

        func cancel() {
            for layer in [root, outline, pigment, fillMask, highlight] { layer.removeAllAnimations() }
        }
    }

    private static func animate(_ shape: CAShapeLayer, paths: [CGPath], duration: TimeInterval,
                                startTime: TimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = paths
        animation.keyTimes = ResultRigMotion.phases.map { NSNumber(value: Double($0)) }
        animation.calculationMode = .linear; animation.duration = duration
        animation.beginTime = shape.convertTime(startTime, from: nil)
        shape.add(animation, forKey: "result-arm-contour")
    }
}

/// Fixed path topology lets Core Animation interpolate all 73 samples without
/// rasterizing sprites or repeatedly rebuilding a path on the main thread.
struct ResultArmGeometry {
    let centerline: CGPath
    let forearmWindow: CGPath
    let contour: CGPath
    let maximumWidth: CGFloat
    let outlineWidth: CGFloat

    /// Raised wrists extend a little beyond the rig's normalized unit square.
    /// Give both pigment and masks real backing space there; the transparent
    /// layer frame is not the visible arm's extent.
    static func canvas(_ size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: -size.width * 0.16, dy: -size.height * 0.16)
    }

    init(arm: ResultRigArm, size: CGSize) {
        func scaled(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * size.width, y: point.y * size.height) }
        func toward(_ point: CGPoint, from origin: CGPoint, fraction: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + (point.x - origin.x) * fraction,
                    y: origin.y + (point.y - origin.y) * fraction)
        }
        let shoulder = scaled(arm.shoulder), elbow = scaled(arm.elbow), wrist = scaled(arm.wrist)
        let entry = toward(shoulder, from: elbow, fraction: 0.52)
        let exit = toward(wrist, from: elbow, fraction: 0.52)
        let complete = CGMutablePath()
        complete.move(to: shoulder); complete.addLine(to: entry)
        complete.addQuadCurve(to: exit, control: elbow); complete.addLine(to: wrist)
        centerline = complete
        let forearm = CGMutablePath()
        // Expose the bend and forearm, not the taper at the hidden shoulder.
        // The wide old window reached back into that taper when hugging and
        // revealed a small notch against the opaque torso.
        let windowEntry = toward(shoulder, from: elbow, fraction: 0.15)
        forearm.move(to: windowEntry); forearm.addQuadCurve(to: exit, control: elbow); forearm.addLine(to: wrist)
        forearmWindow = forearm
        maximumWidth = size.width * 0.128
        outlineWidth = size.width * 0.010

        // Keep 33 samples and 66 cubic segments in every silhouette. Offset
        // rails taper from a hidden shoulder root to a soft elbow, then to a
        // narrow wrist wholly under the original paw. A closed contour avoids
        // the old flat cut ends and equal-width plumbing appearance.
        var samples: [(point: CGPoint, tangent: CGPoint)] = []
        for index in 0...32 {
            let point: CGPoint, derivative: CGPoint
            if index <= 8 {
                point = toward(entry, from: shoulder, fraction: CGFloat(index) / 8)
                derivative = CGPoint(x: entry.x - shoulder.x, y: entry.y - shoulder.y)
            } else if index <= 24 {
                let t = CGFloat(index - 8) / 16, u = 1 - t
                point = CGPoint(x: u * u * entry.x + 2 * u * t * elbow.x + t * t * exit.x,
                                y: u * u * entry.y + 2 * u * t * elbow.y + t * t * exit.y)
                derivative = CGPoint(x: 2 * (u * (elbow.x - entry.x) + t * (exit.x - elbow.x)),
                                     y: 2 * (u * (elbow.y - entry.y) + t * (exit.y - elbow.y)))
            } else {
                point = toward(wrist, from: exit, fraction: CGFloat(index - 24) / 8)
                derivative = CGPoint(x: wrist.x - exit.x, y: wrist.y - exit.y)
            }
            let length = max(0.000001, hypot(derivative.x, derivative.y))
            samples.append((point, CGPoint(x: derivative.x / length, y: derivative.y / length)))
        }
        var distances: [CGFloat] = [0]
        for index in 1..<samples.count {
            let a = samples[index - 1].point, b = samples[index].point
            distances.append(distances[index - 1] + hypot(b.x - a.x, b.y - a.y))
        }
        let total = max(0.000001, distances.last ?? 1)
        func radius(_ t: CGFloat) -> CGFloat {
            let stops: [CGFloat] = [0, 0.14, 0.36, 0.58, 1]
            let values: [CGFloat] = [0, 0.058, 0.064, 0.063, 0.037]
            let upper = stops.firstIndex(where: { $0 > t }) ?? stops.count - 1
            let lower = max(0, upper - 1)
            let fraction = min(1, max(0, (t - stops[lower]) / (stops[upper] - stops[lower])))
            let ease = fraction * fraction * (3 - 2 * fraction)
            return size.width * (values[lower] + (values[upper] - values[lower]) * ease)
        }
        let turn = (elbow.x - shoulder.x) * (wrist.y - elbow.y) - (elbow.y - shoulder.y) * (wrist.x - elbow.x)
        let inside: CGFloat = turn >= 0 ? 1 : -1
        let firstTangent = samples[0].tangent, lastTangent = samples[32].tangent
        let summedNormal = CGPoint(x: -(firstTangent.y + lastTangent.y) * inside,
                                   y: (firstTangent.x + lastTangent.x) * inside)
        let normalLength = max(0.000001, hypot(summedNormal.x, summedNormal.y))
        let innerControl = CGPoint(x: elbow.x + summedNormal.x / normalLength * size.width * 0.090,
                                   y: elbow.y + summedNormal.y / normalLength * size.width * 0.090)
        let innerEnd = CGPoint(x: wrist.x - lastTangent.y * radius(1) * inside,
                               y: wrist.y + lastTangent.x * radius(1) * inside)
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (index, sample) in samples.enumerated() {
            let progress = distances[index] / total
            let r = radius(progress)
            let normal = CGPoint(x: -sample.tangent.y, y: sample.tangent.x)
            // A simple quadratic inner rail cannot fold over itself when the
            // shoulder and wrist approach one another. Directly offsetting the
            // tightly bent centreline would create loops at a hugged elbow.
            let u = 1 - progress
            let innerPoint = CGPoint(x: u * u * shoulder.x + 2 * u * progress * innerControl.x + progress * progress * innerEnd.x,
                                     y: u * u * shoulder.y + 2 * u * progress * innerControl.y + progress * progress * innerEnd.y)
            left.append(inside > 0 ? innerPoint : CGPoint(x: sample.point.x + normal.x * r, y: sample.point.y + normal.y * r))
            right.append(inside < 0 ? innerPoint : CGPoint(x: sample.point.x - normal.x * r, y: sample.point.y - normal.y * r))
        }
        let outline = CGMutablePath()
        func addRail(_ rail: [CGPoint]) {
            for index in 1..<rail.count {
                let a = rail[index - 1], b = rail[index]
                let previous = rail[max(0, index - 2)], next = rail[min(rail.count - 1, index + 1)]
                outline.addCurve(to: b,
                    control1: CGPoint(x: a.x + (b.x - previous.x) / 6, y: a.y + (b.y - previous.y) / 6),
                    control2: CGPoint(x: b.x - (next.x - a.x) / 6, y: b.y - (next.y - a.y) / 6))
            }
        }
        outline.move(to: left[0]); addRail(left)
        let tangent = samples[32].tangent, normal = CGPoint(x: -tangent.y, y: tangent.x)
        let wristRadius = radius(1), k: CGFloat = 0.5522847498
        let tip = CGPoint(x: wrist.x + tangent.x * wristRadius, y: wrist.y + tangent.y * wristRadius)
        outline.addCurve(to: tip,
            control1: CGPoint(x: left[32].x + tangent.x * wristRadius * k, y: left[32].y + tangent.y * wristRadius * k),
            control2: CGPoint(x: tip.x + normal.x * wristRadius * k, y: tip.y + normal.y * wristRadius * k))
        outline.addCurve(to: right[32],
            control1: CGPoint(x: tip.x - normal.x * wristRadius * k, y: tip.y - normal.y * wristRadius * k),
            control2: CGPoint(x: right[32].x + tangent.x * wristRadius * k, y: right[32].y + tangent.y * wristRadius * k))
        addRail(Array(right.reversed())); outline.closeSubpath()
        contour = outline
    }
}
