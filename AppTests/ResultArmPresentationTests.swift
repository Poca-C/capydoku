import XCTest
import UIKit
@testable import Capydoku

@MainActor private final class ResultArmHost {
    let window: UIWindow
    let view: ResultCharacterUIView
    private let previous: UIWindow?

    init(side: CGFloat = 250, missingRig: Bool = false) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.ink)
        window.rootViewController = controller; window.makeKeyAndVisible()
        view = ResultCharacterUIView(frame: CGRect(x: 30, y: 110, width: side, height: side),
            prepareRig: missingRig ? { false } : ResultCharacterArtwork.prewarmRig)
        controller.view.addSubview(view); view.layoutIfNeeded()
    }

    func configure(_ performance: ResultCharacterPerformance, event: UUID?, reduceMotion: Bool = false,
                   lowPower: Bool = false) {
        view.configure(won: performance != .gentleRetry,
            variant: performance == .starHug ? .proudCrown : .joyfulBounce,
            animationID: event, reduceMotion: reduceMotion, presentationEnabled: true, lowPower: lowPower)
        view.layoutIfNeeded()
    }

    func close() {
        view.cancelPresentation(); window.isHidden = true; window.rootViewController = nil
        previous?.makeKeyAndVisible()
    }
}

final class ResultArmPresentationTests: XCTestCase {
    private func hasCrossingRails(_ nodes: [CGPoint]) -> Bool {
        let polygon = Array(nodes.dropLast()) // The closure repeats the shoulder.
        guard polygon.count > 3 else { return false }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        for i in 0..<(polygon.count - 1) {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            for j in (i + 2)..<polygon.count where !(i == 0 && j == polygon.count - 1) {
                let c = polygon[j], d = polygon[(j + 1) % polygon.count]
                if cross(a, b, c) * cross(a, b, d) < -0.00000001 &&
                   cross(c, d, a) * cross(c, d, b) < -0.00000001 { return true }
            }
        }
        return false
    }

    @MainActor private func layers(_ root: CALayer) -> [CALayer] {
        [root] + (root.sublayers ?? []).flatMap(layers) + (root.mask.map(layers) ?? [])
    }

