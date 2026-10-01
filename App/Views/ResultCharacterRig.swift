import Foundation
import CoreGraphics

/// Twelve original cutouts share one coordinate system. Each performance keeps
/// its head texture; joints, not complete-character image swaps, create motion.
enum ResultRigPart: Int, CaseIterable {
    case torso, happyHead, sadHead, star
    case leftUpperArm, leftForearm, leftPaw, leftFoot
    case rightUpperArm, rightForearm, rightPaw, rightFoot

    var layerName: String { "result-rig-\(self)" }
}

struct ResultRigPartPose {
    let center: CGPoint
    let size: CGSize
    let rotation: CGFloat
}

struct ResultRigArm {
    let shoulder: CGPoint
    let elbow: CGPoint
    let wrist: CGPoint
}

struct ResultRigPose {
    let parts: [ResultRigPart: ResultRigPartPose]
    let leftArm: ResultRigArm
    let rightArm: ResultRigArm
}

enum ResultRigMotion {
    /// Shared samples are calculated once per performance, before playback.
    /// Core Animation interpolates them; no display link or repeating timer.
    static let sampleCount = 73
    static let phases = (0..<sampleCount).map { CGFloat($0) / CGFloat(sampleCount - 1) }
    private static let tracks = Dictionary(uniqueKeysWithValues: ResultCharacterPerformance.allCases.map { performance in
        (performance, phases.map { pose(performance, phase: $0) })
    })
    static func prewarm() { _ = tracks.count }
    static func samples(_ performance: ResultCharacterPerformance) -> [ResultRigPose] { tracks[performance] ?? [] }

    private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    private static func interpolate(_ phase: CGFloat, times: [CGFloat], values: [CGFloat], passingThrough: Set<Int> = []) -> CGFloat {
        let phase = min(1, max(0, phase))
        guard let upper = times.firstIndex(where: { $0 > phase }), upper > 0 else { return values.last! }
        let lower = upper - 1
        let t = (phase - times[lower]) / (times[upper] - times[lower])
        let ease = t * t * (3 - 2 * t)
        let stopped = values[lower] + (values[upper] - values[lower]) * ease
        guard !passingThrough.isEmpty else { return stopped }
        // A transit waypoint is not a pose to hold. Use a shared bounded slope
        // on both sides; reversals and every authored contact still stop. The
        // weighted harmonic mean prevents a wrist coordinate overshooting its
        // adjacent key poses, which also keeps the authored IK arc reachable.
        func slope(_ index: Int) -> CGFloat {
            guard passingThrough.contains(index), index > 0, index < times.count - 1 else { return 0 }
            let before = times[index] - times[index - 1], after = times[index + 1] - times[index]
            let incoming = (values[index] - values[index - 1]) / before
            let outgoing = (values[index + 1] - values[index]) / after
            guard incoming * outgoing > 0 else { return 0 }
            let w1 = 2 * after + before, w2 = after + 2 * before
            return (w1 + w2) / (w1 / incoming + w2 / outgoing)
        }
        let span = times[upper] - times[lower]
        return stopped + (t * t * t - 2 * t * t + t) * span * slope(lower)
            + (t * t * t - t * t) * span * slope(upper)
    }

    private static func path(_ phase: CGFloat, times: [CGFloat], points: [CGPoint], passingThrough: Set<Int> = []) -> CGPoint {
        point(interpolate(phase, times: times, values: points.map(\.x), passingThrough: passingThrough),
              interpolate(phase, times: times, values: points.map(\.y), passingThrough: passingThrough))
    }

    /// A fixed elbow branch avoids sudden flips. All authored targets remain
    /// inside the reachable annulus; the clamp is a defensive fallback only.
    static func arm(shoulder: CGPoint, wrist: CGPoint, length: CGFloat, bend: CGFloat) -> ResultRigArm {
        let dx = wrist.x - shoulder.x, dy = wrist.y - shoulder.y
        let requested = hypot(dx, dy), distance = min(length * 2 - 0.0001, max(0.0001, requested))
        let ux = requested > 0 ? dx / requested : 0, uy = requested > 0 ? dy / requested : 1
        let along = distance / 2, offset = sqrt(max(0, length * length - along * along))
        return ResultRigArm(shoulder: shoulder,
            elbow: point(shoulder.x + ux * along - uy * offset * bend,
                         shoulder.y + uy * along + ux * offset * bend),
            wrist: point(shoulder.x + ux * distance, shoulder.y + uy * distance))
    }

