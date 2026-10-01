import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class ChoreographyClock {
    var now = 0.0
    var jobs: [(Double, () -> Void)] = []
    func schedule(_ delay: Double, _ action: @escaping () -> Void) { jobs.append((now + delay, action)) }
    func advance(_ seconds: Double) {
        let until = now + seconds
        while let next = jobs.indices.filter({ jobs[$0].0 <= until }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
            let job = jobs.remove(at: next); now = job.0; job.1()
        }
        now = until
    }
}

final class ResultChoreographyTests: XCTestCase {
    @MainActor func testWinAndLossRevealCharacterThenTitleThenDetailWithoutChangingImmediateActionContract() {
        for outcome in [GameStatus.won, .lost] {
            let clock = ChoreographyClock(), id = UUID(), result = ResultEntrancePresentation(schedule: clock.schedule)
            result.update(sessionID: id, status: .playing, animate: true)
            result.update(sessionID: id, status: outcome, animate: true)
            XCTAssertEqual(result.stage, .board); XCTAssertFalse(result.ready)
            clock.advance(outcome == .won ? 0.82 : 0.60)
            XCTAssertTrue(result.ready); XCTAssertEqual(result.stage, .character)
            let event = result.animationID; XCTAssertNotNil(event)
            clock.advance(0.161); XCTAssertEqual(result.stage, .title)
            clock.advance(0.16); XCTAssertEqual(result.stage, .detail)
            clock.advance(0.19); XCTAssertEqual(result.stage, .settled)
            XCTAssertEqual(result.animationID, event)
        }
    }

    @MainActor func testCoverAndNextLevelCancelEveryRemainingStageAndRestorationIsFullyReadable() {
        for leave in [false, true] {
            let clock = ChoreographyClock(), id = UUID(), result = ResultEntrancePresentation(schedule: clock.schedule)
            result.update(sessionID: id, status: .playing, animate: true)
            result.update(sessionID: id, status: .won, animate: true); clock.advance(0.83)
            result.update(sessionID: leave ? UUID() : id, status: leave ? .playing : .won, animate: false)
            XCTAssertNil(result.animationID); XCTAssertEqual(result.stage, .settled)
            clock.advance(3)
            XCTAssertNil(result.animationID); XCTAssertEqual(result.stage, .settled)
        }
        let restored = ResultEntrancePresentation()
        restored.update(sessionID: UUID(), status: .won, animate: true)
        XCTAssertTrue(restored.ready); XCTAssertEqual(restored.stage, .settled); XCTAssertNil(restored.animationID)
    }

    @MainActor func testLastLifeWaitsForAcknowledgementAndNeverReplaysHiddenChanges() {
        let clock = ChoreographyClock(), feedback = GameFeedbackPresentation(schedule: clock.schedule)
        feedback.life(1); clock.advance(20)
        XCTAssertTrue(feedback.showLastLife, "The player must have time to read and acknowledge it.")
        feedback.dismissLastLife(); clock.advance(20); XCTAssertFalse(feedback.showLastLife)
        feedback.life(3); feedback.life(1); XCTAssertTrue(feedback.showLastLife)
        feedback.setPresentationEnabled(false); feedback.life(1); feedback.setPresentationEnabled(true)
        XCTAssertFalse(feedback.showLastLife)
        feedback.life(1); feedback.life(0); XCTAssertFalse(feedback.showLastLife)
    }

