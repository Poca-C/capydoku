import XCTest
import CoreGraphics
import CapydokuCore
@testable import Capydoku

@MainActor private final class HUDPresentationClock {
    private(set) var now = 0.0
    private var jobs: [(time: Double, action: () -> Void)] = []

    func schedule(_ delay: Double, _ action: @escaping () -> Void) {
        jobs.append((now + delay, action))
    }

    func advance(_ interval: Double) {
        let end = now + interval
        while let next = jobs.indices.filter({ jobs[$0].time <= end })
            .min(by: { jobs[$0].time < jobs[$1].time }) {
            let job = jobs.remove(at: next)
            now = job.time
            job.action()
        }
        now = end
    }
}

final class GameHUDPresentationTests: XCTestCase {
    @MainActor func testDisabledPresentationRejectsLateVisibleCallbacksButKeepsBaselinesForResume() {
        let clock = HUDPresentationClock(), session = UUID()
        let hud = GameHUDPresentation(schedule: clock.schedule)
        let rewards = GameRewardPresentation(schedule: clock.schedule)
        hud.bind(sessionID: session, lives: 3)
        rewards.bind(sessionID: session, score: 100)
        hud.lifeChanged(2, sessionID: session, visible: true)
        hud.conflict([.row], sessionID: session, visible: true)
        rewards.scoreChanged(120, sessionID: session, visible: true)
        rewards.scoreAward(20, sessionID: session, origin: .zero, reduceMotion: false)
        rewards.found(index: 0, sessionID: session, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertFalse(hud.lifeLosses.isEmpty)
        XCTAssertFalse(rewards.localScores.isEmpty)

        hud.setPresentationEnabled(false)
        rewards.setPresentationEnabled(false)
        // These closures captured visible=true before the app went into the background.
        hud.conflict([.column], sessionID: session, visible: true)
        hud.lifeChanged(1, sessionID: session, visible: true)
        rewards.scoreChanged(180, sessionID: session, visible: true)
        rewards.scoreChanged(200, sessionID: session, visible: false)
        rewards.scoreAward(80, sessionID: session, origin: .zero, reduceMotion: false)
        rewards.found(index: 1, sessionID: session, origin: .zero, destination: .zero, reduceMotion: false)
        clock.advance(1)
        XCTAssertTrue(hud.highlightedRules.isEmpty)
        XCTAssertTrue(hud.lifeLosses.isEmpty)
        XCTAssertTrue(rewards.localScores.isEmpty)
        XCTAssertTrue(rewards.flights.isEmpty)
        XCTAssertNil(rewards.scoreDelta)
        XCTAssertFalse(rewards.progressPulse)

        hud.setPresentationEnabled(true)
        rewards.setPresentationEnabled(true)
        hud.lifeChanged(1, sessionID: session, visible: true)
        rewards.scoreChanged(200, sessionID: session, visible: true)
        rewards.found(index: 1, sessionID: session, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertTrue(hud.lifeLosses.isEmpty)
        XCTAssertNil(rewards.scoreDelta)
        XCTAssertTrue(rewards.flights.isEmpty, "A hidden reveal must not replay when its callback is delivered again.")

        hud.lifeChanged(0, sessionID: session, visible: true)
        hud.conflict([.adjacent], sessionID: session, visible: true)
        rewards.scoreChanged(225, sessionID: session, visible: true)
        rewards.scoreAward(25, sessionID: session, origin: CGPoint(x: 60, y: 80), reduceMotion: false)
        rewards.found(index: 2, sessionID: session, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertEqual(hud.lifeLosses.map(\.index), [0])
        XCTAssertEqual(hud.highlightedRules, [.adjacent])
        XCTAssertEqual(rewards.scoreDelta, 25, "Hidden score changes establish the baseline rather than accumulate a deferred award.")
        XCTAssertEqual(rewards.localScores.map(\.amount), [25])
        XCTAssertEqual(rewards.flights.count, 1)
        clock.advance(0.44)
        XCTAssertTrue(rewards.progressPulse)
        clock.advance(0.60)
        XCTAssertTrue(hud.lifeLosses.isEmpty)
        XCTAssertTrue(hud.highlightedRules.isEmpty)
        XCTAssertTrue(rewards.localScores.isEmpty)
        XCTAssertTrue(rewards.flights.isEmpty)
        XCTAssertFalse(rewards.progressPulse)
    }

    @MainActor func testInitialAndRestoredLivesEstablishBaselineWithoutReplayingLoss() {
        let clock = HUDPresentationClock(), feedback = GameHUDPresentation(schedule: clock.schedule)
        let first = UUID(), restored = UUID()
        feedback.bind(sessionID: first, lives: 2)
        feedback.lifeChanged(2, sessionID: first, visible: true)
        XCTAssertTrue(feedback.lifeLosses.isEmpty)
        // A session arriving through observation rather than onAppear is also a baseline.
        feedback.lifeChanged(1, sessionID: restored, visible: true)
        clock.advance(1)
        XCTAssertTrue(feedback.lifeLosses.isEmpty)
        XCTAssertTrue(feedback.highlightedRules.isEmpty)
    }

    @MainActor func testOneCommittedLifeLossAcknowledgesOnceAndExpires() throws {
        let clock = HUDPresentationClock(), feedback = GameHUDPresentation(schedule: clock.schedule)
        let session = UUID()
        feedback.bind(sessionID: session, lives: 3)
        feedback.lifeChanged(2, sessionID: session, visible: true)
        let effect = try XCTUnwrap(feedback.lifeLosses.first)
        XCTAssertEqual(feedback.lifeLosses.map(\.index), [2])
        feedback.lifeChanged(2, sessionID: session, visible: true)
        XCTAssertEqual(feedback.lifeLosses.map(\.id), [effect.id], "Repeated observation must not spend or animate another life.")
        clock.advance(0.47)
        XCTAssertEqual(feedback.lifeLosses.map(\.id), [effect.id])
        clock.advance(0.02)
        XCTAssertTrue(feedback.lifeLosses.isEmpty)
    }

    @MainActor func testReviveThenLosingSameHeartDoesNotLetOldExpiryEraseNewEffect() throws {
        let clock = HUDPresentationClock(), feedback = GameHUDPresentation(schedule: clock.schedule)
        let session = UUID()
        feedback.bind(sessionID: session, lives: 3)
        feedback.lifeChanged(2, sessionID: session, visible: true)
        let first = try XCTUnwrap(feedback.lifeLosses.first)
        clock.advance(0.30)
        feedback.lifeChanged(3, sessionID: session, visible: true)
        feedback.lifeChanged(2, sessionID: session, visible: true)
        let second = try XCTUnwrap(feedback.lifeLosses.first)
        XCTAssertEqual(second.index, first.index)
        XCTAssertNotEqual(second.id, first.id)
        clock.advance(0.19)
        XCTAssertEqual(feedback.lifeLosses.map(\.id), [second.id])
        clock.advance(0.30)
        XCTAssertTrue(feedback.lifeLosses.isEmpty)
    }

    @MainActor func testHiddenLifeChangesAreNewBaselineAndNeverDeferredLosses() {
        let clock = HUDPresentationClock(), feedback = GameHUDPresentation(schedule: clock.schedule)
        let session = UUID()
        feedback.bind(sessionID: session, lives: 3)
        feedback.lifeChanged(2, sessionID: session, visible: false)
        feedback.lifeChanged(2, sessionID: session, visible: true)
        XCTAssertTrue(feedback.lifeLosses.isEmpty)
        feedback.lifeChanged(1, sessionID: session, visible: true)
        XCTAssertEqual(feedback.lifeLosses.map(\.index), [1], "Only the newly committed visible loss is acknowledged.")
    }

    @MainActor func testSessionReplacementAndClearInvalidatePriorLifeCallbacks() throws {
        let clock = HUDPresentationClock(), feedback = GameHUDPresentation(schedule: clock.schedule)
        let first = UUID(), next = UUID()
        feedback.bind(sessionID: first, lives: 3)
        feedback.lifeChanged(2, sessionID: first, visible: true)
        clock.advance(0.30)
        feedback.bind(sessionID: next, lives: 3)
        feedback.lifeChanged(2, sessionID: next, visible: true)
        let replacement = try XCTUnwrap(feedback.lifeLosses.first)
        clock.advance(0.19)
        XCTAssertEqual(feedback.lifeLosses.map(\.id), [replacement.id])
        feedback.clear()
        XCTAssertTrue(feedback.lifeLosses.isEmpty)
        feedback.lifeChanged(1, sessionID: next, visible: true)
        let afterClear = try XCTUnwrap(feedback.lifeLosses.first)
        clock.advance(0.30)
        XCTAssertEqual(feedback.lifeLosses.map(\.id), [afterClear.id], "Callbacks from cleared presentation cannot touch its replacement.")
        clock.advance(0.19)
        XCTAssertTrue(feedback.lifeLosses.isEmpty)
    }

    @MainActor func testNoVisibleConflictImmediatelyClearsPreviousRulesAndInvalidatesItsExpiry() {
        let clock = HUDPresentationClock(), feedback = GameHUDPresentation(schedule: clock.schedule)
        let session = UUID()
        feedback.bind(sessionID: session, lives: 3)
        feedback.conflict([.region, .row], sessionID: session, visible: true)
        XCTAssertEqual(feedback.highlightedRules, [.region, .row])
        clock.advance(0.30)
        feedback.conflict([], sessionID: session, visible: true)
        XCTAssertTrue(feedback.highlightedRules.isEmpty)
        feedback.conflict([.adjacent], sessionID: session, visible: true)
        clock.advance(0.61)
        XCTAssertEqual(feedback.highlightedRules, [.adjacent])
        clock.advance(0.30)
        XCTAssertTrue(feedback.highlightedRules.isEmpty)
    }

    @MainActor func testReplacingHidingClearingAndChangingSessionCannotReplayRuleHighlights() {
        let clock = HUDPresentationClock(), feedback = GameHUDPresentation(schedule: clock.schedule)
        let session = UUID(), next = UUID()
        feedback.bind(sessionID: session, lives: 3)
        feedback.conflict([.row], sessionID: session, visible: true)
        clock.advance(0.50)
        feedback.conflict([.column, .column], sessionID: session, visible: true)
        clock.advance(0.41)
        XCTAssertEqual(feedback.highlightedRules, [.column])
        feedback.conflict([.region], sessionID: session, visible: false)
        XCTAssertTrue(feedback.highlightedRules.isEmpty)
        feedback.conflict([.adjacent], sessionID: session, visible: true)
        feedback.clear()
        clock.advance(1)
        XCTAssertTrue(feedback.highlightedRules.isEmpty)
        feedback.bind(sessionID: next, lives: 3)
        feedback.conflict([.row], sessionID: session, visible: true)
        XCTAssertTrue(feedback.highlightedRules.isEmpty, "A callback from another board cannot highlight this board's rules.")
        feedback.conflict([.region], sessionID: next, visible: true)
        XCTAssertEqual(feedback.highlightedRules, [.region])
    }

    @MainActor func testLocalScoreRejectsUnboundWrongSessionNonpositiveAndNonfiniteInputs() {
        let clock = HUDPresentationClock(), feedback = GameRewardPresentation(schedule: clock.schedule)
        let session = UUID()
        feedback.scoreAward(10, sessionID: session, origin: .zero, reduceMotion: false)
        XCTAssertTrue(feedback.localScores.isEmpty)
        feedback.bind(sessionID: session, score: 500)
        XCTAssertTrue(feedback.localScores.isEmpty, "Restoring committed score does not replay a local award.")
        for amount in [Int.min, -1, 0] {
            feedback.scoreAward(amount, sessionID: session, origin: .zero, reduceMotion: false)
        }
        for origin in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: CGFloat.infinity, y: 0),
                       CGPoint(x: -CGFloat.infinity, y: 0), CGPoint(x: 0, y: CGFloat.nan),
                       CGPoint(x: 0, y: CGFloat.infinity), CGPoint(x: 0, y: -CGFloat.infinity)] {
            feedback.scoreAward(10, sessionID: session, origin: origin, reduceMotion: false)
        }
        feedback.scoreAward(10, sessionID: UUID(), origin: .zero, reduceMotion: false)
        clock.advance(1)
        XCTAssertTrue(feedback.localScores.isEmpty)
        feedback.scoreAward(25, sessionID: session, origin: CGPoint(x: 40, y: 80), reduceMotion: true)
        XCTAssertEqual(feedback.localScores.map(\.amount), [25])
        XCTAssertEqual(feedback.localScores.first?.origin, CGPoint(x: 40, y: 80))
        XCTAssertEqual(feedback.localScores.first?.reduceMotion, true)
    }

    @MainActor func testLocalScoresStayBoundedAndExpireIndividually() {
        let clock = HUDPresentationClock(), feedback = GameRewardPresentation(schedule: clock.schedule)
        let session = UUID()
        feedback.bind(sessionID: session, score: 0)
        for amount in 1...6 {
            feedback.scoreAward(amount, sessionID: session, origin: .zero, reduceMotion: false)
            clock.advance(0.05)
        }
        XCTAssertEqual(feedback.localScores.map(\.amount), [3, 4, 5, 6])
        clock.advance(0.43) // The first (already evicted) award expires at 0.72.
        XCTAssertEqual(feedback.localScores.map(\.amount), [3, 4, 5, 6])
        clock.advance(0.10)
        XCTAssertEqual(feedback.localScores.map(\.amount), [4, 5, 6])
        clock.advance(0.15)
        XCTAssertTrue(feedback.localScores.isEmpty)
    }

    @MainActor func testLocalScoreClearAndSessionReplacementInvalidateOldExpiry() throws {
        let clock = HUDPresentationClock(), feedback = GameRewardPresentation(schedule: clock.schedule)
        let session = UUID(), next = UUID()
        feedback.bind(sessionID: session, score: 0)
        feedback.scoreAward(10, sessionID: session, origin: .zero, reduceMotion: false)
        clock.advance(0.40)
        feedback.clear()
        XCTAssertTrue(feedback.localScores.isEmpty)
        feedback.scoreAward(20, sessionID: session, origin: .zero, reduceMotion: false)
        let afterClear = try XCTUnwrap(feedback.localScores.first)
        clock.advance(0.33)
        XCTAssertEqual(feedback.localScores.map(\.id), [afterClear.id])
        feedback.bind(sessionID: next, score: 90)
        XCTAssertTrue(feedback.localScores.isEmpty)
        feedback.scoreAward(30, sessionID: session, origin: .zero, reduceMotion: false)
        XCTAssertTrue(feedback.localScores.isEmpty)
        feedback.scoreAward(40, sessionID: next, origin: .zero, reduceMotion: false)
        let afterBind = try XCTUnwrap(feedback.localScores.first)
        clock.advance(0.40)
        XCTAssertEqual(feedback.localScores.map(\.id), [afterBind.id])
        clock.advance(0.33)
        XCTAssertTrue(feedback.localScores.isEmpty)
    }
}