    static func pose(_ performance: ResultCharacterPerformance, phase: CGFloat) -> ResultRigPose {
        let joy = performance == .joyfulRaise
        let hugging = performance == .starHug
        let shoulderL = point(joy ? 0.29 : (hugging ? 0.28 : 0.31), joy ? 0.59 : (hugging ? 0.61 : 0.54))
        // The old hug shoulder at x=.83 sat on the torso's outer alpha edge,
        // exposing its attachment as a hook. Move that joint into the body;
        // the authored wrist/star path and both bone lengths remain unchanged.
        let shoulderR = point(joy ? 0.76 : (hugging ? 0.78 : 0.73), joy ? 0.59 : (hugging ? 0.67 : 0.53))
        let wristL: CGPoint, wristR: CGPoint, nod: CGFloat, star: CGPoint?
        let pawAngleL: CGFloat, pawAngleR: CGFloat
        switch performance {
        case .joyfulRaise:
            let beats: [CGFloat] = [0, 0.12, 0.23, 0.38, 0.50, 0.67, 0.84, 1]
            // The hands travel below/outside the shoulders on the way up.
            // A direct chord passes too near the IK origin and whips the elbow.
            // Phase .23 is the middle of the lift, not another anticipation.
            // Carry the hands through it instead of stopping halfway up.
            wristL = path(phase, times: beats, points: [point(0.45,0.65), point(0.40,0.77), point(0.12,0.72), point(-0.025,0.38), point(0.04,0.43), point(-0.01,0.36), point(0.03,0.43), point(0.02,0.40)], passingThrough: [2])
            wristR = path(phase, times: beats, points: [point(0.62,0.64), point(0.66,0.77), point(0.95,0.72), point(1.035,0.36), point(0.98,0.43), point(1.015,0.35), point(0.975,0.43), point(0.99,0.40)], passingThrough: [2])
            nod = interpolate(phase, times: beats, values: [0, 0.03, 0.01, -0.03, 0.02, -0.02, 0.012, 0])
            pawAngleL = -.pi / 2; pawAngleR = .pi / 2; star = nil
        case .starHug:
            let beats: [CGFloat] = [0, 0.12, 0.34, 0.58, 0.80, 1]
            // The early waypoint continues the lift; the cheek contact is the first hold.
            let center = path(phase, times: beats, points: [point(0.56,0.67), point(0.55,0.65), point(0.49,0.44), point(0.50,0.45), point(0.68,0.53), point(0.68,0.54)], passingThrough: [1])
            star = center
            wristL = point(center.x - 0.11, center.y + 0.035)
            wristR = point(center.x + 0.11, center.y + 0.04)
            nod = interpolate(phase, times: beats, values: [0, 0.025, 0.085, 0.07, 0.015, 0])
            pawAngleL = 0; pawAngleR = 0
        case .gentleRetry:
            let beats: [CGFloat] = [0, 0.12, 0.36, 0.58, 0.86, 1]
            wristL = path(phase, times: beats, points: [point(0.46,0.63), point(0.45,0.65), point(0.40,0.76), point(0.40,0.76), point(0.45,0.63), point(0.45,0.63)])
            wristR = path(phase, times: beats, points: [point(0.61,0.63), point(0.62,0.65), point(0.66,0.77), point(0.66,0.77), point(0.66,0.76), point(0.66,0.76)])
            nod = interpolate(phase, times: beats, values: [0, 0.025, 0.12, 0.12, 0.015, 0.02])
            pawAngleL = 0; pawAngleR = 0; star = nil
        }
        let left = arm(shoulder: shoulderL, wrist: wristL, length: joy ? 0.20 : 0.18, bend: joy ? -1 : 1)
        let right = arm(shoulder: shoulderR, wrist: wristR, length: joy ? 0.20 : 0.18, bend: joy ? 1 : -1)
        var parts: [ResultRigPart: ResultRigPartPose] = [:]
        func sprite(_ part: ResultRigPart, _ center: CGPoint, _ width: CGFloat, _ height: CGFloat, _ angle: CGFloat = 0) {
            parts[part] = ResultRigPartPose(center: center, size: CGSize(width: width, height: height), rotation: angle)
        }
        func segment(_ part: ResultRigPart, _ start: CGPoint, _ end: CGPoint, _ width: CGFloat) {
            sprite(part, point((start.x + end.x) / 2, (start.y + end.y) / 2), width,
                   hypot(end.x - start.x, end.y - start.y) / 0.64,
                   atan2(end.y - start.y, end.x - start.x) - .pi / 2)
        }
        sprite(.torso, point(0.48,0.665), 0.74, 0.59)
        let footTurn = joy ? interpolate(phase, times: [0, 0.36, 0.50, 0.67, 0.84, 1], values: [0, 0.065, 0, 0.045, 0, 0]) : 0
        sprite(.leftFoot, point(0.32,0.88), 0.20, 0.185, -footTurn)
        sprite(.rightFoot, point(0.70,0.88), 0.20, 0.185, footTurn)
        segment(.leftUpperArm, left.shoulder, left.elbow, 0.17)
        segment(.rightUpperArm, right.shoulder, right.elbow, 0.17)
        segment(.leftForearm, left.elbow, left.wrist, 0.15)
        segment(.rightForearm, right.elbow, right.wrist, 0.15)
        sprite(performance == .gentleRetry ? .sadHead : .happyHead, point(0.55,0.31 + abs(nod) * 0.3), 0.79, 0.566, nod)
        if let star { sprite(.star, star, 0.29, 0.278) }
        sprite(.leftPaw, left.wrist, 0.12, 0.12, pawAngleL)
        sprite(.rightPaw, right.wrist, 0.12, 0.12, pawAngleR)
        return ResultRigPose(parts: parts, leftArm: left, rightArm: right)
    }

    /// CALayer interpolation must not turn a wrap at -π/+π into a full spin.
    static func unwrapped(_ angles: [CGFloat]) -> [CGFloat] {
        var output: [CGFloat] = []
        for angle in angles {
            var value = angle
            if let previous = output.last {
                while value - previous > .pi { value -= 2 * .pi }
                while value - previous < -.pi { value += 2 * .pi }
            }
            output.append(value)
        }
        return output
    }
}
