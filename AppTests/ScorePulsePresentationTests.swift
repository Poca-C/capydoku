import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class ScorePulseHost {
    let label = ScorePulseLabel(frame: CGRect(x: 120, y: 180, width: 120, height: 44))
    let window: UIWindow
    let previousWindow: UIWindow?
    var sessionID = UUID()
    var score = 80
    var pulseID: UUID?
    var enabled = true, reduced = false, lowPower = false

    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.addSubview(label)
        refresh()
    }
    func refresh() {
        label.configure(score: score, sessionID: sessionID, pulseID: pulseID, fontSize: 25,
                        reduceMotion: reduced, presentationEnabled: enabled, lowPower: lowPower)
    }
    func award() { score += 20; pulseID = UUID(); refresh() }
    func close() {
        label.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
        previousWindow?.makeKeyAndVisible()
    }
}

final class ScorePulsePresentationTests: XCTestCase {
    @MainActor private func scale(_ label: ScorePulseLabel) throws -> CGFloat {
        CGFloat(try XCTUnwrap(label.layer.presentation(), "Sample the running render layer, not the static model transform.").transform.m11)
    }

    @MainActor func testRapidEqualAwardsBothMoveAndSettleWhileNumbersUpdateImmediately() async throws {
        let host = try ScorePulseHost(); defer { host.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(host.label.text, "80")
        XCTAssertNil(host.label.layer.animation(forKey: ScorePulseLabel.animationKey), "A restored score is static.")
        for expected in [100, 120] {
            host.award()
            XCTAssertEqual(host.label.text, String(expected), "The score must not wait for a flight, pulse, or timer.")
            try await Task.sleep(nanoseconds: 40_000_000)
            let early = try scale(host.label)
            try await Task.sleep(nanoseconds: 70_000_000)
            let peak = try scale(host.label)
            XCTAssertGreaterThan(peak, early + 0.035, "Both awards must produce actual motion, including a second award at the first pulse's peak.")
            XCTAssertGreaterThan(peak, 1.06)
            XCTAssertTrue(CATransform3DIsIdentity(host.label.layer.transform), "Presentation cannot leave the model enlarged.")
            let beforeRefresh = try XCTUnwrap(host.label.layer.animation(forKey: ScorePulseLabel.animationKey)).beginTime
            for _ in 0..<5 { host.refresh(); host.label.layoutIfNeeded() }
            XCTAssertEqual(host.label.layer.animation(forKey: ScorePulseLabel.animationKey)?.beginTime, beforeRefresh,
                           "Routine HUD refreshes must not restart or prolong a pulse.")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(host.label.layer.animation(forKey: ScorePulseLabel.animationKey))
        XCTAssertEqual(try scale(host.label), 1, accuracy: 0.001)
        XCTAssertEqual(host.label.text, "120")
    }

    @MainActor func testModalBackgroundStaticPoliciesAndReplacementConsumeWithoutReplay() throws {
        for boundary in ["modal", "background", "reduced", "power", "detach", "session"] {
            let host = try ScorePulseHost(); defer { host.close() }
            host.award()
            XCTAssertNotNil(host.label.layer.animation(forKey: ScorePulseLabel.animationKey))
            switch boundary {
            case "modal": host.enabled = false; host.refresh()
            case "background": NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            case "reduced": host.reduced = true; host.refresh()
            case "power": host.lowPower = true; host.refresh()
            case "detach": host.label.removeFromSuperview()
            default: host.sessionID = UUID(); host.refresh()
            }
            XCTAssertNil(host.label.layer.animation(forKey: ScorePulseLabel.animationKey), boundary)
            XCTAssertTrue(CATransform3DIsIdentity(host.label.layer.transform), boundary)
            // A score accepted under the gate updates its text and is consumed.
            if boundary != "session" { host.award() }
            XCTAssertEqual(host.label.text, String(host.score))
            XCTAssertNil(host.label.layer.animation(forKey: ScorePulseLabel.animationKey), boundary)
            host.enabled = true; host.reduced = false; host.lowPower = false
            if boundary == "background" { NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
            if boundary == "detach" { host.window.rootViewController?.view.addSubview(host.label) }
            host.refresh()
            XCTAssertNil(host.label.layer.animation(forKey: ScorePulseLabel.animationKey), "Uncovering must not replay: \(boundary)")
            host.award()
            XCTAssertNotNil(host.label.layer.animation(forKey: ScorePulseLabel.animationKey), "A genuinely new visible award resumes feedback: \(boundary)")
        }
    }

    /// Runtime screenshot/recording entry: real RootView and accepted Core moves,
    /// no layer time seeking or synthetic score mutation.
    @MainActor func testActualRootRapidAcceptedAwardsCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("score-pulse-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true; model.start(level: 6)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIHostingController(rootView: RootView().environmentObject(model)
            .environment(\.scenePhase, .active).environment(\.capyMotionOverride, false))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: directory)
        }
        func scoreLabel(in view: UIView) -> ScorePulseLabel? {
            (view as? ScorePulseLabel) ?? view.subviews.lazy.compactMap { scoreLabel(in: $0) }.first
        }
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: false)
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let label = try XCTUnwrap(scoreLabel(in: controller.view))
        let solution = try XCTUnwrap(model.session).puzzle.solution
        for (offset, index) in solution.prefix(2).enumerated() {
            model.submit(index)
            let committedScore = try XCTUnwrap(model.session).score
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(label.text, String(committedScore))
            let early = try scale(label)
            try await Task.sleep(nanoseconds: 70_000_000)
            let peak = try scale(label)
            XCTAssertGreaterThan(peak, early + 0.025, "The actual RootView must retrigger on the second accepted award.")
            capture("score-award-\(offset + 1)-peak")
        }
        XCTAssertEqual(model.session?.found.count, 2)
        try await Task.sleep(nanoseconds: 380_000_000)
        XCTAssertNil(label.layer.animation(forKey: ScorePulseLabel.animationKey))
        XCTAssertEqual(try scale(label), 1, accuracy: 0.001)
        capture("score-rapid-awards-settled")
        model.sheet = .settings
        try await Task.sleep(nanoseconds: 80_000_000)
        model.sheet = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(label.layer.animation(forKey: ScorePulseLabel.animationKey), "Closing settings must not replay the last score.")
    }
}
