import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class RewardMotionClock {
    var now = 0.0
    var jobs: [(Double, () -> Void)] = []
    func schedule(_ delay: Double, _ action: @escaping () -> Void) { jobs.append((now + delay, action)) }
    func advance(_ interval: Double) {
        let end = now + interval
        while let next = jobs.indices.filter({ jobs[$0].0 <= end }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
            let job = jobs.remove(at: next); now = job.0; job.1()
        }
        now = end
    }
}

final class GameRewardPresentationTests: XCTestCase {
    @MainActor func testFoundAcknowledgementIsBoundedAndNeverReplayedByDuplicateOrOldSession() {
        let clock = RewardMotionClock(), id = UUID(), next = UUID()
        let feedback = GameRewardPresentation(schedule: clock.schedule)
        feedback.bind(sessionID: id, score: 0)
        for cell in 0..<8 {
            feedback.found(index: cell, sessionID: id, origin: .zero, destination: CGPoint(x: 100, y: 30), reduceMotion: false)
        }
        XCTAssertEqual(feedback.flights.count, 4)
        feedback.found(index: 7, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertEqual(feedback.flights.count, 4)
        clock.advance(0.44)
        XCTAssertTrue(feedback.progressPulse)
        feedback.bind(sessionID: next, score: 100)
        feedback.found(index: 0, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        clock.advance(1)
        XCTAssertTrue(feedback.flights.isEmpty)
        XCTAssertFalse(feedback.progressPulse)
    }

    @MainActor func testHiddenFeedbackClearsFlightsAndStaleScoreExpiryCannotEraseNewReward() {
        let clock = RewardMotionClock(), id = UUID()
        let feedback = GameRewardPresentation(schedule: clock.schedule)
        feedback.bind(sessionID: id, score: 80)
        XCTAssertNil(feedback.scoreDelta, "Restoring a saved score must not replay a reward.")
        XCTAssertNil(feedback.scorePulseID)
        feedback.scoreChanged(100, sessionID: id, visible: true)
        XCTAssertEqual(feedback.scoreDelta, 20)
        let firstPulse = feedback.scorePulseID
        XCTAssertNotNil(firstPulse)
        clock.advance(0.5)
        feedback.scoreChanged(120, sessionID: id, visible: true)
        XCTAssertNotEqual(feedback.scorePulseID, firstPulse, "Equal consecutive awards still need separate visual pulses.")
        let secondPulse = feedback.scorePulseID
        feedback.scoreChanged(120, sessionID: id, visible: true)
        XCTAssertEqual(feedback.scorePulseID, secondPulse, "An unchanged HUD refresh is not another award.")
        clock.advance(0.3)
        XCTAssertEqual(feedback.scoreDelta, 20)
        XCTAssertEqual(feedback.scorePulseID, secondPulse, "Expiry of the preceding pulse must not cancel the newer one.")
        feedback.found(index: 1, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        feedback.clear()
        feedback.scoreChanged(180, sessionID: id, visible: false)
        clock.advance(1)
        XCTAssertTrue(feedback.flights.isEmpty)
        XCTAssertFalse(feedback.progressPulse)
        XCTAssertNil(feedback.scoreDelta)
        XCTAssertNil(feedback.scorePulseID)
        feedback.scoreChanged(200, sessionID: id, visible: true)
        XCTAssertEqual(feedback.scoreDelta, 20, "Hidden changes are the new baseline, not a deferred animation.")
    }

    @MainActor func testReducedMotionRetainsProgressAcknowledgementWithoutFlight() {
        let clock = RewardMotionClock(), id = UUID()
        let feedback = GameRewardPresentation(schedule: clock.schedule)
        feedback.bind(sessionID: id, score: 0)
        feedback.found(index: 1, sessionID: id, origin: .zero, destination: .zero, reduceMotion: true)
        XCTAssertTrue(feedback.flights.isEmpty)
        XCTAssertTrue(feedback.progressPulse)
        clock.advance(1)
        XCTAssertFalse(feedback.progressPulse)
    }

    @MainActor func testFinalMoveGetsBriefFeedbackButRestoredOrBackgroundResultsAreImmediate() {
        let clock = RewardMotionClock(), id = UUID()
        let entrance = ResultEntrancePresentation(schedule: clock.schedule)
        entrance.update(sessionID: id, status: .playing, animate: true)
        XCTAssertFalse(entrance.shows(sessionID: id, status: .won, animate: true))
        entrance.update(sessionID: id, status: .won, animate: true)
        clock.advance(0.81)
        XCTAssertFalse(entrance.shows(sessionID: id, status: .won, animate: true))
        clock.advance(0.01)
        XCTAssertTrue(entrance.shows(sessionID: id, status: .won, animate: true))
        let restored = ResultEntrancePresentation(schedule: clock.schedule)
        XCTAssertTrue(restored.shows(sessionID: id, status: .won, animate: true))
        restored.update(sessionID: id, status: .won, animate: true)
        XCTAssertTrue(restored.ready)
        entrance.update(sessionID: UUID(), status: .playing, animate: true)
        let lossID = UUID()
        entrance.update(sessionID: lossID, status: .playing, animate: true)
        entrance.update(sessionID: lossID, status: .lost, animate: true)
        XCTAssertFalse(entrance.ready)
        entrance.update(sessionID: lossID, status: .lost, animate: false)
        XCTAssertTrue(entrance.ready)
    }

    @MainActor func testNewSessionInvalidatesPendingResultAndReducedMotionNeverWaits() {
        let clock = RewardMotionClock(), id = UUID(), next = UUID()
        let entrance = ResultEntrancePresentation(schedule: clock.schedule)
        entrance.update(sessionID: id, status: .playing, animate: true)
        entrance.update(sessionID: id, status: .lost, animate: true)
        entrance.update(sessionID: next, status: .playing, animate: true)
        clock.advance(2)
        XCTAssertFalse(entrance.shows(sessionID: next, status: .playing, animate: true))
        entrance.update(sessionID: next, status: .won, animate: false)
        XCTAssertTrue(entrance.shows(sessionID: next, status: .won, animate: false))
    }

    @MainActor func testRepeatedComboTierStillGetsANewVisibleAcknowledgement() {
        let clock = RewardMotionClock(), feedback = GameFeedbackPresentation(schedule: clock.schedule)
        feedback.combo(.init(text: "Great", delay: 0))
        let first = feedback.comboRevision
        feedback.combo(.init(text: "Great", delay: 0))
        XCTAssertNotEqual(first, feedback.comboRevision)
        feedback.setPresentationEnabled(false)
        clock.advance(2)
        XCTAssertNil(feedback.comboText)
    }
}

final class GameFeelVisualTests: XCTestCase {
    @MainActor func testActualMovesAndResultPresentationCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("game-feel-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true
        model.start(level: 6)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        var frames: [String: CGRect] = [:]
        let host = UIHostingController(rootView: RootView().environmentObject(model).environment(\.scenePhase, .active)
            .environment(\.capyLayoutObserver, { frames[$0] = $1 }))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: directory)
        }
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let solution = try XCTUnwrap(model.session).puzzle.solution
        for index in solution.prefix(3) {
            model.submit(index)
            try await Task.sleep(nanoseconds: 140_000_000)
            capture("correct-progress-flight-\(index)")
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertEqual(model.session?.found.count, 3)
        let combo = try XCTUnwrap(frames["combo_feedback"])
        let board = try XCTUnwrap(frames["puzzle_board"])
        let level = try XCTUnwrap(frames["level_title"])
        XCTAssertLessThanOrEqual(combo.maxY, board.minY + 1, "Combo must not cover the board's first row.")
        XCTAssertGreaterThan(combo.minY, level.maxY, "Combo must not obscure the level number.")
        capture("combo-progress-after-three")
        for index in solution.dropFirst(3) { model.submit(index) }
        XCTAssertEqual(model.session?.status, .won)
        let committedResult = model.session
        model.submit(solution[0])
        model.toggle((0..<36).first(where: { !solution.contains($0) }) ?? 0)
        XCTAssertEqual(model.session, committedResult, "Visual result delay must not postpone input locking.")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(frames["result_primary_action"], "Result actions must precede the decoration window.")
        capture("final-move-before-result")
        try await Task.sleep(nanoseconds: 750_000_000)
        capture("win-celebration")
        XCTAssertEqual(model.session?.found.count, solution.count)
    }
}
