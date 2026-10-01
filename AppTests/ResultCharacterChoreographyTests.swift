import XCTest
import UIKit
@testable import Capydoku

@MainActor private final class CharacterChoreographyRig {
    let window: UIWindow
    let view: ResultCharacterUIView
    private let previous: UIWindow?
    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.ink)
        window.rootViewController = controller; window.makeKeyAndVisible()
        view = ResultCharacterUIView(frame: CGRect(x: 30, y: 120, width: 168, height: 168))
        controller.view.addSubview(view); view.layoutIfNeeded()
    }
    func configure(_ performance: ResultCharacterPerformance, event: UUID?, reduceMotion: Bool = false) {
        view.configure(won: performance != .gentleRetry,
            variant: performance == .starHug ? .proudCrown : .joyfulBounce,
            animationID: event, reduceMotion: reduceMotion, presentationEnabled: true, lowPower: false)
        view.layoutIfNeeded()
    }
    func close() {
        view.cancelPresentation(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
    }
}

final class ResultCharacterChoreographyTests: XCTestCase {
    private func pixels(_ source: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
        let succeeded = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            return true
        }
        XCTAssertTrue(succeeded)
        return bytes
    }

    @MainActor func testAllNineBundledPosesAreDistinctTransparentCompleteSquareImages() throws {
        var identities = Set<Data>()
        for performance in ResultCharacterPerformance.allCases {
            let source = try XCTUnwrap(UIImage(named: performance.assetName)?.cgImage)
            XCTAssertEqual(source.width, source.height * 3, "Atlas cells must be complete equal squares")
            let poses = ResultCharacterArtwork.poses(for: performance)
            XCTAssertEqual(poses.count, 3)
            for pose in poses {
                let image = try XCTUnwrap(pose.cgImage)
                XCTAssertEqual(image.width, 512); XCTAssertEqual(image.height, 512)
                let data = try pixels(image)
                identities.insert(Data(data))
                let alpha = stride(from: 3, to: data.count, by: 4).map { data[$0] }
                let transparent = alpha.filter { $0 == 0 }.count
                let opaque = alpha.filter { $0 > 240 }.count
                XCTAssertGreaterThan(transparent, image.width * image.height / 5, "Transparent space must not be a baked matte")
                XCTAssertGreaterThan(opaque, image.width * image.height / 4, "A real full-body pose must be present")
                for x in 0..<image.width {
                    XCTAssertLessThanOrEqual(alpha[x], 16, "No visible artwork may touch the atlas seam")
                    XCTAssertLessThanOrEqual(alpha[(image.height - 1) * image.width + x], 16)
                }
                for y in 0..<image.height {
                    XCTAssertLessThanOrEqual(alpha[y * image.width], 16, "Adjacent poses may not visibly bleed into one another")
                    XCTAssertLessThanOrEqual(alpha[y * image.width + image.width - 1], 16)
                }
            }
        }
        XCTAssertEqual(identities.count, 9, "Each key pose must contain distinct drawn pixels")
    }

    @MainActor func testMissingOrMalformedAtlasFallsBackOnceWithoutCrashingOrReusingAnotherPerformance() throws {
        let fallback = try XCTUnwrap(UIImage(named: "CapyMascot"))
        let malformed = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 40, height: 20)) }
        var calls: [String] = []
        let cache = ResultCharacterImageCache { name in
            calls.append(name)
            return name == ResultCharacterPerformance.starHug.assetName ? malformed : (name == "CapyMascot" ? fallback : nil)
        }
        XCTAssertEqual(cache.poses(for: .starHug).count, 3)
        XCTAssertEqual(cache.poses(for: .starHug).count, 3)
        XCTAssertEqual(calls.filter { $0 == ResultCharacterPerformance.starHug.assetName }.count, 1)
        XCTAssertTrue(cache.poses(for: .gentleRetry).isEmpty)
        XCTAssertTrue(cache.poses(for: .gentleRetry).isEmpty)
        XCTAssertEqual(calls.filter { $0 == "CapySad" }.count, 1)
    }

    @MainActor func testFreshResultUsesRealPoseContentsAndCancellationImmediatelyRestoresFinalPose() throws {
        let rig = try CharacterChoreographyRig(); defer { rig.close() }
        for performance in ResultCharacterPerformance.allCases {
            rig.configure(performance, event: nil)
            let character = try XCTUnwrap(rig.view.layer.sublayers?.first { $0.name == "result-character" })
            let settled = try XCTUnwrap(character.contents) as AnyObject
            let expected = try XCTUnwrap(ResultCharacterArtwork.poses(for: performance).last?.cgImage)
            XCTAssertTrue(settled === expected, "The layer must retain the cached terminal pose")
            XCTAssertNil(character.animation(forKey: "result-pose-sequence"))
            rig.configure(performance, event: UUID())
            let sequence = try XCTUnwrap(character.animation(forKey: "result-pose-sequence") as? CAKeyframeAnimation)
            XCTAssertEqual(sequence.calculationMode, .discrete)
            let images = try XCTUnwrap(sequence.values as? [CGImage])
            XCTAssertEqual(Set(try images.map { Data(try pixels($0)) }).count, 3)
            XCTAssertEqual(sequence.repeatCount, 0); XCTAssertLessThanOrEqual(sequence.duration, 1.2)
            rig.view.cancelPresentation()
            XCTAssertNil(character.animation(forKey: "result-pose-sequence"))
            let cancelled = try XCTUnwrap(character.contents) as AnyObject
            XCTAssertTrue(cancelled === expected, "Cancelling must expose the same terminal pose immediately")
        }
    }

    @MainActor func testReducedMotionRetainsExpressiveFinalPoseWithoutAnyMotionOrLaterReplay() throws {
        let rig = try CharacterChoreographyRig(); defer { rig.close() }
        for performance in ResultCharacterPerformance.allCases {
            let event = UUID(); rig.configure(performance, event: event, reduceMotion: true)
            let character = try XCTUnwrap(rig.view.layer.sublayers?.first { $0.name == "result-character" })
            XCTAssertTrue(character.animationKeys()?.isEmpty ?? true)
            let expected = try XCTUnwrap(ResultCharacterArtwork.poses(for: performance).last?.cgImage)
            let settled = try XCTUnwrap(character.contents) as AnyObject
            XCTAssertTrue(settled === expected, "Reduce Motion still displays the expressive terminal pose")
            rig.configure(performance, event: event)
            XCTAssertEqual(rig.view.playedEventCount, 0)
        }
    }

    @MainActor func testPoseTimingUsesOneOpaqueCharacterAndGroundedPerPhaseMotion() throws {
        let rig = try CharacterChoreographyRig(); defer { rig.close() }
        for performance in ResultCharacterPerformance.allCases {
            rig.configure(performance, event: UUID())
            let character = try XCTUnwrap(rig.view.layer.sublayers?.first { $0.name == "result-character" })
            XCTAssertEqual(character.anchorPoint.x, 0.5, accuracy: 0.0001)
            XCTAssertEqual(character.anchorPoint.y, 0.96, accuracy: 0.0001)
            XCTAssertEqual(character.opacity, 1)
            XCTAssertEqual(rig.view.layer.sublayers?.filter { $0.contents != nil }.count, 1,
                "There is one complete silhouette; pose changes must not crossfade doubled faces/paws")
            let poses = try XCTUnwrap(character.animation(forKey: "result-pose-sequence") as? CAKeyframeAnimation)
            XCTAssertEqual(poses.calculationMode, .discrete)
            XCTAssertNil(character.animation(forKey: "result-opacity"))
            XCTAssertNil(character.animation(forKey: "result-transform.scale"), "Squash uses independent axes around the feet")
            for key in ["transform.scale.x", "transform.scale.y", "transform.rotation.z"] {
                let motion = try XCTUnwrap(character.animation(forKey: "result-" + key) as? CAKeyframeAnimation)
                XCTAssertEqual(motion.beginTime, poses.beginTime, accuracy: 0.0001)
                XCTAssertEqual(motion.duration, poses.duration)
                XCTAssertNil(motion.timingFunction, "Global easing would move motion beats away from fixed pose changes")
                XCTAssertEqual(motion.timingFunctions?.count, try XCTUnwrap(motion.keyTimes).count - 1)
            }
            if performance == .joyfulRaise {
                let translation = try XCTUnwrap(character.animation(forKey: "result-transform.translation.y") as? CAKeyframeAnimation)
                let values = try XCTUnwrap(translation.values as? [NSNumber])
                let times = try XCTUnwrap(translation.keyTimes)
                for contact in [0.43, 0.78] {
                    let index = try XCTUnwrap(times.firstIndex { abs($0.doubleValue - contact) < 0.0001 })
                    XCTAssertEqual(values[index].doubleValue, 0, accuracy: 0.0001, "Each landing returns to the ground plane")
                }
            } else if performance == .starHug {
                let sway = try XCTUnwrap(character.animation(forKey: "result-transform.rotation.z") as? CAKeyframeAnimation)
                let stops = try XCTUnwrap(sway.keyTimes).map(\.doubleValue)
                XCTAssertFalse(stops.contains(0.20)); XCTAssertFalse(stops.contains(0.66),
                    "The star moves while the character is leaning, not during a stationary pose swap")
            } else {
                XCTAssertNil(character.animation(forKey: "result-transform.translation.y"),
                    "A seated sigh may squash at the feet but must not push them through the ground")
            }
        }
    }

    /// Replays the exact 0.2.27 body transforms over unchanged production pose
    /// assets. This is comparison evidence, not another production animation path.
    @MainActor private func installLegacyBodyMotion(on view: ResultCharacterUIView, performance: ResultCharacterPerformance) throws {
        let character = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "result-character" })
        let shadow = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "result-ground-shadow" })
        let poses = try XCTUnwrap(character.animation(forKey: "result-pose-sequence"))
        let duration = poses.duration, start = poses.beginTime, side = min(view.bounds.width, view.bounds.height)
        for key in character.animationKeys() ?? [] where key != "result-pose-sequence" { character.removeAnimation(forKey: key) }
        shadow.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        character.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        character.frame = CGRect(x: side * 0.10, y: side * 0.13, width: side * 0.80, height: side * 0.80)
        CATransaction.commit()
        func add(_ target: CALayer, _ key: String, _ values: [CGFloat], _ times: [NSNumber]) {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values; animation.keyTimes = times; animation.duration = duration
            animation.beginTime = start; animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            target.add(animation, forKey: "result-" + key)
        }
        switch performance {
        case .joyfulRaise:
            add(character, "transform.translation.y", [0, 2, -side * 0.07, 0, -side * 0.045, 0, 0], [0, 0.10, 0.27, 0.43, 0.61, 0.78, 1])
            add(character, "transform.scale", [1, 0.97, 1.03, 0.97, 1.02, 1, 1], [0, 0.10, 0.27, 0.43, 0.61, 0.78, 1])
            add(character, "transform.rotation.z", [0, -0.055, 0.055, -0.04, 0.035, 0], [0, 0.23, 0.42, 0.61, 0.78, 1])
            add(shadow, "transform.scale", [1, 0.70, 1, 0.78, 1], [0, 0.27, 0.43, 0.61, 1])
        case .starHug:
            add(character, "transform.rotation.z", [0, -0.085, 0.085, -0.04, 0.025, 0], [0, 0.20, 0.44, 0.64, 0.81, 1])
            add(character, "transform.scale", [1, 1.035, 1.02, 1], [0, 0.24, 0.72, 1])
        case .gentleRetry:
            add(character, "transform.translation.y", [0, side * 0.022, side * 0.022, 0], [0, 0.28, 0.70, 1])
            add(character, "transform.rotation.z", [0, 0.04, -0.025, 0.022, 0], [0, 0.23, 0.43, 0.63, 1])
            add(character, "transform.scale.y", [1, 0.97, 0.97, 1], [0, 0.28, 0.70, 1])
        }
    }

    @MainActor func testActualHostCapturesOldAndNewMotionAroundPoseChangesWithoutBlendedSilhouettes() async throws {
        for performance in ResultCharacterPerformance.allCases {
            var samples: [UIImage] = []
            var sampleTiming: [String] = []
            let phases: [Double] = performance == .joyfulRaise ? [0.12, 0.19, 0.26, 0.38, 0.45, 0.52]
                : performance == .starHug ? [0.15, 0.22, 0.29, 0.61, 0.68, 0.75] : [0.15, 0.22, 0.29, 0.67, 0.74, 0.81]
            for legacy in [true, false] {
                let rig = try CharacterChoreographyRig(); defer { rig.close() }
                // Capture a running presentation tree in a real UIWindow.
                // Pausing before its first commit can capture the model at the
                // first sample, so never seek or fall back to that model here.
                rig.view.schedule = { _, _ in }
                rig.configure(performance, event: UUID())
                if legacy { try installLegacyBodyMotion(on: rig.view, performance: performance) }
                let character = try XCTUnwrap(rig.view.layer.sublayers?.first { $0.name == "result-character" })
                let poses = try XCTUnwrap(character.animation(forKey: "result-pose-sequence"))
                CATransaction.flush()
                for phase in phases {
                    let targetTime = poses.beginTime + phase * poses.duration
                    let remaining = targetTime - character.convertTime(CACurrentMediaTime(), from: nil)
                    if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    let presented = try XCTUnwrap(rig.view.layer.presentation())
                    let presentedCharacter = try XCTUnwrap(character.presentation())
                    if phase == phases.first {
                        XCTAssertFalse(CATransform3DEqualToTransform(presentedCharacter.transform, character.transform),
                            "The first sample must capture active body motion, not the static model layer")
                    }
                    let actualPhase = (character.convertTime(CACurrentMediaTime(), from: nil) - poses.beginTime) / poses.duration
                    sampleTiming.append("\(legacy ? "0227" : "0228") target=\(phase) actual=\(actualPhase)")
                    let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
                    samples.append(UIGraphicsImageRenderer(size: rig.view.bounds.size, format: format).image { context in
                        UIColor(CapyPalette.ink).setFill(); context.fill(rig.view.bounds)
                        presented.render(in: context.cgContext)
                    })
                    XCTAssertEqual(rig.view.layer.sublayers?.filter { $0.contents != nil }.count, 1)
                    XCTAssertFalse(rig.view.isUserInteractionEnabled)
                }
            }
            let tile: CGFloat = 168
            let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
            let strip = UIGraphicsImageRenderer(size: CGSize(width: tile * 6, height: tile * 2), format: format).image { _ in
                for (index, sample) in samples.enumerated() {
                    sample.draw(in: CGRect(x: CGFloat(index % 6) * tile, y: CGFloat(index / 6) * tile, width: tile, height: tile))
                }
            }
            let attachment = XCTAttachment(image: strip)
            attachment.name = "result-pose-boundaries-\(performance.rawValue)-top-0227-bottom-0228"
            attachment.lifetime = .keepAlways; add(attachment)
            let timing = XCTAttachment(string: sampleTiming.joined(separator: "\n"))
            timing.name = "result-pose-boundaries-\(performance.rawValue)-actual-sampling-times"
            timing.lifetime = .keepAlways; add(timing)
            XCTAssertEqual(samples.count, 12)
            XCTAssertNotEqual(samples[0].pngData(), samples[6].pngData(), "Grounded motion must create an actual visible change")
        }
    }

    @MainActor func testActualSmallHostCapturesAnticipationActionAndRecoveryForThreePerformances() async throws {
        let rig = try CharacterChoreographyRig(); defer { rig.close() }
        var samples: [UIImage] = []
        for performance in ResultCharacterPerformance.allCases {
            rig.configure(performance, event: UUID())
            var elapsed: UInt64 = 0
            for sample in [100_000_000, 350_000_000, 900_000_000] as [UInt64] {
                try await Task.sleep(nanoseconds: sample - elapsed); elapsed = sample
                let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
                samples.append(UIGraphicsImageRenderer(size: rig.view.bounds.size, format: format).image { context in
                    UIColor(CapyPalette.ink).setFill(); context.fill(rig.view.bounds)
                    (rig.view.layer.presentation() ?? rig.view.layer).render(in: context.cgContext)
                })
            }
            rig.view.cancelPresentation()
        }
        let tile: CGFloat = 168
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        let contactSheet = UIGraphicsImageRenderer(size: CGSize(width: tile * 3, height: tile * 3), format: format).image { context in
            UIColor(CapyPalette.ink).setFill(); context.fill(CGRect(x: 0, y: 0, width: tile * 3, height: tile * 3))
            for (index, sample) in samples.enumerated() {
                sample.draw(in: CGRect(x: CGFloat(index % 3) * tile, y: CGFloat(index / 3) * tile, width: tile, height: tile))
            }
        }
        let attachment = XCTAttachment(image: contactSheet)
        attachment.name = "result-real-pose-choreography-rows-joy-star-retry-columns-100-350-900ms"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(samples.count, 9)
        for row in 0..<3 {
            XCTAssertNotEqual(samples[row * 3].pngData(), samples[row * 3 + 1].pngData())
            XCTAssertNotEqual(samples[row * 3 + 1].pngData(), samples[row * 3 + 2].pngData())
        }
    }
}
