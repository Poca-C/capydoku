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
    @MainActor func testApplauseIsSinglePerAcceptedFindAndOldExpiryCannotEraseTheNext() throws {
        let clock = RewardMotionClock(), id = UUID(), reward = GameRewardPresentation(schedule: clock.schedule)
        reward.bind(sessionID: id, score: 100)
        XCTAssertNil(reward.applauseID, "Restoring score is not a fresh celebration.")
        reward.found(index: 1, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        let first = try XCTUnwrap(reward.applauseID)
        reward.found(index: 1, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertEqual(reward.applauseID, first)
        clock.advance(0.40)
        reward.found(index: 2, sessionID: id, origin: .zero, destination: .zero, reduceMotion: true)
        let second = try XCTUnwrap(reward.applauseID)
        XCTAssertNotEqual(first, second, "Static acknowledgement still belongs to the new find.")
        clock.advance(0.36)
        XCTAssertEqual(reward.applauseID, second)
        reward.clear()
        XCTAssertNil(reward.applauseID)
        XCTAssertTrue(reward.flights.isEmpty, "A newer mistake ends existing visual celebration.")
        reward.setPresentationEnabled(false)
        reward.found(index: 4, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        reward.setPresentationEnabled(true)
        reward.found(index: 4, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertNil(reward.applauseID, "Hidden finds are consumed, not replayed.")
        reward.found(index: 5, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertNotNil(reward.applauseID)
        reward.bind(sessionID: UUID(), score: 0)
        clock.advance(2)
        XCTAssertNil(reward.applauseID)
    }

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
        XCTAssertNotNil(feedback.progressArrivalID)
        feedback.bind(sessionID: next, score: 100)
        feedback.found(index: 0, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        clock.advance(1)
        XCTAssertTrue(feedback.flights.isEmpty)
        XCTAssertFalse(feedback.progressPulse)
        XCTAssertNil(feedback.progressArrivalID)
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
        let firstArrival = feedback.progressArrivalID
        XCTAssertNotNil(firstArrival)
        clock.advance(0.04)
        feedback.found(index: 2, sessionID: id, origin: .zero, destination: .zero, reduceMotion: true)
        let nextArrival = feedback.progressArrivalID
        XCTAssertNotEqual(nextArrival, firstArrival, "Arrivals inside the old Boolean's hold window still have distinct identities.")
        feedback.found(index: 2, sessionID: id, origin: .zero, destination: .zero, reduceMotion: true)
        XCTAssertEqual(feedback.progressArrivalID, nextArrival, "A duplicate find is not another HUD arrival.")
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
    @MainActor private func applause(in view: UIView) -> ApplauseFeedbackUIView? {
        (view as? ApplauseFeedbackUIView) ?? view.subviews.lazy.compactMap { self.applause(in: $0) }.first
    }

    @MainActor func testActualRootApplauseFitsBesideComboAndStopsForLaterMistake() async throws {
        for (width, language) in [(CGFloat(320), AppLanguage.simplifiedChinese), (CGFloat(402), AppLanguage.english)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("applause-root-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.settings.language = language
            model.progress.tutorialCompleted = true; model.start(level: 6)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: width == 320 ? 568 : 874)
            var frames: [String: CGRect] = [:]
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: false).environmentObject(model)
                .environment(\.scenePhase, .active)
                .environment(\.capyLayoutObserver, { frames[$0] = $1 }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            func capture(_ stage: String) {
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
                }
                let a = XCTAttachment(image: image); a.name = "applause-root-\(Int(width))pt-\(stage)"; a.lifetime = .keepAlways; add(a)
            }
            try await Task.sleep(nanoseconds: 180_000_000)
            let solution = try XCTUnwrap(model.session).puzzle.solution
            let boardBefore = try XCTUnwrap(frames["puzzle_board"])
            model.submit(solution[0])
            try await Task.sleep(nanoseconds: 120_000_000)
            let firstView = try XCTUnwrap(applause(in: host.view))
            let firstID = try XCTUnwrap(firstView.activeEventID)
            capture("first-correct")
            model.submit(solution[1])
            try await Task.sleep(nanoseconds: 90_000_000)
            XCTAssertNotEqual(firstView.activeEventID, firstID)
            model.submit(solution[2])
            try await Task.sleep(nanoseconds: 180_000_000)
            XCTAssertNotNil(firstView.activeEventID)
            let clap = try XCTUnwrap(frames["applause_feedback"]), combo = try XCTUnwrap(frames["combo_feedback"])
            let rules = try XCTUnwrap(frames["rule_strip"]), board = try XCTUnwrap(frames["puzzle_board"])
            XCTAssertLessThanOrEqual(clap.maxY, board.minY + 0.5)
            XCTAssertGreaterThanOrEqual(clap.minY, rules.maxY - 0.5)
            XCTAssertFalse(clap.intersects(combo), "Encouragement must fit beside translated Combo text.")
            XCTAssertTrue(host.view.bounds.contains(clap))
            XCTAssertEqual(board, boardBefore, "A fresh decoration must not shift the playable board.")
            XCTAssertFalse(firstView.isUserInteractionEnabled); XCTAssertTrue(firstView.accessibilityElementsHidden)
            capture("continuous-combo")
            let accepted = try XCTUnwrap(model.session)
            let wrong = try XCTUnwrap((0..<(accepted.puzzle.size * accepted.puzzle.size)).first { !solution.contains($0) })
            model.submit(wrong)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNil(firstView.activeEventID)
            XCTAssertEqual(model.session?.found, accepted.found); XCTAssertEqual(model.session?.score, accepted.score)
            XCTAssertEqual(model.session?.lives, 2)
            capture("mistake-no-applause")
            model.start(level: 6)
            try await Task.sleep(nanoseconds: 120_000_000)
            // Deliberately coalesce a real correct and incorrect submission.
            model.submit(solution[0]); model.submit(wrong)
            try await Task.sleep(nanoseconds: 120_000_000)
            let nextView = try XCTUnwrap(applause(in: host.view))
            XCTAssertFalse(firstView === nextView, "Consumed event storage is scoped to one board.")
            XCTAssertNil(nextView.activeEventID)
            XCTAssertEqual(model.session?.found.count, 1); XCTAssertEqual(model.session?.lives, 2)
            capture("coalesced-correct-wrong-no-applause")
        }
    }

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
        XCTAssertNotNil(try XCTUnwrap(applause(in: host.view)).activeEventID, "A genuine final find still gets encouragement.")
        capture("final-move-before-result")
        // Requested sampling delays identify broad phases, not measured frame
        // timestamps. Keep the existing win-celebration capture for comparison.
        try await Task.sleep(nanoseconds: 500_000_000)
        capture("final-combo-board-phase-before-result-decoration")
        XCTAssertEqual(frames["puzzle_board"], board, "Preserving the Combo band must not shift the completed board.")
        try await Task.sleep(nanoseconds: 250_000_000)
        capture("win-celebration")
        try await Task.sleep(nanoseconds: 250_000_000)
        capture("result-title-entered-without-underlying-combo")
        XCTAssertNil(try XCTUnwrap(applause(in: host.view)).activeEventID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        capture("result-settled-without-underlying-combo")
        XCTAssertEqual(frames["puzzle_board"], board)
        XCTAssertNotNil(frames["result_primary_action"])
        XCTAssertEqual(model.session, committedResult, "Hiding Combo decoration changes no result or reward state.")
        XCTAssertEqual(model.session?.found.count, solution.count)
    }
}
