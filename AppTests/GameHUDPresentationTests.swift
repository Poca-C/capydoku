import XCTest
import CoreGraphics
import UIKit
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
        rewards.scoreAward(20, sessionID: session, placement: CellScorePlacement(amount: 20, center: .zero), reduceMotion: false)
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
        rewards.scoreAward(80, sessionID: session, placement: CellScorePlacement(amount: 80, center: .zero), reduceMotion: false)
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
        rewards.scoreAward(25, sessionID: session, placement: CellScorePlacement(amount: 25, center: CGPoint(x: 60, y: 80)), reduceMotion: false)
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
        feedback.scoreAward(10, sessionID: session, placement: CellScorePlacement(amount: 10, center: .zero), reduceMotion: false)
        XCTAssertTrue(feedback.localScores.isEmpty)
        feedback.bind(sessionID: session, score: 500)
        XCTAssertTrue(feedback.localScores.isEmpty, "Restoring committed score does not replay a local award.")
        for amount in [Int.min, -1, 0] {
            feedback.scoreAward(amount, sessionID: session, placement: CellScorePlacement(amount: amount, center: .zero), reduceMotion: false)
        }
        for origin in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: CGFloat.infinity, y: 0),
                       CGPoint(x: -CGFloat.infinity, y: 0), CGPoint(x: 0, y: CGFloat.nan),
                       CGPoint(x: 0, y: CGFloat.infinity), CGPoint(x: 0, y: -CGFloat.infinity)] {
            feedback.scoreAward(10, sessionID: session, placement: CellScorePlacement(amount: 10, center: origin), reduceMotion: false)
        }
        feedback.scoreAward(10, sessionID: UUID(), placement: CellScorePlacement(amount: 10, center: .zero), reduceMotion: false)
        clock.advance(1)
        XCTAssertTrue(feedback.localScores.isEmpty)
        feedback.scoreAward(25, sessionID: session, placement: CellScorePlacement(amount: 25, center: CGPoint(x: 40, y: 80)), reduceMotion: true)
        XCTAssertEqual(feedback.localScores.map(\.amount), [25])
        XCTAssertEqual(feedback.localScores.first?.origin, CGPoint(x: 40, y: 80))
        XCTAssertEqual(feedback.localScores.first?.reduceMotion, true)
    }

    @MainActor func testLocalScoresStayBoundedAndExpireIndividually() {
        let clock = HUDPresentationClock(), feedback = GameRewardPresentation(schedule: clock.schedule)
        let session = UUID()
        feedback.bind(sessionID: session, score: 0)
        for amount in 1...6 {
            let placement = CellScorePlacement(amount: amount, center: CGPoint(x: CGFloat(amount) * 70, y: 80))
            feedback.scoreAward(amount, sessionID: session, placement: placement, reduceMotion: false)
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

    @MainActor func testOverlappingSameAmountScoreReplacesOnlyItsPredecessorAndKeepsIndependentExpiry() throws {
        for reduceMotion in [false, true] {
            let clock = HUDPresentationClock(), feedback = GameRewardPresentation(schedule: clock.schedule)
            let session = UUID()
            feedback.bind(sessionID: session, score: 0)
            feedback.scoreChanged(100, sessionID: session, visible: true)
            let nearby = CellScorePlacement(amount: 100, center: CGPoint(x: 50, y: 90))
            feedback.scoreAward(100, sessionID: session, placement: nearby, reduceMotion: reduceMotion)
            let first = try XCTUnwrap(feedback.localScores.first)
            clock.advance(0.10)
            feedback.scoreAward(140, sessionID: session,
                                placement: CellScorePlacement(amount: 140, center: CGPoint(x: 240, y: 90)),
                                reduceMotion: reduceMotion)
            let separate = try XCTUnwrap(feedback.localScores.last)
            XCTAssertFalse(nearby.sweptFrame.intersects(separate.placement.sweptFrame))
            XCTAssertEqual(feedback.localScores.map(\.id), [first.id, separate.id])

            clock.advance(0.20)
            feedback.scoreAward(100, sessionID: UUID(), placement: nearby, reduceMotion: reduceMotion)
            feedback.scoreAward(0, sessionID: session, placement: nearby, reduceMotion: reduceMotion)
            XCTAssertEqual(feedback.localScores.map(\.id), [first.id, separate.id],
                           "Rejected events cannot retire a valid acknowledgement at the same position.")
            feedback.scoreAward(100, sessionID: session, placement: nearby, reduceMotion: reduceMotion)
            let replacement = try XCTUnwrap(feedback.localScores.last)
            XCTAssertNotEqual(replacement.id, first.id)
            XCTAssertEqual(replacement.amount, first.amount)
            XCTAssertEqual(replacement.reduceMotion, reduceMotion)
            XCTAssertEqual(feedback.localScores.map(\.id), [separate.id, replacement.id],
                           "Only the overlapping predecessor retires; a separate badge keeps its identity.")
            XCTAssertEqual(feedback.scoreDelta, 100, "Local collision handling must not reset the HUD reward.")

            clock.advance(0.43) // t=0.73: the first badge's original expiry has run.
            XCTAssertEqual(feedback.localScores.map(\.id), [separate.id, replacement.id],
                           "An old same-amount expiry cannot delete the replacement.")
            clock.advance(0.10) // t=0.83: the separate badge keeps its original deadline.
            XCTAssertEqual(feedback.localScores.map(\.id), [replacement.id])
            clock.advance(0.20)
            XCTAssertTrue(feedback.localScores.isEmpty)
        }
    }

    @MainActor func testNewScoreRetiresAnOldBadgeWhoseTravelCrossesItEvenWhenStartingFramesAreSeparate() throws {
        let clock = HUDPresentationClock(), feedback = GameRewardPresentation(schedule: clock.schedule)
        let session = UUID()
        feedback.bind(sessionID: session, score: 0)
        let firstPlacement = CellScorePlacement(amount: 100, center: CGPoint(x: 70, y: 110), verticalTravel: -12)
        feedback.scoreAward(100, sessionID: session, placement: firstPlacement, reduceMotion: false)
        let first = try XCTUnwrap(feedback.localScores.first)
        feedback.scoreAward(180, sessionID: session,
                            placement: CellScorePlacement(amount: 180, center: CGPoint(x: 250, y: 110)),
                            reduceMotion: false)
        let separate = try XCTUnwrap(feedback.localScores.last)
        let incoming = CellScorePlacement(amount: 140,
            center: CGPoint(x: 70, y: firstPlacement.center.y - firstPlacement.size.height - 6), verticalTravel: 12)
        func startFrame(_ placement: CellScorePlacement) -> CGRect {
            CGRect(x: placement.center.x - placement.size.width / 2,
                   y: placement.center.y - placement.size.height / 2,
                   width: placement.size.width, height: placement.size.height)
        }
        XCTAssertFalse(startFrame(firstPlacement).intersects(startFrame(incoming)),
                       "This regression must exercise future travel, not just identical initial rectangles.")
        XCTAssertTrue(firstPlacement.sweptFrame.intersects(incoming.sweptFrame))
        XCTAssertFalse(separate.placement.sweptFrame.intersects(incoming.sweptFrame))
        clock.advance(0.30)
        feedback.scoreAward(140, sessionID: session, placement: incoming, reduceMotion: false)
        let replacement = try XCTUnwrap(feedback.localScores.last)
        XCTAssertEqual(feedback.localScores.map(\.id), [separate.id, replacement.id])
        XCTAssertFalse(feedback.localScores.contains { $0.id == first.id })
        clock.advance(0.43)
        XCTAssertEqual(feedback.localScores.map(\.id), [replacement.id])
        clock.advance(0.30)
        XCTAssertTrue(feedback.localScores.isEmpty)
    }

    @MainActor func testClearAndSessionReplacementInvalidateExpiryOfBothRetiredAndReplacementScores() throws {
        for replaceSession in [false, true] {
            let clock = HUDPresentationClock(), feedback = GameRewardPresentation(schedule: clock.schedule)
            let session = UUID(), next = replaceSession ? UUID() : session
            let placement = CellScorePlacement(amount: 100, center: CGPoint(x: 80, y: 110))
            feedback.bind(sessionID: session, score: 0)
            feedback.scoreAward(100, sessionID: session, placement: placement, reduceMotion: false)
            let first = try XCTUnwrap(feedback.localScores.first)
            clock.advance(0.20)
            feedback.scoreAward(100, sessionID: session, placement: placement, reduceMotion: true)
            let second = try XCTUnwrap(feedback.localScores.last)
            XCTAssertEqual(feedback.localScores.map(\.id), [second.id])
            XCTAssertNotEqual(second.id, first.id)
            clock.advance(0.20)
            if replaceSession { feedback.bind(sessionID: next, score: 200) }
            else { feedback.clear() }
            XCTAssertTrue(feedback.localScores.isEmpty)
            if replaceSession {
                feedback.scoreAward(100, sessionID: session, placement: placement, reduceMotion: true)
                XCTAssertTrue(feedback.localScores.isEmpty)
            }
            feedback.scoreAward(100, sessionID: next, placement: placement, reduceMotion: true)
            let current = try XCTUnwrap(feedback.localScores.first)
            XCTAssertNotEqual(current.id, second.id)
            clock.advance(0.33) // t=0.73: original retired badge expires.
            XCTAssertEqual(feedback.localScores.map(\.id), [current.id])
            clock.advance(0.20) // t=0.93: the pre-clear/pre-bind replacement expires.
            XCTAssertEqual(feedback.localScores.map(\.id), [current.id])
            clock.advance(0.20)
            XCTAssertTrue(feedback.localScores.isEmpty)
        }
    }

    @MainActor func testLocalScoreClearAndSessionReplacementInvalidateOldExpiry() throws {
        let clock = HUDPresentationClock(), feedback = GameRewardPresentation(schedule: clock.schedule)
        let session = UUID(), next = UUID()
        feedback.bind(sessionID: session, score: 0)
        feedback.scoreAward(10, sessionID: session, placement: CellScorePlacement(amount: 10, center: .zero), reduceMotion: false)
        clock.advance(0.40)
        feedback.clear()
        XCTAssertTrue(feedback.localScores.isEmpty)
        feedback.scoreAward(20, sessionID: session, placement: CellScorePlacement(amount: 20, center: .zero), reduceMotion: false)
        let afterClear = try XCTUnwrap(feedback.localScores.first)
        clock.advance(0.33)
        XCTAssertEqual(feedback.localScores.map(\.id), [afterClear.id])
        feedback.bind(sessionID: next, score: 90)
        XCTAssertTrue(feedback.localScores.isEmpty)
        feedback.scoreAward(30, sessionID: session, placement: CellScorePlacement(amount: 30, center: .zero), reduceMotion: false)
        XCTAssertTrue(feedback.localScores.isEmpty)
        feedback.scoreAward(40, sessionID: next, placement: CellScorePlacement(amount: 40, center: .zero), reduceMotion: false)
        let afterBind = try XCTUnwrap(feedback.localScores.first)
        clock.advance(0.40)
        XCTAssertEqual(feedback.localScores.map(\.id), [afterBind.id])
        clock.advance(0.33)
        XCTAssertTrue(feedback.localScores.isEmpty)
    }

    @MainActor func testAnchoredLocalScoresStayInsideEveryBoardCellWithoutCrossingTheSource() throws {
        // Use the real inner-board sizes of 190/320/374pt hosts and a fractional
        // translated origin; a zero-origin-only test would miss coordinate bugs.
        for side in [CGFloat(190), 320, 374] {
            let board = CGRect(x: 17.25, y: 29.75, width: side - 14, height: side - 14)
            for count in 4...10 {
                let unit = board.width / CGFloat(count)
                for index in 0..<(count * count) {
                    let cell = CGRect(x: board.minX + CGFloat(index % count) * unit,
                                      y: board.minY + CGFloat(index / count) * unit,
                                      width: unit, height: unit)
                    for amount in [100, 140, 99_999, Int.max] {
                        let context = "host=\(side), grid=\(count), cell=\(index), amount=\(amount)"
                        let placement = try XCTUnwrap(CellScorePlacement.anchored(amount: amount,
                            cellFrame: cell, boardFrame: board), context)
                        XCTAssertTrue([placement.center.x, placement.center.y, placement.size.width,
                                       placement.size.height, placement.verticalTravel].allSatisfy(\.isFinite), context)
                        XCTAssertGreaterThan(placement.size.width, 0, context)
                        XCTAssertGreaterThanOrEqual(placement.size.height, 22, context)
                        XCTAssertLessThanOrEqual(placement.size.height, 28.5, context)
                        XCTAssertGreaterThanOrEqual(placement.fontSize, 15, context)
                        XCTAssertLessThanOrEqual(placement.fontSize, 19, context)
                        let start = CGRect(x: placement.center.x - placement.size.width / 2,
                                           y: placement.center.y - placement.size.height / 2,
                                           width: placement.size.width, height: placement.size.height)
                        let end = start.offsetBy(dx: 0, dy: placement.verticalTravel)
                        // Derive the sweep from the actual label size and travel,
                        // rather than trusting the helper's declared safe frame.
                        let actualSweep = start.union(end)
                        XCTAssertTrue(board.insetBy(dx: -0.0001, dy: -0.0001).contains(actualSweep), context)
                        XCTAssertFalse(actualSweep.intersects(cell), context)
                        XCTAssertEqual(placement.sweptFrame.minX, actualSweep.minX, accuracy: 0.0001, context)
                        XCTAssertEqual(placement.sweptFrame.minY, actualSweep.minY, accuracy: 0.0001, context)
                        XCTAssertEqual(placement.sweptFrame.width, actualSweep.width, accuracy: 0.0001, context)
                        XCTAssertEqual(placement.sweptFrame.height, actualSweep.height, accuracy: 0.0001, context)
                    }
                }
            }
        }
    }

    @MainActor func testCurrent150LevelPackPlacesEveryScoreAroundAllFoundCharactersInBothOrders() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "levels", withExtension: "json"))
        let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
        XCTAssertEqual(puzzles.count, 150, "Exercise the complete bundled level pack, not a substitute fixture.")
        for puzzle in puzzles {
            for side in [CGFloat(190), 374] {
                let board = CGRect(x: 17.25, y: 29.75, width: side - 14, height: side - 14)
                let unit = board.width / CGFloat(puzzle.size)
                for (direction, order) in [("forward", puzzle.solution), ("reverse", Array(puzzle.solution.reversed()))] {
                    var found = [CGRect]()
                    for (step, index) in order.enumerated() {
                        let cell = CGRect(x: board.minX + CGFloat(index % puzzle.size) * unit,
                                          y: board.minY + CGFloat(index / puzzle.size) * unit,
                                          width: unit, height: unit)
                        found.append(cell)
                        let context = "level=\(puzzle.id), host=\(side), order=\(direction), step=\(step), source=\(index)"
                        let placement = try XCTUnwrap(CellScorePlacement.anchored(amount: 100 + step * 20,
                            cellFrame: cell, boardFrame: board, avoiding: found), context)
                        let start = CGRect(x: placement.center.x - placement.size.width / 2,
                                           y: placement.center.y - placement.size.height / 2,
                                           width: placement.size.width, height: placement.size.height)
                        let sweep = start.union(start.offsetBy(dx: 0, dy: placement.verticalTravel))
                        XCTAssertTrue(board.insetBy(dx: -0.0001, dy: -0.0001).contains(sweep), context)
                        for character in found { XCTAssertFalse(sweep.intersects(character), context) }
                    }
                    XCTAssertEqual(found.count, puzzle.size, "Include the full-board victory find: \(puzzle.id) / \(direction).")
                }
            }
        }
    }

    @MainActor func testDensePackFinalScoresStayNearTheirSourceWithoutShrinkingOrCoveringCharacters() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "levels", withExtension: "json"))
        let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
        XCTAssertEqual(puzzles.count, 150)
        // These are the actual forward-order final finds that previously sent
        // their badges away from the source despite a nearer usable opening.
        let cases: [(level: Int, maximumDistanceInCells: CGFloat)] = [(6, 1.1), (111, 2.5)]
        for item in cases {
            let puzzle = try XCTUnwrap(puzzles.first { $0.id == item.level })
            let board = CGRect(x: 17.25, y: 29.75, width: 190 - 14, height: 190 - 14)
            let unit = board.width / CGFloat(puzzle.size)
            let found = puzzle.solution.map { index in
                CGRect(x: board.minX + CGFloat(index % puzzle.size) * unit,
                       y: board.minY + CGFloat(index / puzzle.size) * unit,
                       width: unit, height: unit)
            }
            XCTAssertEqual(found.count, puzzle.size)
            let source = try XCTUnwrap(found.last)
            let amount = 100 + (puzzle.solution.count - 1) * 20
            let context = "level=\(item.level), host=190, order=forward, final=\(puzzle.solution.last ?? -1)"
            let placement = try XCTUnwrap(CellScorePlacement.anchored(amount: amount,
                cellFrame: source, boardFrame: board, avoiding: found), context)
            let start = CGRect(x: placement.center.x - placement.size.width / 2,
                               y: placement.center.y - placement.size.height / 2,
                               width: placement.size.width, height: placement.size.height)
            let sweep = start.union(start.offsetBy(dx: 0, dy: placement.verticalTravel))
            XCTAssertTrue(board.insetBy(dx: 2, dy: 2).contains(sweep), context)
            for character in found {
                XCTAssertFalse(sweep.intersects(character.insetBy(dx: -2, dy: -2)), context)
            }
            XCTAssertGreaterThanOrEqual(placement.fontSize, 15, context)
            XCTAssertLessThanOrEqual(placement.fontSize, 19, context)
            let distanceInCells = hypot(placement.center.x - source.midX,
                                        placement.center.y - source.midY) / unit
            XCTAssertLessThanOrEqual(distanceInCells, item.maximumDistanceInCells, context)
            // The normal final score must fit at the declared font size; a
            // narrow capsule cannot silently rely on minimumScaleFactor.
            let base = UIFont.systemFont(ofSize: placement.fontSize, weight: .heavy)
            let font = UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
                              size: placement.fontSize)
            let requiredTextWidth = ("+\(amount)" as NSString).size(withAttributes: [.font: font]).width
            XCTAssertGreaterThanOrEqual(placement.size.width - 2 * placement.horizontalPadding,
                                        requiredTextWidth, context)
        }
    }

    @MainActor func testAnchoredLocalScoresAvoidEarlierCharactersAcrossCompactLevel101Sequence() throws {
        // Current fixed L101 layout: its first two finds (0 -> 12) expose the
        // old top-row badge crossing the next character on a compact board.
        let solution = [0, 12, 29, 31, 45, 53, 67, 74, 86, 98]
        for side in [CGFloat(190), 320, 374] {
            let board = CGRect(x: 17.25, y: 29.75, width: side - 14, height: side - 14)
            let unit = board.width / 10
            let cells = solution.map { index in
                CGRect(x: board.minX + CGFloat(index % 10) * unit,
                       y: board.minY + CGFloat(index / 10) * unit, width: unit, height: unit)
            }
            for step in cells.indices {
                let found = Array(cells.prefix(step + 1))
                let context = "host=\(side), source=\(solution[step]), found=\(step + 1)"
                let placement = try XCTUnwrap(CellScorePlacement.anchored(amount: 100 + step * 40,
                    cellFrame: cells[step], boardFrame: board, avoiding: found), context)
                let start = CGRect(x: placement.center.x - placement.size.width / 2,
                                   y: placement.center.y - placement.size.height / 2,
                                   width: placement.size.width, height: placement.size.height)
                let sweep = start.union(start.offsetBy(dx: 0, dy: placement.verticalTravel))
                XCTAssertTrue(board.insetBy(dx: -0.0001, dy: -0.0001).contains(sweep), context)
                for character in found { XCTAssertFalse(sweep.intersects(character), context) }
            }
        }
    }

    @MainActor func testNewCharacterRetiresOnlyOverlappingScoresAndOldExpiryCannotEraseReplacement() throws {
        let clock = HUDPresentationClock(), feedback = GameRewardPresentation(schedule: clock.schedule)
        let session = UUID()
        feedback.bind(sessionID: session, score: 0)
        feedback.scoreChanged(100, sessionID: session, visible: true)
        feedback.scoreAward(100, sessionID: session,
                            placement: CellScorePlacement(amount: 100, center: CGPoint(x: 40, y: 80)),
                            reduceMotion: false)
        let first = try XCTUnwrap(feedback.localScores.first)
        clock.advance(0.20)
        feedback.scoreAward(140, sessionID: session,
                            placement: CellScorePlacement(amount: 140, center: CGPoint(x: 200, y: 80)),
                            reduceMotion: true)
        let safe = try XCTUnwrap(feedback.localScores.last)
        // This character lies in the first badge's travel, outside its initial
        // rectangle; checking only the original center would miss the collision.
        let incomingCharacter = CGRect(x: 35, y: 55, width: 10, height: 5)
        feedback.retireScores(overlapping: [incomingCharacter], sessionID: UUID())
        XCTAssertEqual(feedback.localScores.map(\.id), [first.id, safe.id], "Stale-board geometry is ignored.")
        feedback.retireScores(overlapping: [], sessionID: session)
        XCTAssertEqual(feedback.localScores.map(\.id), [first.id, safe.id])
        feedback.retireScores(overlapping: [incomingCharacter], sessionID: session)
        XCTAssertEqual(feedback.localScores.map(\.id), [safe.id], "Keep the separate, non-overlapping acknowledgement.")
        XCTAssertEqual(feedback.localScores.first?.amount, 140)
        XCTAssertEqual(feedback.localScores.first?.reduceMotion, true)
        XCTAssertEqual(feedback.scoreDelta, 100, "Retiring local artwork does not clear the committed HUD acknowledgement.")

        clock.advance(0.39)
        feedback.scoreAward(100, sessionID: session,
                            placement: CellScorePlacement(amount: 100, center: CGPoint(x: 40, y: 80)),
                            reduceMotion: false)
        let replacement = try XCTUnwrap(feedback.localScores.last)
        XCTAssertNotEqual(replacement.id, first.id)
        clock.advance(0.14) // t=0.73: the retired first badge's timer has fired.
        XCTAssertEqual(feedback.localScores.map(\.id), [safe.id, replacement.id])
        clock.advance(0.20) // t=0.93: the unaffected badge still expires normally.
        XCTAssertEqual(feedback.localScores.map(\.id), [replacement.id])
        clock.advance(0.40)
        XCTAssertTrue(feedback.localScores.isEmpty)
    }

    /// Inspect real-pack placement and simultaneous static labels. This is a
    /// diagnostic inventory, not an assertion that every sampled layout passes.
    @MainActor func testCurrentPackLocalScoreReadabilityDiagnostics() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "levels", withExtension: "json"))
        let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
        var collisions: [[String: Any]] = [], distant: [[String: Any]] = []
        var sampled = 0
        for puzzle in puzzles {
            for side in [CGFloat(190), 374] {
                let board = CGRect(x: 17.25, y: 29.75, width: side - 14, height: side - 14)
                let unit = board.width / CGFloat(puzzle.size)
                for (direction, order) in [("forward", puzzle.solution), ("reverse", Array(puzzle.solution.reversed()))] {
                    let clock = HUDPresentationClock(), feedback = GameRewardPresentation(schedule: clock.schedule)
                    let session = UUID(); feedback.bind(sessionID: session, score: 0)
                    var found = [CGRect]()
                    for (step, index) in order.enumerated() {
                        let cell = CGRect(x: board.minX + CGFloat(index % puzzle.size) * unit,
                                          y: board.minY + CGFloat(index / puzzle.size) * unit, width: unit, height: unit)
                        found.append(cell)
                        let placement = try XCTUnwrap(CellScorePlacement.anchored(amount: 100 + step * 20,
                            cellFrame: cell, boardFrame: board, avoiding: found))
                        feedback.retireScores(overlapping: found, sessionID: session)
                        feedback.scoreAward(100 + step * 20, sessionID: session, placement: placement, reduceMotion: true)
                        let current = try XCTUnwrap(feedback.localScores.last)
                        func frame(_ item: GameRewardPresentation.LocalScore) -> CGRect {
                            CGRect(x: item.origin.x - item.placement.size.width / 2,
                                   y: item.origin.y - item.placement.size.height / 2,
                                   width: item.placement.size.width, height: item.placement.size.height)
                        }
                        let badge = frame(current)
                        for old in feedback.localScores.dropLast() {
                            let overlap = frame(old).intersection(badge)
                            if !overlap.isNull && !overlap.isEmpty {
                                collisions.append(["level": puzzle.id, "host": side, "order": direction,
                                    "step": step, "source": index, "oldStep": (old.amount - 100) / 20,
                                    "area": overlap.width * overlap.height, "newFrame": NSCoder.string(for: badge),
                                    "oldFrame": NSCoder.string(for: frame(old))])
                            }
                        }
                        distant.append(["level": puzzle.id, "host": side, "order": direction,
                            "step": step, "source": index, "cellWidthsFromSource": hypot(placement.center.x - cell.midX, placement.center.y - cell.midY) / unit,
                            "travel": placement.verticalTravel, "font": placement.fontSize,
                            "sourceFrame": NSCoder.string(for: cell), "scoreFrame": NSCoder.string(for: badge)])
                        sampled += 1; clock.advance(0.15)
                    }
                }
            }
        }
        collisions.sort { ($0["area"] as! CGFloat) > ($1["area"] as! CGFloat) }
        distant.sort { ($0["cellWidthsFromSource"] as! CGFloat) > ($1["cellWidthsFromSource"] as! CGFloat) }
        let data = try JSONSerialization.data(withJSONObject: [
            "sampled": sampled, "staticOverlapCount": collisions.count,
            "largestOverlaps": Array(collisions.prefix(15)), "furthestPlacements": Array(distant.prefix(15)),
            "boundary": "Actual bundled150 pack, forward/reverse and190/374pt. Requested150ms clock intervals and reduced-motion static labels; rectangle intersections do not measure raster alpha or normal-motion phase collisions."
        ], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "local-score-readability-diagnostic"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testAnchoredLocalScoreOmitsDecorationWhenTheBoardCannotFitIt() {
        let tooSmall = CGRect(x: 40, y: 70, width: 18, height: 18)
        XCTAssertNil(CellScorePlacement.anchored(amount: 140,
            cellFrame: tooSmall.insetBy(dx: 2, dy: 2), boardFrame: tooSmall))
        let board = CGRect(x: 40, y: 70, width: 190, height: 190)
        XCTAssertNil(CellScorePlacement.anchored(amount: 140, cellFrame: board, boardFrame: board),
                     "A badge must not cover the source merely because every other position is unavailable.")
    }

}
