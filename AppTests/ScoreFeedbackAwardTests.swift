import XCTest
import CapydokuCore
@testable import Capydoku

private final class ScoreAwardRewards: RewardProvider {
    var requests: [(id: String, completion: (RewardSignal) -> Void)] = []
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) {
        requests.append((offerID, completion))
    }
}

final class ScoreFeedbackAwardTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("score-awards-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor private func fresh(direct: Int = 1, rewards: ScoreAwardRewards? = nil) -> AppModel {
        let model = AppModel(saveDirectory: directory(), rewardProvider: rewards,
                             runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true
        model.config = DemoConfig(hintsPerLevel: 2, directPerLevel: direct)
        model.start(level: 6)
        return model
    }

    @MainActor private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor private func assertAwards(_ model: AppModel, sessionID: UUID,
                                         expected: [(cell: Int, amount: Int)],
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.scoreFeedbackAwards.map(\.sessionID), Array(repeating: sessionID, count: expected.count), file: file, line: line)
        XCTAssertEqual(model.scoreFeedbackAwards.map(\.cell), expected.map(\.cell), file: file, line: line)
        XCTAssertEqual(model.scoreFeedbackAwards.map(\.amount), expected.map(\.amount), file: file, line: line)
    }

    @MainActor func testConsecutiveCorrectMovesKeepAcceptedOrderAndActualAmountsWithoutDuplicateReceipts() throws {
        let model = fresh(), initial = try XCTUnwrap(model.session)
        let solution = initial.puzzle.solution.sorted()
        // Deliberately differ from cell sorting, with no intervening run-loop
        // turn: a renderer may receive both commits in one update.
        let cells = [solution[2], solution[0]]
        var expected = [(cell: Int, amount: Int)]()
        for cell in cells {
            let before = try XCTUnwrap(model.session)
            model.submit(cell)
            let after = try XCTUnwrap(model.session)
            XCTAssertEqual(after.found.subtracting(before.found), [cell])
            XCTAssertEqual(after.lives, before.lives)
            expected.append((cell, after.score - before.score))
        }
        XCTAssertGreaterThan(expected[1].amount, expected[0].amount, "The fixture must distinguish the two Combo awards.")
        assertAwards(model, sessionID: initial.id, expected: expected)
        let accepted = try XCTUnwrap(model.session)
        XCTAssertEqual(expected.reduce(0) { $0 + $1.amount }, accepted.score - initial.score)
        model.submit(cells[1]) // Duplicate delivery of the latest submit.
        model.submit(cells[0]) // Already found, even though this is a different cell.
        XCTAssertEqual(model.session, accepted)
        assertAwards(model, sessionID: initial.id, expected: expected)
        let empty = try XCTUnwrap(initial.puzzle.regions.indices.first { !initial.puzzle.solution.contains($0) })
        model.toggle(empty); model.toggle(empty)
        XCTAssertEqual(model.session?.score, accepted.score)
        assertAwards(model, sessionID: initial.id, expected: expected)
    }

    @MainActor func testMistakeDropsEarlierAwardsAndFollowingCorrectUsesOnlyItsCommittedIncrease() throws {
        let model = fresh(), initial = try XCTUnwrap(model.session)
        for cell in initial.puzzle.solution.prefix(2) { model.submit(cell) }
        XCTAssertEqual(model.scoreFeedbackAwards.count, 2)
        let beforeMistake = try XCTUnwrap(model.session)
        let wrong = try XCTUnwrap(initial.puzzle.regions.indices.first { !initial.puzzle.solution.contains($0) })
        model.submit(wrong)
        let mistaken = try XCTUnwrap(model.session)
        XCTAssertEqual(mistaken.score, beforeMistake.score)
        XCTAssertEqual(mistaken.lives, beforeMistake.lives - 1)
        XCTAssertEqual(mistaken.combo, 0)
        XCTAssertTrue(model.scoreFeedbackAwards.isEmpty)
        let next = try XCTUnwrap(initial.puzzle.solution.first { !mistaken.found.contains($0) })
        model.submit(next)
        let corrected = try XCTUnwrap(model.session)
        XCTAssertEqual(corrected.score - mistaken.score, corrected.config.baseScore)
        assertAwards(model, sessionID: initial.id, expected: [(next, corrected.score - mistaken.score)])
        XCTAssertEqual(corrected.errors, mistaken.errors, "Only presentation yields to the next correct move.")
    }

    @MainActor func testCoverBackgroundAndHomeReturnConsumeAwardsWithoutBlockingTheNextRealAward() throws {
        for boundary in ["settings", "hint", "background", "home"] {
            let model = fresh(), initial = try XCTUnwrap(model.session)
            let first = initial.puzzle.solution[0], second = initial.puzzle.solution[1]
            model.submit(first)
            XCTAssertEqual(model.scoreFeedbackAwards.count, 1, boundary)
            switch boundary {
            case "settings": model.sheet = .settings
            case "hint": model.showHint(); XCTAssertNotNil(model.hint)
            case "background": model.setActive(false)
            default: model.home()
            }
            XCTAssertTrue(model.scoreFeedbackAwards.isEmpty, boundary)
            let covered = model.session
            model.submit(second)
            XCTAssertEqual(model.session, covered, "A covered submit must not fabricate an award: \(boundary).")
            switch boundary {
            case "settings": model.sheet = nil
            case "hint": XCTAssertTrue(model.closeHint())
            case "background": model.setActive(true)
            default: model.startOrContinue()
            }
            XCTAssertTrue(model.scoreFeedbackAwards.isEmpty, "Returning must not replay the first cell: \(boundary).")
            let before = try XCTUnwrap(model.session)
            XCTAssertEqual(before.id, initial.id)
            model.submit(second)
            let after = try XCTUnwrap(model.session)
            XCTAssertEqual(after.found.subtracting(before.found), [second])
            assertAwards(model, sessionID: after.id, expected: [(second, after.score - before.score)])
        }
    }

    @MainActor func testNewSessionReloadAndColdRestoreNeverRecreatePreviousScoreAwards() throws {
        let model = fresh(), first = try XCTUnwrap(model.session)
        model.submit(first.puzzle.solution[0])
        XCTAssertEqual(model.scoreFeedbackAwards.count, 1)
        model.start(level: 7)
        let next = try XCTUnwrap(model.session)
        XCTAssertNotEqual(next.id, first.id)
        XCTAssertTrue(model.scoreFeedbackAwards.isEmpty)
        let cell = next.puzzle.solution[0]
        model.submit(cell)
        let committed = try XCTUnwrap(model.session)
        assertAwards(model, sessionID: next.id, expected: [(cell, committed.score - next.score)])
        model.flushPendingSaves()

        let restored = AppModel(saveDirectory: model.saveDirectory, runsTimer: false, feedbackEnabled: false)
        XCTAssertEqual(restored.session?.id, committed.id)
        XCTAssertEqual(restored.session?.found, committed.found)
        XCTAssertEqual(restored.session?.score, committed.score)
        XCTAssertTrue(restored.scoreFeedbackAwards.isEmpty)
        restored.startOrContinue()
        XCTAssertTrue(restored.scoreFeedbackAwards.isEmpty)
        model.loadProgress()
        XCTAssertTrue(model.scoreFeedbackAwards.isEmpty)
        XCTAssertEqual(model.session?.score, committed.score)

        let followUp = try XCTUnwrap(committed.puzzle.solution.first { !committed.found.contains($0) })
        restored.submit(followUp)
        let accepted = try XCTUnwrap(restored.session)
        assertAwards(restored, sessionID: committed.id, expected: [(followUp, accepted.score - committed.score)])
    }

    @MainActor func testInventoryDirectRecordsActualRandomCellAndAmountIncludingFinalMoveOnlyOnce() throws {
        for finalMove in [false, true] {
            let model = fresh(), initial = try XCTUnwrap(model.session)
            for cell in initial.puzzle.solution.prefix(finalMove ? initial.puzzle.size - 1 : 1) { model.submit(cell) }
            let before = try XCTUnwrap(model.session), inventory = model.progress.availableDirect
            let earlier = model.scoreFeedbackAwards.map { (cell: $0.cell, amount: $0.amount) }
            model.direct()
            let after = try XCTUnwrap(model.session)
            let added = after.found.subtracting(before.found)
            XCTAssertEqual(added.count, 1)
            let cell = try XCTUnwrap(added.first)
            XCTAssertEqual(after.lives, before.lives)
            XCTAssertEqual(after.errors, before.errors)
            XCTAssertEqual(after.marks, before.marks.subtracting([cell]))
            XCTAssertEqual(after.status, finalMove ? .won : .playing)
            XCTAssertEqual(model.progress.availableDirect, inventory - 1)
            let expected = earlier + [(cell: cell, amount: after.score - before.score)]
            assertAwards(model, sessionID: after.id, expected: expected)
            model.direct()
            XCTAssertEqual(model.session, after)
            assertAwards(model, sessionID: after.id, expected: expected)
        }
    }

    @MainActor func testRewardedDirectRecordsOnlyItsActualAwardAndDuplicateCannotReplayIncludingWin() async throws {
        for finalMove in [false, true] {
            let rewards = ScoreAwardRewards(), model = fresh(direct: 0, rewards: rewards)
            let initial = try XCTUnwrap(model.session)
            for cell in initial.puzzle.solution.prefix(finalMove ? initial.puzzle.size - 1 : 1) { model.submit(cell) }
            let before = try XCTUnwrap(model.session)
            XCTAssertFalse(model.scoreFeedbackAwards.isEmpty)
            model.direct()
            let request = try XCTUnwrap(rewards.requests.last)
            XCTAssertEqual(rewards.requests.count, 1)
            XCTAssertTrue(model.rewardBusy)
            XCTAssertTrue(model.scoreFeedbackAwards.isEmpty, "Opening the reward consumes previous board feedback.")
            request.completion(.started)
            await drainCallbacks()
            XCTAssertEqual(model.session, before)
            XCTAssertTrue(model.scoreFeedbackAwards.isEmpty)
            request.completion(.earned); request.completion(.earned)
            await drainCallbacks()
            let after = try XCTUnwrap(model.session), added = after.found.subtracting(before.found)
            XCTAssertEqual(added.count, 1)
            let cell = try XCTUnwrap(added.first)
            XCTAssertEqual(after.lives, before.lives)
            XCTAssertEqual(after.errors, before.errors)
            XCTAssertEqual(after.marks, before.marks.subtracting([cell]))
            XCTAssertEqual(after.status, finalMove ? .won : .playing)
            XCTAssertEqual(model.progress.availableDirect, 0)
            XCTAssertEqual(model.progress.rewardLedger[request.id]?.state, .executed)
            XCTAssertFalse(model.rewardBusy); XCTAssertNil(model.sheet)
            let expected = [(cell: cell, amount: after.score - before.score)]
            assertAwards(model, sessionID: after.id, expected: expected)
            let accepted = model.progress
            request.completion(.earned)
            await drainCallbacks()
            XCTAssertEqual(model.progress, accepted)
            assertAwards(model, sessionID: after.id, expected: expected)
            model.setActive(false); model.setActive(true)
            request.completion(.earned)
            await drainCallbacks()
            XCTAssertTrue(model.scoreFeedbackAwards.isEmpty, "Late duplicates cannot resurrect an already consumed reward.")
            XCTAssertEqual(model.session, after)
        }
    }

    @MainActor func testRewardEarnedInBackgroundCommitsScoreWithoutDeferringAnAwardUntilResume() async throws {
        let rewards = ScoreAwardRewards(), model = fresh(direct: 0, rewards: rewards)
        let before = try XCTUnwrap(model.session)
        model.direct()
        let request = try XCTUnwrap(rewards.requests.last)
        model.setActive(false)
        request.completion(.earned)
        await drainCallbacks()
        let committed = try XCTUnwrap(model.session)
        XCTAssertEqual(committed.found.count, before.found.count + 1)
        XCTAssertGreaterThan(committed.score, before.score)
        XCTAssertEqual(model.progress.rewardLedger[request.id]?.state, .executed)
        XCTAssertTrue(model.scoreFeedbackAwards.isEmpty)
        model.setActive(true)
        request.completion(.earned)
        await drainCallbacks()
        XCTAssertEqual(model.session, committed)
        XCTAssertTrue(model.scoreFeedbackAwards.isEmpty)
        let next = try XCTUnwrap(committed.puzzle.solution.first { !committed.found.contains($0) })
        model.submit(next)
        let after = try XCTUnwrap(model.session)
        assertAwards(model, sessionID: committed.id, expected: [(next, after.score - committed.score)])
    }
}
