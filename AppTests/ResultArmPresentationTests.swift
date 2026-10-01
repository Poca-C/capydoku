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
