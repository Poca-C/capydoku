import XCTest
import UIKit
@testable import Capydoku

@MainActor private final class ResultCharacterClock {
    private(set) var jobs: [(TimeInterval, DispatchWorkItem)] = []
    func schedule(_ delay: TimeInterval, _ work: DispatchWorkItem) { jobs.append((delay, work)) }
}

@MainActor private final class ResultCharacterRig {
    let window: UIWindow
    let view: ResultCharacterUIView
    let button = UIButton(type: .system)
    private let previousWindow: UIWindow?

    init(side: CGFloat = 240, clock: ResultCharacterClock? = nil, prepareRig: (() -> Bool)? = nil) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.ink)
        window.rootViewController = controller; window.makeKeyAndVisible()
        let frame = CGRect(x: 40, y: 120, width: side, height: side)
        if let prepareRig { view = ResultCharacterUIView(frame: frame, prepareRig: prepareRig) }
        else { view = ResultCharacterUIView(frame: frame) }
        if let clock { view.schedule = clock.schedule }
        controller.view.addSubview(view)
        button.frame = CGRect(x: 40, y: 120 + side + 16, width: side, height: 46)
        button.setTitle("继续", for: .normal); button.backgroundColor = UIColor(CapyPalette.orange)
        button.setTitleColor(.white, for: .normal); button.layer.cornerRadius = 12
        controller.view.addSubview(button)
        view.layoutIfNeeded()
    }

    func configure(won: Bool = true, variant: ResultCelebrationVariant = .joyfulBounce,
                   id: UUID?, reduceMotion: Bool = false, enabled: Bool = true, lowPower: Bool = false) {
        view.configure(won: won, variant: variant, animationID: id, reduceMotion: reduceMotion,
                       presentationEnabled: enabled, lowPower: lowPower)
        view.layoutIfNeeded()
    }

    func close() {
        view.cancelPresentation(); view.removeFromSuperview(); window.isHidden = true
        window.rootViewController = nil; previousWindow?.makeKeyAndVisible()
    }
}