    @MainActor private func modelPixels(_ view: UIView) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(bounds: view.bounds, format: format).image {
            view.layer.render(in: $0.cgContext)
        }.cgImage?.dataProvider?.data) as Data
    }

    func testAllSleeveSamplesKeepOneContinuousPathWithStableTopologyAndOriginalEndpoints() {
        for performance in ResultCharacterPerformance.allCases {
            for pose in ResultRigMotion.samples(performance) {
                for arm in [pose.leftArm, pose.rightArm] {
                    let geometry = ResultArmGeometry(arm: arm, size: CGSize(width: 190, height: 190))
                    var types: [CGPathElementType] = [], starts: [CGPoint] = [], ends: [CGPoint] = []
                    geometry.centerline.applyWithBlock { element in
                        types.append(element.pointee.type)
                        if element.pointee.type == .moveToPoint { starts.append(element.pointee.points[0]) }
                        if element.pointee.type == .addLineToPoint { ends.append(element.pointee.points[0]) }
                    }
                    XCTAssertEqual(types, [.moveToPoint, .addLineToPoint, .addQuadCurveToPoint, .addLineToPoint])
                    XCTAssertEqual(starts, [CGPoint(x: arm.shoulder.x * 190, y: arm.shoulder.y * 190)])
                    XCTAssertEqual(ends.last, CGPoint(x: arm.wrist.x * 190, y: arm.wrist.y * 190))
                    XCTAssertFalse(geometry.centerline.isEmpty)
                    var contourTypes: [CGPathElementType] = [], nodes: [CGPoint] = []
                    geometry.contour.applyWithBlock { element in
                        contourTypes.append(element.pointee.type)
                        if element.pointee.type == .moveToPoint { nodes.append(element.pointee.points[0]) }
                        if element.pointee.type == .addCurveToPoint { nodes.append(element.pointee.points[2]) }
                    }
                    XCTAssertEqual(contourTypes, [.moveToPoint] + Array(repeating: .addCurveToPoint, count: 66) + [.closeSubpath],
                        "Every sample must retain one closed silhouette with identical morph topology")
                    XCTAssertEqual(nodes.count, 67)
                    guard nodes.count == 67 else { continue }
                    XCTAssertTrue(nodes.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                    XCTAssertFalse(hasCrossingRails(nodes), "A tightly folded elbow must not turn its sampled inner rail into a loop")
                    let leftWrist = nodes[32], rightWrist = nodes[34]
                    XCTAssertEqual(hypot(leftWrist.x - rightWrist.x, leftWrist.y - rightWrist.y) / 190, 0.074, accuracy: 0.000001)
                    XCTAssertEqual((leftWrist.x + rightWrist.x) / 2, arm.wrist.x * 190, accuracy: 0.000001)
                    XCTAssertEqual((leftWrist.y + rightWrist.y) / 2, arm.wrist.y * 190, accuracy: 0.000001)
                    XCTAssertLessThan(0.074 * 190 + geometry.outlineWidth, 0.12 * 190,
                        "Even including its ink, the tapered wrist must fit inside the original paw width")
                    XCTAssertEqual(geometry.maximumWidth / 190, 0.128, accuracy: 0.000001)
                }
            }
        }
    }

    @MainActor func testContinuousSleevesShareJointClockAndPreserveTorsoOcclusionWithoutSeparateElbowCaps() throws {
        let host = try ResultArmHost(); defer { host.close() }
        for performance in ResultCharacterPerformance.allCases {
            let event = UUID(); host.configure(performance, event: event)
            let character = try XCTUnwrap(host.view.layer.sublayers?.first { $0.name == "result-character" })
            let children = try XCTUnwrap(character.sublayers)
            let torso = try XCTUnwrap(children.firstIndex { $0.name == "result-rig-torso" })
            let head = try XCTUnwrap(children.first { $0.name == (performance == .gentleRetry ? "result-rig-sadHead" : "result-rig-happyHead") })
            let headClock = try XCTUnwrap(head.animation(forKey: "result-rig-position"))
            let beforeStarts = layers(character).compactMap { $0.animation(forKey: "result-arm-contour")?.beginTime }
            XCTAssertEqual(beforeStarts.count, 14, "Two depths × three contour layers × two arms, plus two forearm masks")
            for side in ["left", "right"] {
                let backIndex = try XCTUnwrap(children.firstIndex { $0.name == "result-arm-\(side)-back" })
                let frontIndex = try XCTUnwrap(children.firstIndex { $0.name == "result-arm-\(side)-front" })
                XCTAssertLessThan(backIndex, torso); XCTAssertGreaterThan(frontIndex, torso)
                XCTAssertLessThan(frontIndex, try XCTUnwrap(children.firstIndex { $0 === head }))
                let back = children[backIndex], front = children[frontIndex]
                XCTAssertNil(back.mask); XCTAssertNotNil(front.mask)
                let backInk = try XCTUnwrap(back.sublayers?.first { $0.name?.hasSuffix("-outline") == true } as? CAShapeLayer)
                let frontInk = try XCTUnwrap(front.sublayers?.first { $0.name?.hasSuffix("-outline") == true } as? CAShapeLayer)
                XCTAssertTrue(try XCTUnwrap(backInk.path) == XCTUnwrap(frontInk.path))
                XCTAssertEqual(backInk.strokeColor, frontInk.strokeColor)
                XCTAssertEqual(backInk.lineWidth, frontInk.lineWidth)
                XCTAssertNotNil(backInk.fillColor, "Use one closed filled silhouette, not a wide open-ended stroke")
                var closed = false
                backInk.path?.applyWithBlock { if $0.pointee.type == .closeSubpath { closed = true } }
                XCTAssertTrue(closed)
                for shape in [backInk, frontInk] {
                    let animation = try XCTUnwrap(shape.animation(forKey: "result-arm-contour") as? CAKeyframeAnimation)
                    XCTAssertEqual(animation.values?.count, 73)
                    XCTAssertEqual(animation.keyTimes, ResultRigMotion.phases.map { NSNumber(value: Double($0)) })
                    XCTAssertEqual(animation.beginTime, headClock.beginTime, accuracy: 0.000001)
                    XCTAssertEqual(animation.duration, headClock.duration)
                    XCTAssertEqual(animation.repeatCount, 0)
                }
            }
            host.configure(performance, event: event)
            XCTAssertEqual(layers(character).compactMap { $0.animation(forKey: "result-arm-contour")?.beginTime }, beforeStarts)
        }
    }

    @MainActor func testActualContinuousSleevesAtThreeSizesStayInsideViewportAndReachOriginalPaws() async throws {
        for side: CGFloat in [140, 168, 250] {
            let host = try ResultArmHost(side: side); defer { host.close() }
            for performance in ResultCharacterPerformance.allCases {
                host.configure(performance, event: UUID())
                try await Task.sleep(nanoseconds: 470_000_000)
                let root = try XCTUnwrap(host.view.layer.presentation())
                let character = try XCTUnwrap(root.sublayers?.first { $0.name == "result-character" })
                for hand in ["left", "right"] {
                    let sleeve = try XCTUnwrap(character.sublayers?.first { $0.name == "result-arm-\(hand)-back" })
                    let ink = try XCTUnwrap(sleeve.sublayers?.first { $0.name?.hasSuffix("-outline") == true } as? CAShapeLayer)
                    let contour = try XCTUnwrap(ink.path)
                    let occupied = contour.copy(strokingWithWidth: ink.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1).boundingBoxOfPath
                    XCTAssertTrue(host.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(ink.convert(occupied, to: root)),
                        "\(performance) \(side) \(hand) continuous ink must stay in the result viewport")
                    let front = try XCTUnwrap(character.sublayers?.first { $0.name == "result-arm-\(hand)-front" })
                    let mask = try XCTUnwrap((front.mask?.presentation() ?? front.mask) as? CAShapeLayer)
                    let wrist = mask.convert(try XCTUnwrap(mask.path).currentPoint, to: character)
                    let paw = try XCTUnwrap(character.sublayers?.first { $0.name == "result-rig-\(hand)Paw" })
                    XCTAssertLessThan(hypot(wrist.x - paw.position.x, wrist.y - paw.position.y), 0.25,
                        "Both the contour and original paw must use the same interpolated wrist")
                }
                let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image {
                    UIColor(CapyPalette.ink).setFill(); $0.fill(host.view.bounds); root.render(in: $0.cgContext)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "result-arm-continuous-\(performance.rawValue)-\(Int(side))pt-live-470ms"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    @MainActor func testActualBodyFollowKeepsShouldersRegisteredAndPartsInBoundsAcrossThreePerformancesAndSizes() async throws {
        for side: CGFloat in [140, 168, 250] {
            for performance in ResultCharacterPerformance.allCases {
                let host = try ResultArmHost(side: side); defer { host.close() }
                let targets: [Double]
                let shoulders: [CGPoint]
                switch performance {
                case .joyfulRaise:
                    targets = [0.32, 0.50]
                    shoulders = [CGPoint(x: 0.29, y: 0.59), CGPoint(x: 0.76, y: 0.59)]
                case .starHug:
                    targets = [0.34, 0.80]
                    shoulders = [CGPoint(x: 0.28, y: 0.61), CGPoint(x: 0.78, y: 0.67)]
                case .gentleRetry:
                    targets = [0.36, 0.86]
                    shoulders = [CGPoint(x: 0.31, y: 0.54), CGPoint(x: 0.73, y: 0.53)]
                }
                // Registration comes from the unchanged torso artwork layout,
                // not from evaluating the moving production pose a second time.
                let shoulderRegistration = shoulders.map {
                    CGPoint(x: 0.5 + ($0.x - 0.48) / 0.74,
                            y: 0.5 + ($0.y - 0.665) / 0.59)
                }
                host.configure(performance, event: UUID())
                let model = try XCTUnwrap(host.view.layer.sublayers?.first { $0.name == "result-character" })
                let modelTorso = try XCTUnwrap(model.sublayers?.first { $0.name == "result-rig-torso" })
                let clock = try XCTUnwrap(modelTorso.animation(forKey: "result-rig-position"))
                let expectedDuration = performance == .joyfulRaise ? 1.05 : performance == .starHug ? 1.20 : 0.92
                XCTAssertEqual(clock.duration, expectedDuration, accuracy: 0.000001)
                var samples: [[String: Double]] = []
                var captures: [(name: String, image: UIImage)] = []
                var capturedPhases: [Double] = []
                while true {
                    let phase = (modelTorso.convertTime(CACurrentMediaTime(), from: nil) - clock.beginTime) / clock.duration
                    if phase > 0.94 { break }
                    if phase >= 0.07, let root = host.view.layer.presentation(),
                       let character = root.sublayers?.first(where: { $0.name == "result-character" }) {
                        let torso = try XCTUnwrap(character.sublayers?.first { $0.name == "result-rig-torso" })
                        let viewport = host.view.bounds.insetBy(dx: -0.5, dy: -0.5)
                        // Includes the head, torso, both feet/paws, and held star
                        // when present. Transparent sleeve canvases are checked
                        // by their visible ink separately below.
                        let visibleParts = (character.sublayers ?? []).filter {
                            $0.opacity > 0 && $0.name?.hasPrefix("result-rig-") == true
                        }
                        XCTAssertEqual(visibleParts.count, performance == .starHug ? 7 : 6)
                        for part in visibleParts {
                            XCTAssertTrue(viewport.contains(character.convert(part.frame, to: root)),
                                "\(performance) \(side)pt phase \(phase): \(part.name ?? "part") must remain in the viewport")
                        }
                        var maximumShoulderError: CGFloat = 0
                        var maximumWristError: CGFloat = 0
                        for (index, hand) in ["left", "right"].enumerated() {
                            let sleeve = try XCTUnwrap(character.sublayers?.first { $0.name == "result-arm-\(hand)-back" })
                            let ink = try XCTUnwrap(sleeve.sublayers?.first { $0.name?.hasSuffix("-outline") == true } as? CAShapeLayer)
                            let contour = try XCTUnwrap(ink.path)
                            let occupied = contour.copy(strokingWithWidth: ink.lineWidth, lineCap: .round,
                                                        lineJoin: .round, miterLimit: 1).boundingBoxOfPath
                            XCTAssertTrue(viewport.contains(ink.convert(occupied, to: root)))
                            var shoulder: CGPoint?
                            contour.applyWithBlock { element in
                                if element.pointee.type == .moveToPoint { shoulder = element.pointee.points[0] }
                            }
                            let registered = ink.convert(try XCTUnwrap(shoulder), to: torso)
                            let expected = CGPoint(x: torso.bounds.minX + shoulderRegistration[index].x * torso.bounds.width,
                                                   y: torso.bounds.minY + shoulderRegistration[index].y * torso.bounds.height)
                            let shoulderError = hypot(registered.x - expected.x, registered.y - expected.y)
                            maximumShoulderError = max(maximumShoulderError, shoulderError)
                            XCTAssertLessThan(shoulderError, 0.25,
                                "The actual interpolated sleeve root must stay attached to the same point on the rotating torso")
                            let front = try XCTUnwrap(character.sublayers?.first { $0.name == "result-arm-\(hand)-front" })
                            let mask = try XCTUnwrap((front.mask?.presentation() ?? front.mask) as? CAShapeLayer)
                            let wrist = mask.convert(try XCTUnwrap(mask.path).currentPoint, to: character)
                            let paw = try XCTUnwrap(character.sublayers?.first { $0.name == "result-rig-\(hand)Paw" })
                            let wristError = hypot(wrist.x - paw.position.x, wrist.y - paw.position.y)
                            maximumWristError = max(maximumWristError, wristError)
                            XCTAssertLessThan(wristError, 0.25,
                                "Moving the shoulder must not detach the existing paw from its sleeve")
                        }
                        let lean = atan2(torso.transform.m12, torso.transform.m11)
                        samples.append(["phase": phase, "torsoLean": Double(lean),
                                        "shoulderRegistrationErrorPoints": Double(maximumShoulderError),
                                        "wristErrorPoints": Double(maximumWristError)])
                        if captures.count < targets.count, phase >= targets[captures.count] {
                            let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
                            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image {
                                UIColor(CapyPalette.ink).setFill(); $0.fill(host.view.bounds); root.render(in: $0.cgContext)
                            }
                            let moment = captures.isEmpty ? "lean" : "reverse"
                            captures.append(("body-follow-\(performance.rawValue)-\(Int(side))pt-\(moment)", image))
                            capturedPhases.append(phase)
                        }
                    }
                    // Let Core Animation run normally; never seek or freeze a
                    // presentation clock to manufacture a requested pose.
                    try await Task.sleep(nanoseconds: 8_000_000)
                }
                XCTAssertGreaterThan(samples.count, 12)
                XCTAssertTrue(samples.contains { ($0["phase"] ?? 1) < 0.20 })
                XCTAssertTrue(samples.contains { ($0["phase"] ?? 0) > 0.88 })
                XCTAssertTrue(samples.contains { ($0["torsoLean"] ?? 0) > 0.008 })
                XCTAssertTrue(samples.contains { ($0["torsoLean"] ?? 0) < -0.008 },
                    "Natural playback must sample both sides of the internal torso reversal")
                XCTAssertEqual(captures.count, 2)
                for (actual, target) in zip(capturedPhases, targets) {
                    XCTAssertLessThan(actual - target, 0.08,
                        "A late screenshot must not be labelled as the requested lean or reversal pose")
                }
                for (name, image) in captures {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                }
                let evidence: [String: Any] = ["performance": performance.rawValue, "sidePoints": Double(side),
                                                "durationSeconds": clock.duration, "targetPhases": targets,
                                                "capturedPhases": capturedPhases, "samples": samples]
                let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                let log = XCTAttachment(string: try XCTUnwrap(String(data: data, encoding: .utf8)))
                log.name = "body-follow-\(performance.rawValue)-\(Int(side))pt-natural-samples"
                log.lifetime = .keepAlways; add(log)
            }
        }
    }

    @MainActor func testSleeveCancellationAndBackgroundRestoreRemoveMaskAnimationsWithoutReplay() throws {
        let host = try ResultArmHost(); defer { host.close() }
        for performance in ResultCharacterPerformance.allCases {
            host.configure(performance, event: nil)
            let settled = try modelPixels(host.view)
            let event = UUID(); host.configure(performance, event: event)
            XCTAssertFalse(layers(host.view.layer).allSatisfy { $0.animationKeys()?.isEmpty ?? true })
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            XCTAssertTrue(layers(host.view.layer).allSatisfy { $0.animationKeys()?.isEmpty ?? true })
            XCTAssertEqual(try modelPixels(host.view), settled)
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            host.configure(performance, event: event)
            XCTAssertTrue(layers(host.view.layer).allSatisfy { $0.animationKeys()?.isEmpty ?? true })
            host.configure(performance, event: UUID(), reduceMotion: true)
            XCTAssertTrue(layers(host.view.layer).allSatisfy { $0.animationKeys()?.isEmpty ?? true })
            XCTAssertEqual(try modelPixels(host.view), settled)
            host.configure(performance, event: UUID(), lowPower: true)
            XCTAssertTrue(layers(host.view.layer).allSatisfy { $0.animationKeys()?.isEmpty ?? true })
            XCTAssertEqual(try modelPixels(host.view), settled)
        }
    }

    @MainActor func testMissingRigNeverDrawsSleevesOnTopOfCompleteFallbackCharacter() throws {
        let host = try ResultArmHost(missingRig: true); defer { host.close() }
        for performance in ResultCharacterPerformance.allCases {
            host.configure(performance, event: UUID())
            let character = try XCTUnwrap(host.view.layer.sublayers?.first { $0.name == "result-character" })
            XCTAssertNotNil(character.contents)
            for sleeve in character.sublayers ?? [] where sleeve.name?.hasPrefix("result-arm-") == true {
                XCTAssertEqual(sleeve.opacity, 0)
                XCTAssertTrue(layers(sleeve).allSatisfy { $0.animationKeys()?.isEmpty ?? true })
            }
        }
    }
}
