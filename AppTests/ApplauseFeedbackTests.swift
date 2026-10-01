import XCTest
import SwiftUI
import UIKit
@testable import Capydoku

@MainActor private final class ApplauseWindowRig {
    let applause: ApplauseFeedbackUIView
    let button = UIButton(type: .system)
    let window: UIWindow
    private let previous: UIWindow?

    init(size: CGSize = CGSize(width: 34, height: 30), initialEvent: UUID? = nil) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = controller; window.makeKeyAndVisible()
        applause = ApplauseFeedbackUIView(frame: CGRect(origin: CGPoint(x: 80, y: 180), size: size))
        applause.configure(eventID: initialEvent, enabled: true, reduceMotion: false, lowPower: false)
        button.frame = applause.frame; controller.view.addSubview(button)
        controller.view.addSubview(applause); applause.layoutIfNeeded()
    }
    func show(_ id: UUID?, enabled: Bool = true, reduced: Bool = false, lowPower: Bool = false) {
        applause.configure(eventID: id, enabled: enabled, reduceMotion: reduced, lowPower: lowPower)
    }
    func close() {
        applause.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
        previous?.makeKeyAndVisible()
    }
}

@MainActor private final class ApplauseVisualState: ObservableObject {
    @Published var eventID: UUID?
    @Published var enabled = true
}

@MainActor private struct ApplauseVisualHost: View {
    @ObservedObject var state: ApplauseVisualState
    var body: some View {
        HStack(spacing: 32) {
            VStack(spacing: 10) {
                Text("34 × 30").font(.caption)
                ApplauseFeedbackView(eventID: state.eventID, enabled: state.enabled, reduceMotion: false, lowPower: false)
                    .frame(width: 34, height: 30)
            }
            VStack(spacing: 10) {
                Text("28 × 24").font(.caption)
                ApplauseFeedbackView(eventID: state.eventID, enabled: state.enabled, reduceMotion: false, lowPower: false)
                    .frame(width: 28, height: 24)
            }
        }.foregroundColor(CapyPalette.ink).frame(width: 230, height: 120).background(CapyPalette.cream)
    }
}