final class ResultCharacterTests: XCTestCase {
    @MainActor private func layers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(layers)
    }

    @MainActor private func animations(_ view: UIView) -> [CAAnimation] {
        layers(view.layer).flatMap { layer in (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) } }
    }

    @MainActor private func capture(_ view: UIView, name: String) {
        let picture = UIGraphicsImageRenderer(bounds: view.bounds).image {
            (view.layer.presentation() ?? view.layer).render(in: $0.cgContext)
        }
        let attachment = XCTAttachment(image: picture); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func modelPixels(_ view: UIView) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let picture = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image {
            view.layer.render(in: $0.cgContext)
        }
        return try XCTUnwrap(picture.cgImage?.dataProvider?.data) as Data
    }

    @MainActor func testNilEventIsStaticAndRepeatedOrOldEventCannotRestartDecoration() throws {
        let clock = ResultCharacterClock(), rig = try ResultCharacterRig(clock: clock); defer { rig.close() }
        rig.configure(id: nil)
        XCTAssertTrue(animations(rig.view).isEmpty); XCTAssertEqual(rig.view.playedEventCount, 0)
        let first = UUID(); rig.configure(id: first)
        XCTAssertEqual(rig.view.activeEventID, first); XCTAssertEqual(rig.view.playedEventCount, 1)
        XCTAssertFalse(animations(rig.view).isEmpty)
        for _ in 0..<4 { rig.configure(id: first) }
        XCTAssertEqual(rig.view.playedEventCount, 1); XCTAssertEqual(clock.jobs.count, 1)
        clock.jobs[0].1.perform()
        XCTAssertNil(rig.view.activeEventID); XCTAssertTrue(animations(rig.view).isEmpty)
        rig.configure(id: nil); rig.configure(id: first)
        XCTAssertEqual(rig.view.playedEventCount, 1)
        let next = UUID(); rig.configure(variant: .proudCrown, id: next)
        XCTAssertEqual(rig.view.playedEventCount, 2)
        rig.configure(id: first)
        XCTAssertEqual(rig.view.playedEventCount, 2); XCTAssertNil(rig.view.activeEventID)
    }

    @MainActor func testNewEventCancelsOldCleanupAndBothVariantsAreDistinctFiniteSequences() throws {
        let clock = ResultCharacterClock(), rig = try ResultCharacterRig(clock: clock); defer { rig.close() }
        let first = UUID(); rig.configure(id: first)
        let character = try XCTUnwrap(layers(rig.view.layer).first { $0.name == "result-character" })
        let bounce = try XCTUnwrap(character.animation(forKey: "result-transform.translation.y") as? CAKeyframeAnimation)
        let heights = try XCTUnwrap(bounce.values as? [NSNumber]).map(\.doubleValue)
        XCTAssertEqual(heights.filter { $0 < 0 }.count, 2, "The first victory has two separate jumps")
        let oldJob = clock.jobs[0].1
        let next = UUID(); rig.configure(variant: .proudCrown, id: next)
        XCTAssertTrue(oldJob.isCancelled); XCTAssertEqual(rig.view.activeEventID, next)
        oldJob.perform()
        XCTAssertEqual(rig.view.activeEventID, next, "A late completion from another result cannot end the current performance")
        XCTAssertNil(character.animation(forKey: "result-transform.translation.y"))
        XCTAssertNotNil(character.animation(forKey: "result-transform.rotation.z"))
        let crown = try XCTUnwrap(layers(rig.view.layer).first { $0.name == "result-star-crown" })
        XCTAssertEqual(crown.opacity, 1)
        XCTAssertTrue((crown.sublayers ?? []).allSatisfy { $0.animation(forKey: "result-transform.scale") != nil })
        for animation in animations(rig.view) {
            XCTAssertLessThanOrEqual(animation.duration, 1.2)
            XCTAssertEqual(animation.repeatCount, 0); XCTAssertEqual(animation.repeatDuration, 0)
            XCTAssertFalse(animation.autoreverses)
        }
        clock.jobs.last?.1.perform()
        XCTAssertTrue(animations(rig.view).isEmpty); XCTAssertNil(rig.view.activeEventID)
        XCTAssertEqual(crown.opacity, 1, "The second result retains its static star crown after motion ends")
    }

    @MainActor func testReducedMotionLowPowerAndOcclusionConsumeEventsWithoutDelayedReplay() throws {
        let rig = try ResultCharacterRig(); defer { rig.close() }
        let reduced = UUID(); rig.configure(id: reduced, reduceMotion: true)
        rig.configure(id: reduced)
        XCTAssertEqual(rig.view.playedEventCount, 0)
        let power = UUID(); rig.configure(id: power, lowPower: true)
        rig.configure(id: power)
        XCTAssertEqual(rig.view.playedEventCount, 0)
        let hidden = UUID(); rig.configure(id: hidden, enabled: false)
        rig.configure(id: hidden)
        XCTAssertEqual(rig.view.playedEventCount, 0)
        let live = UUID(); rig.configure(id: live)
        XCTAssertEqual(rig.view.playedEventCount, 1)
        rig.configure(id: live, enabled: false)
        XCTAssertTrue(animations(rig.view).isEmpty); XCTAssertNil(rig.view.activeEventID)
        rig.configure(id: live)
        XCTAssertEqual(rig.view.playedEventCount, 1)
    }

    @MainActor func testBackgroundDetachAndLayoutChangesCancelWithoutRestoringOldMotion() throws {
        let rig = try ResultCharacterRig(); defer { rig.close() }
        let event = UUID(); rig.configure(id: event)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(animations(rig.view).isEmpty); XCTAssertNil(rig.view.activeEventID)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        rig.configure(id: event)
        XCTAssertEqual(rig.view.playedEventCount, 1)
        let next = UUID(); rig.configure(id: next)
        rig.view.removeFromSuperview()
        XCTAssertTrue(animations(rig.view).isEmpty)
        rig.window.rootViewController?.view.addSubview(rig.view)
        rig.configure(id: next)
        XCTAssertEqual(rig.view.playedEventCount, 2)
        let resize = UUID(); rig.configure(id: resize)
        rig.view.bounds.size = CGSize(width: 180, height: 180); rig.view.layoutIfNeeded()
        XCTAssertTrue(animations(rig.view).isEmpty); XCTAssertNil(rig.view.activeEventID)
        rig.configure(id: resize)
        XCTAssertEqual(rig.view.playedEventCount, 3)
    }

    @MainActor func testFirstAttachmentCanPlayFreshEventButPendingReplacementIsConsumed() throws {
        let rig = try ResultCharacterRig(); defer { rig.close() }
        let fresh = ResultCharacterUIView(frame: CGRect(x: 0, y: 0, width: 180, height: 180))
        let first = UUID(), second = UUID()
        fresh.configure(won: true, variant: .joyfulBounce, animationID: first, reduceMotion: false, presentationEnabled: true, lowPower: false)
        fresh.configure(won: true, variant: .joyfulBounce, animationID: second, reduceMotion: false, presentationEnabled: true, lowPower: false)
        XCTAssertEqual(fresh.playedEventCount, 0)
        rig.window.rootViewController?.view.addSubview(fresh); fresh.layoutIfNeeded()
        defer { fresh.cancelPresentation(); fresh.removeFromSuperview() }
        XCTAssertEqual(fresh.activeEventID, second); XCTAssertEqual(fresh.playedEventCount, 1)
        fresh.configure(won: true, variant: .joyfulBounce, animationID: first, reduceMotion: false, presentationEnabled: true, lowPower: false)
        XCTAssertEqual(fresh.playedEventCount, 1); XCTAssertNil(fresh.activeEventID)
    }

    @MainActor func testFailureUsesSadArtworkAndFiniteSighWithoutTouchingButtons() throws {
        let clock = ResultCharacterClock(), rig = try ResultCharacterRig(clock: clock); defer { rig.close() }
        rig.configure(won: false, id: UUID())
        let character = try XCTUnwrap(layers(rig.view.layer).first { $0.name == "result-character" })
        XCTAssertNil(character.contents)
        let head = try XCTUnwrap(character.sublayers?.first { $0.name == ResultRigPart.sadHead.layerName })
        let texture = try XCTUnwrap(head.contents) as AnyObject
        let expectedTexture = try XCTUnwrap(ResultCharacterArtwork.rigImage(.sadHead)?.cgImage)
        XCTAssertTrue(texture === expectedTexture)
        XCTAssertEqual(head.opacity, 1)
        XCTAssertNotNil(character.animation(forKey: "result-transform.rotation.z"))
        let sighs = layers(rig.view.layer).filter { $0.name?.hasPrefix("result-sigh-") == true }
        XCTAssertEqual(sighs.count, 3)
        XCTAssertTrue(sighs.allSatisfy { $0.animation(forKey: "result-opacity") != nil && $0.opacity == 0 })
        let crown = try XCTUnwrap(layers(rig.view.layer).first { $0.name == "result-star-crown" })
        XCTAssertEqual(crown.opacity, 0)
        XCTAssertFalse(rig.view.isUserInteractionEnabled); XCTAssertTrue(rig.view.accessibilityElementsHidden)
        let action = rig.button.convert(CGPoint(x: rig.button.bounds.midX, y: rig.button.bounds.midY), to: rig.window)
        XCTAssertTrue(rig.window.hitTest(action, with: nil) === rig.button)
        XCTAssertTrue(animations(rig.view).allSatisfy { $0.duration <= 0.92 && $0.repeatCount == 0 })
        clock.jobs.last?.1.perform()
        XCTAssertTrue(animations(rig.view).isEmpty)
    }

    @MainActor func testSighFollowsActualMouthDuringNodAtThreeSizesIncludingFallback() async throws {
        for fallback in [false, true] {
            for side: CGFloat in [140,168,250] {
                let rig = try ResultCharacterRig(side:side, prepareRig:fallback ? { false } : nil)
                defer { rig.close() }
                rig.configure(won:false,id:nil)
                let finalPixels = try modelPixels(rig.view)
                let event = UUID(); rig.configure(won:false,id:event)
                try await Task.sleep(nanoseconds:380_000_000)
                let root = try XCTUnwrap(rig.view.layer.presentation())
                let ownerName = fallback ? "result-character" : ResultRigPart.sadHead.layerName
                let owner = try XCTUnwrap(layers(root).first { $0.name == ownerName })
                let origin = try XCTUnwrap(owner.sublayers?.first { $0.name == "result-mouth-origin" })
                let mouth = fallback ? CGPoint(x:0.805,y:0.446) : CGPoint(x:0.835,y:0.815)
                XCTAssertEqual(origin.position.x / owner.bounds.width,mouth.x,accuracy:0.0001)
                XCTAssertEqual(origin.position.y / owner.bounds.height,mouth.y,accuracy:0.0001)
                let firstSigh = try XCTUnwrap(origin.sublayers?.first { $0.name == "result-sigh-0" })
                XCTAssertGreaterThan(firstSigh.opacity,0.1)
                let mouthPoint = origin.convert(CGPoint.zero,to:root)
                let bubblePoint = firstSigh.convert(CGPoint(x:firstSigh.bounds.midX,y:firstSigh.bounds.midY),to:root)
                // Mouth and nostril coordinates are independently marked on the
                // supplied head/fallback image. The old root-level effect sat
                // near the nostril instead of following the animated mouth.
                let nostril = fallback ? CGPoint(x:0.85,y:0.285) : CGPoint(x:0.9,y:0.49)
                let nosePoint = owner.convert(CGPoint(x:owner.bounds.width * nostril.x,
                                                      y:owner.bounds.height * nostril.y),to:root)
                XCTAssertLessThan(hypot(bubblePoint.x-mouthPoint.x,bubblePoint.y-mouthPoint.y),
                                  hypot(bubblePoint.x-nosePoint.x,bubblePoint.y-nosePoint.y))
                XCTAssertLessThan(hypot(bubblePoint.x-mouthPoint.x,bubblePoint.y-mouthPoint.y),side * 0.08)
                for shown in origin.sublayers ?? [] where shown.opacity > 0 {
                    XCTAssertTrue(rig.view.bounds.insetBy(dx:-0.5,dy:-0.5).contains(shown.convert(shown.bounds,to:root)))
                }
                capture(rig.view,name:"result-mouth-0230-\(fallback ? "fallback" : "rig")-\(Int(side))pt-380ms")
                NotificationCenter.default.post(name:UIApplication.willResignActiveNotification,object:nil)
                XCTAssertTrue(animations(rig.view).isEmpty)
                XCTAssertEqual(try modelPixels(rig.view),finalPixels)
                NotificationCenter.default.post(name:UIApplication.didBecomeActiveNotification,object:nil)
                rig.configure(won:false,id:event)
                XCTAssertEqual(rig.view.playedEventCount,1)
                XCTAssertTrue(animations(rig.view).isEmpty)
            }
        }
    }

    @MainActor func testActualHostShowsThreeDistinctPerformancesWithinBoundsAndSettlesExactly() async throws {
        let rig = try ResultCharacterRig(); defer { rig.close() }
        for (won, variant, name) in [(true, ResultCelebrationVariant.joyfulBounce, "win-double-bounce"),
                                    (true, .proudCrown, "win-proud-star-crown"),
                                    (false, .joyfulBounce, "loss-bow-and-sigh")] {
            rig.configure(won: won, variant: variant, id: nil)
            let finalPixels = try modelPixels(rig.view)
            rig.configure(won: won, variant: variant, id: UUID())
            try await Task.sleep(nanoseconds: 310_000_000)
            capture(rig.view, name: "result-character-\(name)-310ms")
            for target in rig.view.layer.sublayers ?? [] {
                let shown = target.presentation() ?? target
                guard shown.opacity > 0, target.name != "result-star-crown" else { continue }
                XCTAssertTrue(rig.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(shown.frame),
                    "\(target.name ?? "layer") must remain inside the allocated decoration area, clear of action buttons")
            }
            try await Task.sleep(nanoseconds: 1_020_000_000)
            XCTAssertNil(rig.view.activeEventID); XCTAssertTrue(animations(rig.view).isEmpty)
            XCTAssertEqual(try modelPixels(rig.view), finalPixels)
        }
        capture(rig.window, name: "result-character-settled-host-with-action")
    }
}
