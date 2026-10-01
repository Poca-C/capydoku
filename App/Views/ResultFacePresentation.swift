import UIKit

/// Local raster features share the result choreography's clock. The owner keeps
/// the head base static and decides whether motion is permitted; this object
/// neither creates another event nor schedules a task, timer or repeating loop.
@MainActor final class ResultFacePresentation {
    private weak var head: CALayer?
    private var parts: ResultFaceParts?
    private let openEyes = CALayer()
    private let closedEyes = CALayer()
    private let restMouth = CALayer()
    private let activeMouth = CALayer()
    private var featureLayers: [CALayer] { [openEyes, closedEyes, restMouth, activeMouth] }

    init() {
        for (layer, name) in zip(featureLayers, ["eyes-open", "eyes-closed", "mouth-rest", "mouth-active"]) {
            layer.name = "result-face-" + name
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            layer.minificationFilter = .linear
        }
        restoreModelState()
    }

    deinit {
        for layer in [openEyes, closedEyes, restMouth, activeMouth] {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
    }

    func configure(parts: ResultFaceParts?, on head: CALayer?) {
        guard let parts, let head else {
            cancel()
            featureLayers.forEach { $0.removeFromSuperlayer() }
            self.parts = nil; self.head = nil
            return
        }
        let sameArtwork = self.parts.map {
            $0.base === parts.base && $0.openEyes.image === parts.openEyes.image &&
            $0.closedEyes.image === parts.closedEyes.image && $0.restMouth.image === parts.restMouth.image &&
            $0.activeMouth.image === parts.activeMouth.image
        } ?? false
        if self.head !== head || !sameArtwork {
            cancel()
            featureLayers.forEach { $0.removeFromSuperlayer() }
        }
        self.head = head; self.parts = parts
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (layer, feature) in zip(featureLayers, [parts.openEyes, parts.closedEyes, parts.restMouth, parts.activeMouth]) {
            if layer.superlayer !== head { head.addSublayer(layer) }
            layer.contents = feature.image.cgImage
            layer.contentsScale = feature.image.scale
            let frame = feature.frame
            layer.bounds = CGRect(x: 0, y: 0, width: head.bounds.width * frame.width,
                                  height: head.bounds.height * frame.height)
            layer.position = CGPoint(x: head.bounds.minX + head.bounds.width * frame.midX,
                                     y: head.bounds.minY + head.bounds.height * frame.midY)
        }
        CATransaction.commit()
        // Layout updates never touch the active animation or restart its clock.
    }

    func play(performance: ResultCharacterPerformance, duration: TimeInterval, startTime: CFTimeInterval) {
        cancel()
        guard let head, parts != nil, !head.bounds.isEmpty, duration.isFinite, duration > 0,
              startTime.isFinite, featureLayers.allSatisfy({ $0.superlayer === head }) else { return }
        let eyeTimes: [NSNumber]
        let eyeValues: [Double]
        let mouthTimes: [NSNumber]
        switch performance {
        case .joyfulRaise:
            // Two brief happy blinks accompany the lift and its smaller bounce.
            eyeTimes = [0, 0.16, 0.19, 0.27, 0.30, 0.54, 0.57, 0.62, 0.65, 1]
            eyeValues = [0, 0, 1, 1, 0, 0, 1, 1, 0, 0]
            mouthTimes = [0, 0.16, 0.20, 0.76, 0.80, 1]
        case .starHug:
            eyeTimes = [0, 0.30, 0.34, 0.45, 0.49, 1]
            eyeValues = [0, 0, 1, 1, 0, 0]
            mouthTimes = [0, 0.24, 0.28, 0.76, 0.81, 1]
        case .gentleRetry:
            // The lids soften during the nod; the exhale mouth remains briefly
            // after they reopen, rather than switching the entire face at once.
            eyeTimes = [0, 0.20, 0.29, 0.54, 0.65, 1]
            eyeValues = [0, 0, 1, 1, 0, 0]
            mouthTimes = [0, 0.32, 0.36, 0.72, 0.77, 1]
        }
        transition(rest: openEyes, active: closedEyes, times: eyeTimes, activeValues: eyeValues,
                   compressedScale: 0.84, duration: duration, startTime: startTime)
        transition(rest: restMouth, active: activeMouth, times: mouthTimes, activeValues: [0, 0, 1, 1, 0, 0],
                   compressedScale: 0.90, duration: duration, startTime: startTime)
    }

    func cancel() {
        featureLayers.forEach { $0.removeAllAnimations() }
        restoreModelState()
    }

    private func restoreModelState() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        openEyes.opacity = 1; closedEyes.opacity = 0
        restMouth.opacity = 1; activeMouth.opacity = 0
        featureLayers.forEach { $0.transform = CATransform3DIdentity }
        CATransaction.commit()
    }

    private func transition(rest: CALayer, active: CALayer, times: [NSNumber], activeValues: [Double],
                            compressedScale: CGFloat, duration: TimeInterval, startTime: CFTimeInterval) {
        var switches: [NSNumber] = [0]
        var states = [activeValues[0]]
        var scaleTimes: [NSNumber] = [0]
        var scales: [CGFloat] = [1]
        for index in 1..<times.count where activeValues[index] != activeValues[index - 1] {
            let lower = times[index - 1].doubleValue, upper = times[index].doubleValue
            let middle = (lower + upper) / 2
            // Keep the authored transition window. Its outgoing raster closes
            // slightly, switches at the compressed midpoint, then opens as the
            // incoming raster. Registered images never crossfade or coexist.
            switches.append(NSNumber(value: middle)); states.append(activeValues[index])
            if lower > scaleTimes.last!.doubleValue {
                scaleTimes.append(NSNumber(value: lower)); scales.append(1)
            }
            scaleTimes.append(contentsOf: [NSNumber(value: middle), NSNumber(value: upper)])
            scales.append(contentsOf: [compressedScale, 1])
        }
        // Discrete keyTimes bound intervals: they require one more endpoint
        // than values. The final held state is already the static model state.
        switches.append(1)
        if scaleTimes.last!.doubleValue < 1 { scaleTimes.append(1); scales.append(1) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (layer, values) in [(rest, states.map { 1 - $0 }), (active, states)] {
            let visible = CAKeyframeAnimation(keyPath: "opacity")
            visible.keyTimes = switches
            visible.values = values
            visible.calculationMode = .discrete
            visible.duration = duration
            visible.beginTime = layer.convertTime(startTime, from: nil)
            let closure = CAKeyframeAnimation(keyPath: "transform.scale.y")
            closure.keyTimes = scaleTimes
            closure.values = scales
            closure.calculationMode = .linear
            closure.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: scales.count - 1)
            closure.duration = duration
            closure.beginTime = visible.beginTime
            // Both rasters share the exact envelope/clock, but only one is
            // visible. Normal removal and cancellation restore identity.
            layer.add(visible, forKey: "result-face-expression")
            layer.add(closure, forKey: "result-face-closure")
        }
        CATransaction.commit()
    }
}
