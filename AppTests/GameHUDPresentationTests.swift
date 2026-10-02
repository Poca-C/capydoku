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

    @MainActor func testCompactLevel101FinalReverseScoreUsesSideSpaceWithoutShrinkingOrCoveringCharacters() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "levels", withExtension: "json"))
        let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
        let puzzle = try XCTUnwrap(puzzles.first { $0.id == 101 })
        // Root's compact 190pt host is centered in a 320pt content area. Its
        // 7pt board inset and 14pt content margin leave usable side space.
        let board = CGRect(x: 72, y: 200.25, width: 176, height: 176)
        let available = CGRect(x: 14, y: board.minY, width: 292, height: board.height)
        let unit = board.width / CGFloat(puzzle.size)
        let found = puzzle.solution.reversed().map { index in
            CGRect(x: board.minX + CGFloat(index % puzzle.size) * unit,
                   y: board.minY + CGFloat(index / puzzle.size) * unit, width: unit, height: unit)
        }
        let source = try XCTUnwrap(found.last)
        let amount = 100 + (found.count - 1) * 20
        let before = try XCTUnwrap(CellScorePlacement.anchored(amount: amount,
            cellFrame: source, boardFrame: board, avoiding: found))
        let after = try XCTUnwrap(CellScorePlacement.anchored(amount: amount,
            cellFrame: source, boardFrame: board, avoiding: found, availableFrame: available))
        let beforeDistance = hypot(before.center.x - source.midX, before.center.y - source.midY) / unit
        let afterDistance = hypot(after.center.x - source.midX, after.center.y - source.midY) / unit
        XCTAssertLessThan(afterDistance, beforeDistance / 2,
                          "This measured worst case must gain a visibly closer acknowledgement, not a fractional adjustment.")
        XCTAssertEqual(after.fontSize, before.fontSize, "Closer placement must not come from smaller lettering.")
        XCTAssertEqual(after.size, before.size, "Preserve the existing readable capsule dimensions.")
        XCTAssertFalse(board.contains(after.sweptFrame), "The known blocked corner must actually use its available side space.")
        XCTAssertTrue(available.insetBy(dx: 2, dy: 2).contains(after.sweptFrame))
        for character in found {
            XCTAssertFalse(after.sweptFrame.intersects(character.insetBy(dx: -2, dy: -2)))
        }
        let base = UIFont.systemFont(ofSize: after.fontSize, weight: .heavy)
        let font = UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: after.fontSize)
        let requiredTextWidth = ("+\(amount)" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThanOrEqual(after.size.width - 2 * after.horizontalPadding, requiredTextWidth)
    }

    @MainActor func testLocalScoreAvailableFrameRejectsInvalidBoundsAndNeverExpandsTheVerticalBand() throws {
        let board = CGRect(x: 72.25, y: 200.75, width: 176, height: 176)
        let source = CGRect(x: board.minX, y: board.minY, width: 17.6, height: 17.6)
        let baseline = try XCTUnwrap(CellScorePlacement.anchored(amount: 280,
            cellFrame: source, boardFrame: board))
        let invalid: [(String, CGRect)] = [
            ("null", .null), ("infinite", .infinite), ("empty", .zero),
            ("zero width", CGRect(x: 14, y: 0, width: 0, height: 1000)),
            ("zero height", CGRect(x: 14, y: 0, width: 292, height: 0)),
            ("NaN origin", CGRect(x: CGFloat.nan, y: 0, width: 292, height: 1000)),
            ("infinite width", CGRect(x: 14, y: 0, width: CGFloat.infinity, height: 1000)),
            ("missing left board edge", board.offsetBy(dx: 1, dy: 0)),
            ("missing bottom board edge", CGRect(x: 14, y: board.minY, width: 292, height: board.height - 1))
        ]
        for (reason, frame) in invalid {
            let result = try XCTUnwrap(CellScorePlacement.anchored(amount: 280,
                cellFrame: source, boardFrame: board, availableFrame: frame), reason)
            XCTAssertEqual(result.center, baseline.center, reason)
            XCTAssertEqual(result.size, baseline.size, reason)
            XCTAssertEqual(result.verticalTravel, baseline.verticalTravel, reason)
            XCTAssertEqual(result.fontSize, baseline.fontSize, reason)
        }

        let horizontalOnly = CGRect(x: 14.25, y: board.minY, width: 292, height: board.height)
        let alsoAboveAndBelow = CGRect(x: horizontalOnly.minX, y: -500,
                                      width: horizontalOnly.width, height: 2000)
        // Both top and bottom sources could otherwise escape into the rules or
        // footer. Extra available height must have no influence on placement.
        for cell in [source, source.offsetBy(dx: board.width - source.width, dy: board.height - source.height)] {
            let horizontal = try XCTUnwrap(CellScorePlacement.anchored(amount: 280,
                cellFrame: cell, boardFrame: board, availableFrame: horizontalOnly))
            let tall = try XCTUnwrap(CellScorePlacement.anchored(amount: 280,
                cellFrame: cell, boardFrame: board, availableFrame: alsoAboveAndBelow))
            XCTAssertEqual(tall.center, horizontal.center)
            XCTAssertEqual(tall.size, horizontal.size)
            XCTAssertEqual(tall.verticalTravel, horizontal.verticalTravel)
            XCTAssertEqual(tall.fontSize, horizontal.fontSize)
            XCTAssertGreaterThanOrEqual(tall.sweptFrame.minY, board.minY + 2)
            XCTAssertLessThanOrEqual(tall.sweptFrame.maxY, board.maxY - 2)
            XCTAssertFalse(tall.sweptFrame.intersects(cell.insetBy(dx: -2, dy: -2)))
        }
    }

    @MainActor func testCurrent150LevelPackSideSpaceKeepsScoresReadableAndClearAndReportsDistanceChanges() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "levels", withExtension: "json"))
        let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
        XCTAssertEqual(puzzles.count, 150)
        var comparisons = [[String: Any]]()
        var baselineDistances = [CGFloat](), expandedDistances = [CGFloat]()
        var baselineBadgeCollisions = 0, expandedBadgeCollisions = 0
        var baselineCharacterCollisions = 0, expandedCharacterCollisions = 0
        var improved = 0, unchanged = 0, farther = 0
        for puzzle in puzzles {
            for (host, content) in [(CGFloat(190), CGFloat(320)), (CGFloat(374), CGFloat(402))] {
                // A translated, fractional content origin catches accidentally
                // mixing local board coordinates with the parent's safe area.
                let board = CGRect(x: 17.25 + (content - host) / 2 + 7,
                                   y: 29.75, width: host - 14, height: host - 14)
                let available = CGRect(x: 17.25 + 14, y: board.minY,
                                       width: content - 28, height: board.height)
                let unit = board.width / CGFloat(puzzle.size)
                for (direction, order) in [("forward", puzzle.solution), ("reverse", Array(puzzle.solution.reversed()))] {
                    let clock = HUDPresentationClock(), session = UUID()
                    let beforeFeedback = GameRewardPresentation(schedule: clock.schedule)
                    let afterFeedback = GameRewardPresentation(schedule: clock.schedule)
                    beforeFeedback.bind(sessionID: session, score: 0)
                    afterFeedback.bind(sessionID: session, score: 0)
                    var found = [CGRect]()
                    for (step, index) in order.enumerated() {
                        let cell = CGRect(x: board.minX + CGFloat(index % puzzle.size) * unit,
                                          y: board.minY + CGFloat(index / puzzle.size) * unit, width: unit, height: unit)
                        found.append(cell)
                        let amount = 100 + step * 20
                        let context = "level=\(puzzle.id), host=\(host), content=\(content), order=\(direction), step=\(step), source=\(index)"
                        let before = try XCTUnwrap(CellScorePlacement.anchored(amount: amount,
                            cellFrame: cell, boardFrame: board, avoiding: found), context)
                        let after = try XCTUnwrap(CellScorePlacement.anchored(amount: amount,
                            cellFrame: cell, boardFrame: board, avoiding: found, availableFrame: available), context)
                        let beforeDistance = hypot(before.center.x - cell.midX, before.center.y - cell.midY) / unit
                        let afterDistance = hypot(after.center.x - cell.midX, after.center.y - cell.midY) / unit
                        baselineDistances.append(beforeDistance); expandedDistances.append(afterDistance)
                        if afterDistance < beforeDistance - 0.0001 { improved += 1 }
                        else if afterDistance > beforeDistance + 0.0001 { farther += 1 }
                        else { unchanged += 1 }

                        for (name, placement, feedback, bounds) in [
                            ("board only", before, beforeFeedback, board),
                            ("side space", after, afterFeedback, available)
                        ] {
                            let labelContext = "\(name): \(context)"
                            let start = CGRect(x: placement.center.x - placement.size.width / 2,
                                               y: placement.center.y - placement.size.height / 2,
                                               width: placement.size.width, height: placement.size.height)
                            let sweep = start.union(start.offsetBy(dx: 0, dy: placement.verticalTravel))
                            XCTAssertTrue(bounds.insetBy(dx: 2 - 0.0001, dy: 2 - 0.0001).contains(sweep), labelContext)
                            XCTAssertGreaterThanOrEqual(sweep.minY, board.minY + 2 - 0.0001, labelContext)
                            XCTAssertLessThanOrEqual(sweep.maxY, board.maxY - 2 + 0.0001, labelContext)
                            for character in found {
                                XCTAssertFalse(sweep.intersects(character.insetBy(dx: -2, dy: -2)), labelContext)
                            }
                            XCTAssertGreaterThanOrEqual(placement.fontSize, 15, labelContext)
                            XCTAssertLessThanOrEqual(placement.fontSize, 19, labelContext)
                            let base = UIFont.systemFont(ofSize: placement.fontSize, weight: .heavy)
                            let font = UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
                                              size: placement.fontSize)
                            let textWidth = ("+\(amount)" as NSString).size(withAttributes: [.font: font]).width
                            XCTAssertGreaterThanOrEqual(placement.size.width - 2 * placement.horizontalPadding,
                                                        textWidth, labelContext)
                            feedback.retireScores(overlapping: found, sessionID: session)
                            feedback.scoreAward(amount, sessionID: session, placement: placement, reduceMotion: false)
                            // Swept-rectangle separation is conservative: if it
                            // holds, static and every vertical drift phase are
                            // both clear, without inventing a rendering clock.
                            for (position, score) in feedback.localScores.enumerated() {
                                for older in feedback.localScores.prefix(position) {
                                    if score.placement.sweptFrame.intersects(older.placement.sweptFrame) {
                                        if name == "board only" { baselineBadgeCollisions += 1 }
                                        else { expandedBadgeCollisions += 1 }
                                    }
                                }
                                for character in found where score.placement.sweptFrame.intersects(character) {
                                    if name == "board only" { baselineCharacterCollisions += 1 }
                                    else { expandedCharacterCollisions += 1 }
                                }
                            }
                        }
                        comparisons.append([
                            "level": puzzle.id, "host": host, "content": content, "order": direction,
                            "step": step, "source": index, "foundCount": found.count,
                            "boardOnlyDistanceInCells": beforeDistance, "sideSpaceDistanceInCells": afterDistance,
                            "distanceReductionInCells": beforeDistance - afterDistance,
                            "boardOnlyFont": before.fontSize, "sideSpaceFont": after.fontSize,
                            "boardOnlySweep": NSCoder.string(for: before.sweptFrame),
                            "sideSpaceSweep": NSCoder.string(for: after.sweptFrame),
                            "sourceFrame": NSCoder.string(for: cell), "boardFrame": NSCoder.string(for: board),
                            "availableFrame": NSCoder.string(for: available)
                        ])
                        clock.advance(0.15)
                    }
                    XCTAssertEqual(found.count, puzzle.size)
                    clock.advance(1)
                    XCTAssertTrue(beforeFeedback.localScores.isEmpty)
                    XCTAssertTrue(afterFeedback.localScores.isEmpty)
                }
            }
        }
        func distanceSummary(_ distances: [CGFloat]) -> [String: Any] {
            let sorted = distances.sorted()
            return ["maximum": sorted.last ?? 0,
                    "mean": sorted.reduce(0, +) / CGFloat(max(1, sorted.count)),
                    "median": sorted[sorted.count / 2], "p95": sorted[Int(Double(sorted.count - 1) * 0.95)]]
        }
        let furthestBefore = comparisons.sorted { ($0["boardOnlyDistanceInCells"] as! CGFloat) > ($1["boardOnlyDistanceInCells"] as! CGFloat) }
        let furthestAfter = comparisons.sorted { ($0["sideSpaceDistanceInCells"] as! CGFloat) > ($1["sideSpaceDistanceInCells"] as! CGFloat) }
        let fartherCases = comparisons.filter { ($0["distanceReductionInCells"] as! CGFloat) < -0.0001 }
            .sorted { ($0["distanceReductionInCells"] as! CGFloat) < ($1["distanceReductionInCells"] as! CGFloat) }
        let data = try JSONSerialization.data(withJSONObject: [
            "sampledPerLayout": comparisons.count,
            "improved": improved, "unchanged": unchanged, "farther": farther,
            "boardOnlyDistances": distanceSummary(baselineDistances),
            "sideSpaceDistances": distanceSummary(expandedDistances),
            "boardOnlyBadgeSweepCollisions": baselineBadgeCollisions,
            "sideSpaceBadgeSweepCollisions": expandedBadgeCollisions,
            "boardOnlyCharacterCollisions": baselineCharacterCollisions,
            "sideSpaceCharacterCollisions": expandedCharacterCollisions,
            "furthestBefore": Array(furthestBefore.prefix(15)), "furthestAfter": Array(furthestAfter.prefix(15)),
            "largestDistanceIncreases": Array(fartherCases.prefix(15)),
            "boundary": "Actual bundled 150 levels; every forward/reverse prefix; 190pt host in 320pt content and 374pt host in 402pt content. Both use unchanged typography and full found-cell +2 exclusion. Concurrent rewards are committed 150ms apart on an injected clock; conservative swept rectangles are checked, not raster pixels or real input timing. Distances are diagnostics; no arbitrary global proximity target is asserted."
        ], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "local-score-side-space-0251-diagnostic"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(comparisons.count, puzzles.reduce(0) { $0 + $1.solution.count } * 4)
        XCTAssertEqual(baselineBadgeCollisions, 0)
        XCTAssertEqual(expandedBadgeCollisions, 0)
        XCTAssertEqual(baselineCharacterCollisions, 0)
        XCTAssertEqual(expandedCharacterCollisions, 0)
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

extension GameHUDPresentationTests {
    @MainActor func testScoreSearchPruningPreservesLegacyPlacementsAcrossRealBoardsAndCutsCollisionWork() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "levels", withExtension: "json"))
        let pack = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
        let levelIDs: Set<Int> = [1, 2, 6, 20, 70, 101, 150]
        let puzzles = pack.filter { levelIDs.contains($0.id) }
        XCTAssertEqual(Set(puzzles.map(\.id)), levelIDs)
        XCTAssertEqual(Set(puzzles.map(\.size)), [4, 6, 8, 10])
        let beforeCounts = CellScorePlacement.SearchDiagnostics()
        let afterCounts = CellScorePlacement.SearchDiagnostics()
        var samples = 0, prunedCases = 0, densePrunedCases = 0
        for puzzle in puzzles {
            for (host, content) in [(CGFloat(190), CGFloat(320)), (CGFloat(374), CGFloat(402))] {
                let board = CGRect(x: 17.25 + (content - host) / 2 + 7,
                                   y: 29.75, width: host - 14, height: host - 14)
                let available = CGRect(x: 17.25 + 14, y: board.minY,
                                       width: content - 28, height: board.height)
                let unit = board.width / CGFloat(puzzle.size)
                for (direction, order) in [("forward", puzzle.solution), ("reverse", Array(puzzle.solution.reversed()))] {
                    var found = [CGRect]()
                    for (step, index) in order.enumerated() {
                        let cell = CGRect(x: board.minX + CGFloat(index % puzzle.size) * unit,
                                          y: board.minY + CGFloat(index / puzzle.size) * unit,
                                          width: unit, height: unit)
                        found.append(cell)
                        for useSideSpace in [false, true] {
                            let beforeCandidateCount = beforeCounts.candidateChecks
                            let beforeObstacleCount = beforeCounts.obstacleChecks
                            let afterCandidateCount = afterCounts.candidateChecks
                            let afterObstacleCount = afterCounts.obstacleChecks
                            let beforePrunedCount = afterCounts.costPrunedCandidates
                            let amount = 100 + step * 20
                            let frame: CGRect? = useSideSpace ? available : nil
                            let context = "level=\(puzzle.id), host=\(host), order=\(direction), step=\(step), sideSpace=\(useSideSpace)"
                            let before = LegacyCellScorePlacement0264.anchored(amount: amount,
                                cellFrame: cell, boardFrame: board, avoiding: found,
                                availableFrame: frame, diagnostics: beforeCounts)
                            let after = CellScorePlacement.anchored(amount: amount,
                                cellFrame: cell, boardFrame: board, avoiding: found,
                                availableFrame: frame, diagnostics: afterCounts)
                            XCTAssertEqual(after?.center, before?.center, context)
                            XCTAssertEqual(after?.size, before?.size, context)
                            XCTAssertEqual(after?.verticalTravel, before?.verticalTravel, context)
                            XCTAssertEqual(after?.fontSize, before?.fontSize, context)
                            let pruned = afterCounts.costPrunedCandidates - beforePrunedCount
                            XCTAssertEqual(afterCounts.candidateChecks - afterCandidateCount + pruned,
                                           beforeCounts.candidateChecks - beforeCandidateCount, context)
                            XCTAssertLessThanOrEqual(afterCounts.obstacleChecks - afterObstacleCount,
                                                     beforeCounts.obstacleChecks - beforeObstacleCount, context)
                            if pruned > 0 {
                                prunedCases += 1
                                if puzzle.size == 10 && found.count >= 8 { densePrunedCases += 1 }
                            }
                            samples += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(samples, puzzles.reduce(0) { $0 + $1.size } * 8)
        XCTAssertGreaterThan(prunedCases, 0)
        XCTAssertGreaterThan(densePrunedCases, 0, "Include late 10×10 play, where the original search does the most work.")
        XCTAssertLessThan(afterCounts.candidateChecks, beforeCounts.candidateChecks)
        XCTAssertLessThan(afterCounts.obstacleChecks, beforeCounts.obstacleChecks)
        let data = try JSONSerialization.data(withJSONObject: [
            "sampledPlacements": samples, "levels": levelIDs.sorted(),
            "prunedCases": prunedCases, "denseTenByTenPrunedCases": densePrunedCases,
            "legacyCandidateChecks": beforeCounts.candidateChecks,
            "optimizedCandidateChecks": afterCounts.candidateChecks,
            "costPrunedCandidates": afterCounts.costPrunedCandidates,
            "legacyObstacleChecks": beforeCounts.obstacleChecks,
            "optimizedObstacleChecks": afterCounts.obstacleChecks,
            "boundary": "Frozen 0.2.64 algorithm versus production, identical measured fonts and real board prefixes; normal/compact, forward/reverse, side space enabled/disabled. Exact center, size, font and travel equality; deterministic geometry-operation counts, not device input latency or frame-rate claims."
        ], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "score-search-pruning-0265"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

// Frozen 0.2.64 search oracle. Keep its candidate order, geometry and tie rules
// independent of production so latency work cannot silently relocate rewards.
private struct LegacyCellScorePlacement0264 {
    let center: CGPoint
    let size: CGSize
    let verticalTravel: CGFloat
    let fontSize: CGFloat
    var horizontalPadding: CGFloat { fontSize <= 15 ? 3 : 6 }

    init(amount: Int, center: CGPoint, verticalTravel: CGFloat = -12) {
        self.init(amount: amount, center: center, verticalTravel: verticalTravel, fontSize: 19)
    }

    private init(amount: Int, center: CGPoint, verticalTravel: CGFloat, fontSize: CGFloat) {
        let base = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let font = UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: fontSize)
        let textWidth = ("+\(amount)" as NSString).size(withAttributes: [.font: font]).width
        self.center = center; self.fontSize = fontSize
        size = CGSize(width: ceil(textWidth) + (fontSize <= 15 ? 6 : 12),
                      height: max(ceil(font.lineHeight) + 4, ceil(fontSize * 24 / 19) + 4))
        self.verticalTravel = verticalTravel
    }

    private init(center: CGPoint, size: CGSize, verticalTravel: CGFloat, fontSize: CGFloat) {
        self.center = center; self.size = size; self.verticalTravel = verticalTravel; self.fontSize = fontSize
    }

    var sweptFrame: CGRect {
        let start = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                           width: size.width, height: size.height)
        return start.union(start.offsetBy(dx: 0, dy: verticalTravel))
    }

    static func anchored(amount: Int, cellFrame: CGRect, boardFrame: CGRect, avoiding: [CGRect] = [], availableFrame: CGRect? = nil, diagnostics: CellScorePlacement.SearchDiagnostics) -> LegacyCellScorePlacement0264? {
        // Short screens leave wide empty margins beside a compact board. Let
        // an edge reward use that space instead of appearing across the puzzle.
        // The board owns the vertical band: never enter rules, Combo or tools.
        let placementFrame: CGRect
        if let availableFrame, !availableFrame.isEmpty, !availableFrame.isNull, !availableFrame.isInfinite,
           [availableFrame.minX, availableFrame.minY, availableFrame.width, availableFrame.height].allSatisfy(\.isFinite),
           availableFrame.contains(boardFrame) {
            placementFrame = CGRect(x: availableFrame.minX, y: boardFrame.minY,
                                    width: availableFrame.width, height: boardFrame.height)
        } else { placementFrame = boardFrame }
        let preferredSize = max(15, min(19, cellFrame.width * 0.6))
        let preferred = place(amount: amount, cellFrame: cellFrame, boardFrame: placementFrame,
                              avoiding: avoiding, fontSize: preferredSize, diagnostics: diagnostics)
        guard preferredSize > 15 else { return preferred }
        let compact = place(amount: amount, cellFrame: cellFrame, boardFrame: placementFrame,
                            avoiding: avoiding, fontSize: 15, diagnostics: diagnostics)
        guard let preferred else { return compact }
        guard let compact else { return preferred }
        // Preserve the more readable original type unless smaller text makes
        // a material difference to its association with the new character.
        let compactCost = compact.proximityCost(to: cellFrame) + (preferredSize - 15) * 2
        return compactCost + 0.001 < preferred.proximityCost(to: cellFrame) ? compact : preferred
    }

    private func proximityCost(to cell: CGRect) -> CGFloat {
        // Small tie-break preference for visible drift; never send a badge
        // across the board merely to keep a full12pt upward movement.
        hypot(center.x - cell.midX, center.y - cell.midY) + (12 - abs(verticalTravel)) * 0.25
    }

    private static func place(amount: Int, cellFrame: CGRect, boardFrame: CGRect, avoiding: [CGRect], fontSize: CGFloat, diagnostics: CellScorePlacement.SearchDiagnostics) -> LegacyCellScorePlacement0264? {
        guard amount > 0, !cellFrame.isEmpty, !boardFrame.isEmpty,
              [cellFrame.minX, cellFrame.minY, cellFrame.width, cellFrame.height,
               boardFrame.minX, boardFrame.minY, boardFrame.width, boardFrame.height].allSatisfy(\.isFinite) else { return nil }
        let bounds = boardFrame.insetBy(dx: 2, dy: 2)
        let measured = LegacyCellScorePlacement0264(amount: amount, center: .zero, verticalTravel: -12, fontSize: fontSize)
        let size = CGSize(width: min(measured.size.width, bounds.width), height: measured.size.height)
        guard size.width > 0, bounds.height >= size.height else { return nil }
        let obstacles = [cellFrame] + avoiding.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, bounds.minX + size.width / 2), bounds.maxX - size.width / 2) }
        func candidate(x: CGFloat, y: CGFloat, direction: CGFloat, travel: CGFloat = 12) -> LegacyCellScorePlacement0264? {
            diagnostics.candidateChecks += 1
            let result = LegacyCellScorePlacement0264(center: CGPoint(x: x, y: y), size: size,
                verticalTravel: direction * travel, fontSize: fontSize)
            guard bounds.insetBy(dx: -0.0001, dy: -0.0001).contains(result.sweptFrame),
                  !obstacles.contains(where: { obstacle in
                      diagnostics.obstacleChecks += 1
                      return obstacle.insetBy(dx: -2, dy: -2).intersects(result.sweptFrame)
                  }) else { return nil }
            return result
        }
        let x = clampX(cellFrame.midX)
        var best: LegacyCellScorePlacement0264?
        var bestCost = CGFloat.infinity
        func consider(_ option: LegacyCellScorePlacement0264?) {
            guard let option else { return }
            let cost = option.proximityCost(to: cellFrame)
            if cost + 0.001 < bestCost { best = option; bestCost = cost }
        }
        for direction in [CGFloat(-1), CGFloat(1)] {
            let y = direction < 0 ? cellFrame.minY - 4 - size.height / 2 : cellFrame.maxY + 4 + size.height / 2
            let direct = candidate(x: x, y: y, direction: direction)
            // Aligned above/below is the shortest clear axis for this wide
            // label. Keep the normal-board fast path and its familiar motion.
            if let direct, abs(x - cellFrame.midX) < 0.001 { return direct }
            consider(direct)
        }
        // Tight late-game boards may have another animal above and below.
        // Search only obstacle edges and board limits, then choose the closest
        // clear position; at most 10 occupied cells bound this small search.
        // Search just beyond the required2pt exclusion. Using the normal4pt
        // aesthetic gap here can miss valid narrow slots between two animals.
        let searchGap: CGFloat = 2.25
        var horizontal = [x, bounds.minX + size.width / 2, bounds.maxX - size.width / 2]
        for obstacle in obstacles {
            horizontal.append(clampX(obstacle.minX - searchGap - size.width / 2))
            horizontal.append(clampX(obstacle.maxX + searchGap + size.width / 2))
        }
        let xs = Array(Set(horizontal)).sorted()
        for travel in [CGFloat(12), CGFloat(6), CGFloat(0)] {
            for direction in [CGFloat(-1), CGFloat(1)] {
                let upward: CGFloat = direction < 0 ? travel : 0
                let downward: CGFloat = direction > 0 ? travel : 0
                var vertical = [cellFrame.midY, bounds.minY + size.height / 2 + upward,
                                bounds.maxY - size.height / 2 - downward]
                for obstacle in obstacles {
                    vertical.append(obstacle.minY - searchGap - size.height / 2 - downward)
                    vertical.append(obstacle.maxY + searchGap + size.height / 2 + upward)
                }
                let ys = Array(Set(vertical)).sorted()
                for cx in xs { for cy in ys {
                    guard let option = candidate(x: cx, y: cy, direction: direction, travel: travel) else { continue }
                    consider(option)
                } }
            }
        }
        return best
    }
}