    func testSpotlightGeometryTracksMeasuredHeartsAndRejectsInvalidOrOffscreenFrames() {
        let size = CGSize(width: 320, height: 568), measured = CGRect(x: 205, y: 120, width: 74, height: 32)
        let hole = LastLifeSpotlightView.focusFrame(measured, in: size)
        XCTAssertTrue(hole.contains(measured)); XCTAssertEqual(hole.midX, measured.midX)
        for rect in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), CGRect(x: -500, y: 600, width: 1000, height: 100)] {
            let valid = LastLifeSpotlightView.focusFrame(rect, in: size)
            XCTAssertTrue(valid.minX.isFinite); XCTAssertTrue(valid.minY.isFinite)
            XCTAssertGreaterThanOrEqual(valid.minX, 0); XCTAssertLessThanOrEqual(valid.maxX, size.width)
            XCTAssertLessThanOrEqual(valid.maxY, size.height * 0.36)
        }
    }

    @MainActor func testAtmosphereIsFiniteBoundedAndCoverCannotReplayItsParticles() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 360)
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(white: 0.14, alpha: 1)
        window.rootViewController = controller; window.makeKeyAndVisible()
        let effect = ResultAtmosphereUIView(frame: controller.view.bounds)
        effect.autoresizingMask = [.flexibleWidth, .flexibleHeight]; controller.view.addSubview(effect)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        controller.view.layoutIfNeeded()
        let id = UUID(); effect.configure(won: true, eventID: id, enabled: true, reduceMotion: false)
        XCTAssertEqual(effect.activeEventID, id); XCTAssertEqual(effect.playedEvents, 1); XCTAssertEqual(effect.particleCount, 28)
        XCTAssertFalse(effect.isUserInteractionEnabled)
        try await Task.sleep(nanoseconds: 350_000_000)
        capture(controller.view, "result-atmosphere-rays-confetti-350ms")
        effect.configure(won: true, eventID: id, enabled: false, reduceMotion: false)
        XCTAssertNil(effect.activeEventID)
        effect.configure(won: true, eventID: id, enabled: true, reduceMotion: false)
        XCTAssertEqual(effect.playedEvents, 1)
        effect.configure(won: true, eventID: UUID(), enabled: true, reduceMotion: true)
        XCTAssertNil(effect.activeEventID); XCTAssertEqual(effect.playedEvents, 1)
        effect.configure(won: false, eventID: UUID(), enabled: true, reduceMotion: false)
        XCTAssertNil(effect.activeEventID)
        effect.configure(won: true, eventID: UUID(), enabled: true, reduceMotion: false)
        try await Task.sleep(nanoseconds: 1_650_000_000)
        XCTAssertNil(effect.activeEventID); XCTAssertEqual(effect.playedEvents, 2)
        func animationCount(_ layer: CALayer) -> Int { (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + animationCount($1) } }
        XCTAssertEqual(animationCount(effect.layer), 0)
    }

    @MainActor func testCurrentLevelSixRootShowsSequentialResultAndAccessibleImmediateAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("result-choreography-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true; model.start(level: 6)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        var frames: [String: CGRect] = [:]
        let host = UIHostingController(rootView: RootView(reduceMotionOverride: false).environmentObject(model)
            .environment(\.scenePhase, .active).environment(\.capyLayoutObserver, { frames[$0] = $1 }))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory) }
        try await Task.sleep(nanoseconds: 650_000_000)
        for cell in try XCTUnwrap(model.session).puzzle.solution { model.submit(cell) }
        let won = model.session; XCTAssertEqual(won?.status, .won)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(frames["result_primary_action"])
        capture(host.view, "current-L6-final-board-200ms")
        try await Task.sleep(nanoseconds: 680_000_000)
        capture(host.view, "current-L6-character-first-880ms")
        try await Task.sleep(nanoseconds: 190_000_000)
        capture(host.view, "current-L6-title-second-1070ms")
        try await Task.sleep(nanoseconds: 430_000_000)
        capture(host.view, "current-L6-complete-celebration-1500ms")
        XCTAssertEqual(model.session, won)
        model.next(); XCTAssertEqual(model.session?.puzzle.id, 7)
    }

    @MainActor func testActualSmallRootOneLifeFocusFitsChineseAndPreservesCommittedState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("last-life-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true; model.start(level: 6)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        var frames: [String: CGRect] = [:]
        let host = UIHostingController(rootView: RootView(reduceMotionOverride: true).environmentObject(model)
            .environment(\.scenePhase, .active).environment(\.dynamicTypeSize, .accessibility1)
            .environment(\.capyLayoutObserver, { frames[$0] = $1 }))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let session = try XCTUnwrap(model.session), wrong = (0..<(session.puzzle.size * session.puzzle.size)).filter { !session.puzzle.solution.contains($0) }
        model.submit(wrong[0]); try await Task.sleep(nanoseconds: 100_000_000); model.submit(wrong[1])
        let committed = model.session; XCTAssertEqual(committed?.lives, 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(frames["last_life_continue"])
        capture(host.view, "current-L6-last-life-small-Chinese-large-type")
        XCTAssertEqual(model.session, committed)
        model.home(); try await Task.sleep(nanoseconds: 100_000_000); model.startOrContinue()
        try await Task.sleep(nanoseconds: 200_000_000)
        // A real Home/Continue transition opens the next analytics result phase.
        // Keep an exact session comparison, including every gameplay field.
        var expected = try XCTUnwrap(committed)
        XCTAssertNotNil(expected.claimResult(.quit))
        XCTAssertTrue(expected.resumeAfterQuit())
        XCTAssertEqual(model.session, expected)
    }

    @MainActor private func capture(_ view: UIView, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: false) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