final class ApplauseFeedbackTests: XCTestCase {
    @MainActor private func layers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(layers) }
    @MainActor private func animations(_ layer: CALayer) -> [CAAnimation] {
        layers(layer).flatMap { node in (node.animationKeys() ?? []).compactMap { node.animation(forKey: $0) } }
    }
    @MainActor private func artwork(_ view: ApplauseFeedbackUIView) throws -> CALayer {
        try XCTUnwrap(view.layer.sublayers?.first { $0.name == "applause-artwork" })
    }
    @MainActor private func visiblePixels(_ view: UIView) throws -> Int {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image {
            (view.layer.presentation() ?? view.layer).render(in: $0.cgContext)
        }
        let bitmap = try XCTUnwrap(image.cgImage), width = bitmap.width, height = bitmap.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 16 }.count
    }

    @MainActor func testInitialMountConsumesEventsAndDecorationNeverOwnsInputOrAccessibility() throws {
        let first = UUID(), rig = try ApplauseWindowRig(initialEvent: first); defer { rig.close() }
        XCTAssertEqual(rig.applause.activeEventID, first, "The first SwiftUI configuration may precede mounting.")
        let art = try artwork(rig.applause)
        XCTAssertEqual(art.opacity, 0, "Static model pixels remain transparent even during playback.")
        XCTAssertFalse(rig.applause.isUserInteractionEnabled); XCTAssertFalse(rig.applause.isAccessibilityElement)
        XCTAssertTrue(rig.applause.accessibilityElementsHidden)
        let point = CGPoint(x: rig.button.frame.midX, y: rig.button.frame.midY)
        XCTAssertTrue(rig.window.rootViewController?.view.hitTest(point, with: nil) === rig.button)
        let started = try XCTUnwrap(art.animation(forKey: "applause-opacity")).beginTime
        for _ in 0..<5 { rig.show(first); rig.applause.layoutIfNeeded() }
        XCTAssertEqual(art.animation(forKey: "applause-opacity")?.beginTime, started)
        rig.show(nil); rig.show(first)
        XCTAssertNil(rig.applause.activeEventID); XCTAssertTrue(animations(art).isEmpty)
        let second = UUID(); rig.show(second); XCTAssertEqual(rig.applause.activeEventID, second)
        rig.show(nil); rig.show(first); rig.show(second)
        XCTAssertNil(rig.applause.activeEventID, "Neither an older ID nor the most recent consumed ID can replay.")
    }

    @MainActor func testRapidNewEventOutlivesTheOldCleanupAndThenBecomesTransparent() async throws {
        let rig = try ApplauseWindowRig(); defer { rig.close() }
        let first = UUID(), second = UUID()
        rig.show(first)
        try await Task.sleep(nanoseconds: 270_000_000)
        XCTAssertGreaterThan(try visiblePixels(rig.applause), 0)
        rig.show(second)
        try await Task.sleep(nanoseconds: 320_000_000)
        XCTAssertEqual(rig.applause.activeEventID, second, "The first event's 0.56s cleanup cannot erase its successor.")
        XCTAssertGreaterThan(try visiblePixels(rig.applause), 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(rig.applause.activeEventID); XCTAssertTrue(animations(rig.applause.layer).isEmpty)
        XCTAssertEqual(try visiblePixels(rig.applause), 0)
    }

    @MainActor func testCoverBackgroundDetachAndNilCancelWithoutReplayingOnResume() throws {
        for gate in ["disabled", "background", "detach", "hidden", "nil"] {
            let rig = try ApplauseWindowRig(); defer { rig.close() }
            let event = UUID(); rig.show(event)
            XCTAssertEqual(rig.applause.activeEventID, event)
            switch gate {
            case "disabled": rig.show(event, enabled: false)
            case "background": NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            case "detach": rig.applause.removeFromSuperview()
            case "hidden": rig.applause.isHidden = true
            default: rig.show(nil)
            }
            XCTAssertNil(rig.applause.activeEventID); XCTAssertTrue(animations(rig.applause.layer).isEmpty)
            let coveredEvent = UUID()
            if gate != "nil" {
                rig.show(coveredEvent, enabled: gate != "disabled")
                XCTAssertNil(rig.applause.activeEventID, "A covered cue must be consumed immediately: \(gate)")
            }
            if gate == "background" { NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
            if gate == "detach" { rig.window.rootViewController?.view.addSubview(rig.applause) }
            rig.applause.isHidden = false
            rig.show(gate == "nil" ? event : coveredEvent)
            XCTAssertNil(rig.applause.activeEventID, "Returning cannot replay: \(gate)")
            let fresh = UUID(); rig.show(fresh); XCTAssertEqual(rig.applause.activeEventID, fresh)
        }
    }

    @MainActor func testStaticPoliciesShowOnlyAnOutlineAndChangesCancelInFlightMotion() async throws {
        for reduced in [true, false] {
            let rig = try ApplauseWindowRig(); defer { rig.close() }
            let event = UUID(); rig.show(event, reduced: reduced, lowPower: !reduced)
            let art = try artwork(rig.applause)
            XCTAssertEqual(art.opacity, 0)
            let running = animations(art)
            XCTAssertEqual(running.count, 1)
            let opacity = try XCTUnwrap(running.first as? CAKeyframeAnimation)
            XCTAssertEqual(opacity.keyPath, "opacity"); XCTAssertLessThanOrEqual(opacity.duration, 0.25)
            let values = try XCTUnwrap(opacity.values as? [NSNumber])
            XCTAssertEqual(values.map(\.doubleValue), [0.9, 0.9])
            for body in layers(art).compactMap({ $0 as? CAShapeLayer }).filter({ $0.name == "paw-body" }) {
                XCTAssertEqual(body.fillColor?.alpha, 0)
            }
            try await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertGreaterThan(try visiblePixels(rig.applause), 0)
            try await Task.sleep(nanoseconds: 210_000_000)
            XCTAssertNil(rig.applause.activeEventID); XCTAssertEqual(try visiblePixels(rig.applause), 0)
            let normal = UUID(); rig.show(normal)
            XCTAssertEqual(rig.applause.activeEventID, normal)
            rig.show(normal, reduced: reduced, lowPower: !reduced)
            XCTAssertNil(rig.applause.activeEventID); XCTAssertTrue(animations(art).isEmpty)
            rig.show(normal); XCTAssertNil(rig.applause.activeEventID)
        }
    }

    @MainActor func testPawsRemainInsideNormalAndCompactFramesForTheWholeFiniteMotion() throws {
        for size in [CGSize(width: 34, height: 30), CGSize(width: 28, height: 24), CGSize(width: 17, height: 15)] {
            let rig = try ApplauseWindowRig(size: size); defer { rig.close() }
            rig.show(UUID())
            let art = try artwork(rig.applause)
            XCTAssertLessThanOrEqual(layers(art).count, 8, "Two paws and one bounded contact accent; no growing particle list.")
            let allAnimations = animations(art)
            let commonTime = try XCTUnwrap(allAnimations.first).beginTime
            for animation in allAnimations {
                XCTAssertLessThanOrEqual(animation.duration, 0.60); XCTAssertEqual(animation.repeatCount, 0)
                XCTAssertFalse(animation.autoreverses); XCTAssertEqual(animation.beginTime, commonTime, accuracy: 0.0001)
            }
            let scale = art.affineTransform().a
            let accent = try XCTUnwrap(art.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
            let accentBounds = try XCTUnwrap(accent.path).boundingBoxOfPath.insetBy(dx: -accent.lineWidth / 2, dy: -accent.lineWidth / 2)
            XCTAssertTrue(art.bounds.contains(accentBounds), "Contact strokes stay in the reserved decoration band.")
            for paw in (art.sublayers ?? []).filter({ $0.name == "applause-left" || $0.name == "applause-right" }) {
                let translation = try XCTUnwrap(paw.animation(forKey: "applause-transform.translation.x") as? CAKeyframeAnimation)
                let rotation = try XCTUnwrap(paw.animation(forKey: "applause-transform.rotation.z") as? CAKeyframeAnimation)
                let positions = try XCTUnwrap(translation.values as? [NSNumber])
                let angles = try XCTUnwrap(rotation.values as? [NSNumber])
                for shape in paw.sublayers?.compactMap({ $0 as? CAShapeLayer }) ?? [] {
                    let path = try XCTUnwrap(shape.path)
                    let box = path.boundingBoxOfPath.insetBy(dx: -shape.lineWidth / 2, dy: -shape.lineWidth / 2)
                    let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                                   CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
                    // Cross all extrema rather than assuming the two animation
                    // channels remain in phase when checking the safety margin.
                    for x in positions {
                        for angle in angles {
                            let theta = CGFloat(angle.doubleValue), shift = CGFloat(x.doubleValue)
                            for corner in corners {
                                let dx = corner.x - paw.bounds.midX, dy = corner.y - paw.bounds.midY
                                let px = paw.position.x + cos(theta) * dx - sin(theta) * dy + shift
                                let py = paw.position.y + sin(theta) * dx + cos(theta) * dy
                                let point = CGPoint(x: art.position.x + (px - art.bounds.midX) * scale,
                                                    y: art.position.y + (py - art.bounds.midY) * scale)
                                XCTAssertTrue(rig.applause.bounds.contains(point), "The complete stroked paw must stay inside \(size).")
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor func testRealSwiftUIHostsNaturallyShowTwoContactsAndClearAfterCancellation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let state = ApplauseVisualState()
        let host = UIHostingController(rootView: ApplauseVisualHost(state: state))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func find(_ view: UIView) -> [ApplauseFeedbackUIView] {
            if let applause = view as? ApplauseFeedbackUIView { return [applause] }
            return view.subviews.flatMap(find)
        }
        var captures = [(String, UIImage)]()
        func capture(_ stage: String) {
            // Render only the actual compact host region to avoid the cost of
            // full-screen images between two naturally spaced samples.
            let bounds = host.view.bounds
            let crop = CGRect(x: bounds.midX - 115, y: bounds.midY - 60, width: 230, height: 120)
            let image = UIGraphicsImageRenderer(size: crop.size).image { context in
                context.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
                (host.view.layer.presentation() ?? host.view.layer).render(in: context.cgContext)
            }
            // Attachment encoding waits until after the sampled motion.
            captures.append((stage, image))
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let views = find(host.view); XCTAssertEqual(views.count, 2)
        guard views.count == 2 else { return }
        let event = UUID(); state.eventID = event
        let mountingDeadline = CACurrentMediaTime() + 0.8
        while !views.allSatisfy({ $0.activeEventID == event }), CACurrentMediaTime() < mountingDeadline {
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        XCTAssertTrue(views.allSatisfy { $0.activeEventID == event })
        let paws = try views.map { view in try XCTUnwrap(artwork(view).sublayers?.first { $0.name == "applause-left" }) }
        var stages = Array(repeating: 0, count: views.count)
        let samplingDeadline = CACurrentMediaTime() + 0.7
        // Detect the sequence from short, live presentation samples instead of
        // assuming a relative sleep lands at an exact animation frame. The two
        // inward contacts must be separated by an actual outward release.
        while stages.contains(where: { $0 < 3 }), CACurrentMediaTime() < samplingDeadline {
            for index in paws.indices {
                guard let rendered = paws[index].presentation() else { continue }
                let inward = rendered.transform.m41
                let before = stages[index]
                if before == 0 && inward > 1.8 { stages[index] = 1 }
                else if before == 1 && inward < 0.8 { stages[index] = 2 }
                else if before == 2 && inward > 1.8 { stages[index] = 3 }
                if index == 0, stages[index] != before {
                    capture(["first-contact-phase", "release-phase", "second-contact-phase"][stages[index] - 1])
                }
            }
            if stages.allSatisfy({ $0 == 3 }) { break }
            try await Task.sleep(nanoseconds: 12_000_000)
        }
        for index in views.indices {
            XCTAssertEqual(stages[index], 3, "Both real size variants must visibly close, release, and close again.")
            XCTAssertGreaterThan(try visiblePixels(views[index]), 0)
        }
        // New live event, then cancel while visible. No layer seeking or forced
        // timeOffset is used; these are naturally rendered UIKit/SwiftUI frames.
        state.eventID = UUID()
        try await Task.sleep(nanoseconds: 90_000_000)
        for view in views { XCTAssertGreaterThan(try visiblePixels(view), 0) }
        state.enabled = false
        try await Task.sleep(nanoseconds: 60_000_000)
        capture("cancelled")
        for view in views {
            XCTAssertNil(view.activeEventID); XCTAssertTrue(animations(view.layer).isEmpty)
            XCTAssertEqual(try visiblePixels(view), 0)
        }
        state.enabled = true
        try await Task.sleep(nanoseconds: 80_000_000)
        for view in views { XCTAssertNil(view.activeEventID); XCTAssertEqual(try visiblePixels(view), 0) }
        for (stage, image) in captures {
            let attachment = XCTAttachment(image: image); attachment.name = "applause-native-normal-and-compact-\(stage)"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
