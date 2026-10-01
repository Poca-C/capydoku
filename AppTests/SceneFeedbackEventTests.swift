import XCTest
import CapydokuCore
@testable import Capydoku

private final class SceneFeedbackRewards: RewardProvider {
    var requests: [(id: String, completion: (RewardSignal) -> Void)] = []
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) {
        requests.append((offerID, completion))
    }
}

final class SceneFeedbackEventTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scene-feedback-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor private func fresh(direct: Int = 2, rewards: SceneFeedbackRewards? = nil) -> AppModel {
        let model = AppModel(saveDirectory: directory(), rewardProvider: rewards, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true
        model.config = DemoConfig(hintsPerLevel: 2, directPerLevel: direct)
        model.start(level: 1)
        return model
    }

    @MainActor private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor func testDeferredApplauseCannotCrossMistakeCoverReturnOrReplacement() async throws {
        for boundary in ["mistake", "settings-round-trip", "background-round-trip", "replacement"] {
            let model = fresh(), reward = GameRewardPresentation()
            let first = try XCTUnwrap(model.session).puzzle.solution[0]
            model.submit(first)
            let accepted = try XCTUnwrap(model.session), epoch = model.sceneFeedbackEpoch
            reward.bind(sessionID: accepted.id, score: accepted.score)
            XCTAssertTrue(model.canPresentPositiveFeedback(from: accepted, epoch: epoch))
            // The same snapshot/epoch guard used by Root's queued callback.
            DispatchQueue.main.async {
                guard model.canPresentPositiveFeedback(from: accepted, epoch: epoch) else { return }
                reward.found(index: first, sessionID: accepted.id, origin: .zero, destination: .zero, reduceMotion: false)
                reward.scoreAward(accepted.score, sessionID: accepted.id, origin: .zero, reduceMotion: false)
            }
            switch boundary {
            case "mistake":
                let wrong = try XCTUnwrap((0..<(accepted.puzzle.size * accepted.puzzle.size)).first { !accepted.puzzle.solution.contains($0) })
                model.submit(wrong)
                XCTAssertEqual(model.session?.lives, accepted.lives - 1)
                XCTAssertEqual(model.session?.found, accepted.found)
                XCTAssertEqual(model.session?.score, accepted.score)
                let combined = try XCTUnwrap(model.session)
                XCTAssertFalse(model.canPresentPositiveFeedback(from: combined, epoch: model.sceneFeedbackEpoch),
                               "Correct + incorrect in one render has matching lives, but must not applaud.")
            case "settings-round-trip": model.sheet = .settings; model.sheet = nil
            case "background-round-trip": model.setActive(false); model.setActive(true)
            default: model.start(level: 2)
            }
            let committed = model.session
            await drainCallbacks()
            XCTAssertNil(reward.applauseID, boundary)
            XCTAssertTrue(reward.flights.isEmpty, boundary); XCTAssertTrue(reward.localScores.isEmpty, boundary)
            XCTAssertEqual(model.session, committed, "Dropping decoration cannot change a committed move.")
            let continued = try XCTUnwrap(model.session)
            let next = try XCTUnwrap(continued.puzzle.solution.first { !continued.found.contains($0) })
            model.submit(next)
            let freshResult = try XCTUnwrap(model.session)
            XCTAssertTrue(model.canPresentPositiveFeedback(from: freshResult, epoch: model.sceneFeedbackEpoch),
                          "A later real success remains eligible after \(boundary).")
        }
    }

    @MainActor func testFinalFoundApplauseSurvivesWinButColdRestoreIsNotTheSamePresentation() throws {
        let model = fresh()
        for cell in try XCTUnwrap(model.session).puzzle.solution { model.submit(cell) }
        let won = try XCTUnwrap(model.session), epoch = model.sceneFeedbackEpoch
        XCTAssertEqual(won.status, .won)
        XCTAssertTrue(model.canPresentPositiveFeedback(from: won, epoch: epoch))
        model.home(); model.startOrContinue()
        XCTAssertEqual(model.session?.id, won.id)
        XCTAssertFalse(model.canPresentPositiveFeedback(from: won, epoch: epoch))
    }

    private func blockPrimary(_ modelDirectory: URL) throws -> Data {
        let primary = modelDirectory.appendingPathComponent("progress.json")
        let bytes = try Data(contentsOf: primary)
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        return bytes
    }

    private func restorePrimary(_ modelDirectory: URL, bytes: Data) throws {
        let primary = modelDirectory.appendingPathComponent("progress.json")
        try FileManager.default.removeItem(at: primary)
        try bytes.write(to: primary, options: .atomic)
    }

    @MainActor func testFreshPackagedBoardPublishesEntranceForItsActualSession() throws {
        let model = fresh()
        let first = try XCTUnwrap(model.session)
        XCTAssertEqual(model.boardEntranceID, first.id)
        XCTAssertNil(model.directRevealFeedback)
        XCTAssertTrue(first.found.isEmpty)
        model.start(level: 2)
        let next = try XCTUnwrap(model.session)
        XCTAssertNotEqual(next.id, first.id)
        XCTAssertEqual(next.puzzle.id, 2)
        XCTAssertEqual(model.boardEntranceID, next.id)
        XCTAssertNil(model.directRevealFeedback)
    }

    @MainActor func testHomeContinueLoadAndColdRestoreDoNotReplayEntranceOrToolConfirmation() throws {
        let model = fresh()
        model.direct()
        XCTAssertNotNil(model.directRevealFeedback)
        let played = try XCTUnwrap(model.session)
        let inventory = model.progress.availableDirect
        model.home()
        XCTAssertNil(model.boardEntranceID)
        XCTAssertNil(model.directRevealFeedback)
        model.startOrContinue()
        XCTAssertEqual(model.session?.id, played.id)
        XCTAssertEqual(model.session?.found, played.found)
        XCTAssertEqual(model.progress.availableDirect, inventory)
        XCTAssertNil(model.boardEntranceID)
        XCTAssertNil(model.directRevealFeedback)
        model.loadProgress()
        XCTAssertNil(model.boardEntranceID)
        XCTAssertNil(model.directRevealFeedback)

        let restored = AppModel(saveDirectory: model.saveDirectory, runsTimer: false, feedbackEnabled: false)
        XCTAssertEqual(restored.session?.id, played.id)
        XCTAssertEqual(restored.session?.puzzle, played.puzzle)
        XCTAssertEqual(restored.session?.found, played.found)
        XCTAssertEqual(restored.progress.availableDirect, inventory)
        XCTAssertNil(restored.boardEntranceID)
        XCTAssertNil(restored.directRevealFeedback)
        restored.startOrContinue()
        XCTAssertNil(restored.boardEntranceID)
        XCTAssertNil(restored.directRevealFeedback)
    }

    @MainActor func testRestartCreatesNewAttemptEntranceAndDiscardsOldDirectConfirmation() throws {
        let model = fresh()
        model.direct()
        let first = try XCTUnwrap(model.session)
        XCTAssertNotNil(model.directRevealFeedback)
        model.restart()
        let restarted = try XCTUnwrap(model.session)
        XCTAssertEqual(restarted.puzzle, first.puzzle)
        XCTAssertNotEqual(restarted.id, first.id)
        XCTAssertEqual(restarted.attempt, first.attempt + 1)
        XCTAssertTrue(restarted.found.isEmpty)
        XCTAssertEqual(model.boardEntranceID, restarted.id)
        XCTAssertNil(model.directRevealFeedback)
        model.restart() // A duplicate delivery cannot create another attempt or entrance.
        XCTAssertEqual(model.session?.id, restarted.id)
        XCTAssertEqual(model.boardEntranceID, restarted.id)
    }

    @MainActor func testBackgroundDiscardsExistingEffectsAndHiddenNewBoardDoesNotReplayOnResume() throws {
        let model = fresh()
        model.direct()
        XCTAssertNotNil(model.directRevealFeedback)
        model.setActive(false)
        XCTAssertNil(model.boardEntranceID)
        XCTAssertNil(model.directRevealFeedback)
        model.start(level: 2)
        let hiddenBoard = try XCTUnwrap(model.session)
        XCTAssertEqual(hiddenBoard.puzzle.id, 2)
        XCTAssertNil(model.boardEntranceID)
        model.setActive(true)
        XCTAssertEqual(model.session?.id, hiddenBoard.id)
        XCTAssertNil(model.boardEntranceID)
        XCTAssertNil(model.directRevealFeedback)
        model.start(level: 3)
        XCTAssertEqual(model.boardEntranceID, model.session?.id)
        XCTAssertNotEqual(model.session?.id, hiddenBoard.id)
    }

    @MainActor func testBlockingOverlaysInvalidateEffectsAndClosingDoesNotReplayThem() throws {
        for blocker in ["settings", "loading", "notice", "error", "challenge", "hint"] {
            let model = fresh()
            model.direct()
            XCTAssertNotNil(model.boardEntranceID, blocker)
            XCTAssertNotNil(model.directRevealFeedback, blocker)
            switch blocker {
            case "settings": model.sheet = .settings
            case "loading": model.loading = true
            case "notice": model.notice = "test notice"
            case "error": model.errorMessage = "test error"
            case "challenge": model.challengePending = true
            default:
                model.showHint()
                XCTAssertNotNil(model.hint)
            }
            XCTAssertNil(model.boardEntranceID, blocker)
            XCTAssertNil(model.directRevealFeedback, blocker)
            let covered = model.progress
            model.direct()
            XCTAssertEqual(model.progress, covered, "\(blocker) must not accept a late tool action.")
            XCTAssertNil(model.directRevealFeedback, blocker)
            switch blocker {
            case "settings": model.sheet = nil
            case "loading": model.loading = false
            case "notice": model.notice = nil
            case "error": model.errorMessage = nil
            case "challenge": model.challengePending = false
            default: XCTAssertTrue(model.closeHint())
            }
            XCTAssertNil(model.boardEntranceID, blocker)
            XCTAssertNil(model.directRevealFeedback, blocker)
        }
    }

    @MainActor func testDirectConfirmationUsesActualRevealedCellIncludingWinningMove() throws {
        for winningMove in [false, true] {
            let model = fresh()
            if winningMove {
                for cell in try XCTUnwrap(model.session).puzzle.solution.dropLast() { model.submit(cell) }
            }
            let before = try XCTUnwrap(model.session), inventory = model.progress.availableDirect
            model.direct()
            let after = try XCTUnwrap(model.session), event = try XCTUnwrap(model.directRevealFeedback)
            XCTAssertEqual(after.found.subtracting(before.found), [event.cell])
            XCTAssertEqual(event.sessionID, after.id)
            XCTAssertTrue(after.puzzle.solution.contains(event.cell))
            XCTAssertEqual(after.lives, before.lives)
            XCTAssertGreaterThan(after.score, before.score)
            XCTAssertEqual(model.progress.availableDirect, inventory - 1)
            XCTAssertEqual(after.status, winningMove ? .won : .playing)
            model.direct()
            XCTAssertEqual(model.session, after)
            XCTAssertEqual(model.directRevealFeedback, event, "Duplicate/locked tool actions must not emit a new confirmation.")
        }
    }

    @MainActor func testFailedDirectWritePublishesNoConfirmationAndSuccessfulRetryUsesCommittedCell() throws {
        let model = fresh()
        model.flushPendingSaves()
        let before = model.progress, bytes = try blockPrimary(model.saveDirectory)
        model.direct()
        XCTAssertEqual(model.progress, before)
        XCTAssertNil(model.directRevealFeedback)
        XCTAssertNotNil(model.errorMessage)
        try restorePrimary(model.saveDirectory, bytes: bytes)
        model.errorMessage = nil
        model.direct()
        let event = try XCTUnwrap(model.directRevealFeedback)
        XCTAssertEqual(model.session?.found, [event.cell])
        XCTAssertEqual(model.progress.availableDirect, before.availableDirect - 1)
        let restored = AppModel(saveDirectory: model.saveDirectory, runsTimer: false, feedbackEnabled: false)
        XCTAssertEqual(restored.session?.found, [event.cell])
        XCTAssertNil(restored.directRevealFeedback)
    }

    @MainActor func testRewardedDirectSuccessPublishesOneConfirmationAndDuplicateCallbackCannotReplay() async throws {
        let rewards = SceneFeedbackRewards(), model = fresh(direct: 0, rewards: rewards)
        model.direct()
        let request = try XCTUnwrap(rewards.requests.last)
        XCTAssertNil(model.directRevealFeedback)
        XCTAssertNil(model.boardEntranceID, "The reward sheet invalidates the prior entrance.")
        request.completion(.earned)
        request.completion(.earned)
        await drainCallbacks()
        XCTAssertFalse(model.rewardBusy)
        let event = try XCTUnwrap(model.directRevealFeedback), committed = try XCTUnwrap(model.session)
        XCTAssertEqual(committed.found, [event.cell])
        XCTAssertEqual(event.sessionID, committed.id)
        XCTAssertEqual(model.progress.rewardLedger[request.id]?.state, .executed)
        request.completion(.earned)
        await drainCallbacks()
        XCTAssertEqual(model.session, committed)
        XCTAssertEqual(model.directRevealFeedback, event)
        model.home(); model.startOrContinue()
        request.completion(.earned)
        await drainCallbacks()
        XCTAssertNil(model.directRevealFeedback)
        XCTAssertNil(model.boardEntranceID)
        XCTAssertEqual(model.session?.found, committed.found)
    }

    @MainActor func testCancelledFailedOrTimedOutRewardDoesNotPublishToolConfirmation() async throws {
        for signal: RewardSignal in [.cancelled, .failed, .timedOut] {
            let rewards = SceneFeedbackRewards(), model = fresh(direct: 0, rewards: rewards)
            let before = try XCTUnwrap(model.session)
            model.direct()
            let request = try XCTUnwrap(rewards.requests.last)
            request.completion(signal)
            await drainCallbacks()
            XCTAssertEqual(model.session, before)
            XCTAssertEqual(model.progress.availableDirect, 0)
            XCTAssertNil(model.directRevealFeedback)
            XCTAssertNil(model.boardEntranceID)
            model.notice = nil
            request.completion(.earned) // A late success cannot turn an already ended offer into a reveal.
            await drainCallbacks()
            XCTAssertEqual(model.session, before)
            XCTAssertNil(model.directRevealFeedback)
        }
    }

    @MainActor func testRewardedLastCellConfirmsTheActualRevealAfterWinIsCommitted() async throws {
        let rewards = SceneFeedbackRewards(), model = fresh(direct: 0, rewards: rewards)
        let solution = try XCTUnwrap(model.session).puzzle.solution
        for cell in solution.dropLast() { model.submit(cell) }
        let before = try XCTUnwrap(model.session)
        model.direct()
        let request = try XCTUnwrap(rewards.requests.last)
        request.completion(.earned)
        await drainCallbacks()
        let event = try XCTUnwrap(model.directRevealFeedback), won = try XCTUnwrap(model.session)
        XCTAssertEqual(won.status, .won)
        XCTAssertEqual(won.found.subtracting(before.found), [event.cell])
        XCTAssertEqual(event.cell, solution.last)
        XCTAssertEqual(event.sessionID, won.id)
        XCTAssertEqual(won.lives, before.lives)
        XCTAssertEqual(model.progress.rewardLedger[request.id]?.state, .executed)
    }

    @MainActor func testRewardEarnedInBackgroundCommitsWithoutReplayingConfirmationOnResume() async throws {
        let rewards = SceneFeedbackRewards(), model = fresh(direct: 0, rewards: rewards)
        model.direct()
        let request = try XCTUnwrap(rewards.requests.last)
        model.setActive(false)
        request.completion(.earned)
        await drainCallbacks()
        let committed = try XCTUnwrap(model.session)
        XCTAssertEqual(committed.found.count, 1)
        XCTAssertEqual(model.progress.rewardLedger[request.id]?.state, .executed)
        XCTAssertNil(model.directRevealFeedback)
        XCTAssertNil(model.boardEntranceID)
        model.setActive(true)
        request.completion(.earned)
        await drainCallbacks()
        XCTAssertEqual(model.session, committed)
        XCTAssertNil(model.directRevealFeedback)
        XCTAssertNil(model.boardEntranceID)
    }

    @MainActor func testInterruptedReceiptColdCompensationDoesNotInventARevealOrEntrance() async throws {
        let rewards = SceneFeedbackRewards(), model = fresh(direct: 0, rewards: rewards)
        let before = try XCTUnwrap(model.session)
        model.direct()
        let request = try XCTUnwrap(rewards.requests.last)
        request.completion(.interrupted)
        await drainCallbacks()
        XCTAssertEqual(model.session, before)
        XCTAssertNil(model.directRevealFeedback)
        let restored = AppModel(saveDirectory: model.saveDirectory, runsTimer: false, feedbackEnabled: false)
        XCTAssertEqual(restored.session, before)
        XCTAssertEqual(restored.progress.availableDirect, 1)
        XCTAssertNil(restored.boardEntranceID)
        XCTAssertNil(restored.directRevealFeedback)
        restored.startOrContinue()
        XCTAssertNil(restored.boardEntranceID)
        XCTAssertNil(restored.directRevealFeedback)
    }

    @MainActor func testRewardWriteFailureWithholdsConfirmationUntilExplicitSuccessfulRetry() async throws {
        let rewards = SceneFeedbackRewards(), model = fresh(direct: 0, rewards: rewards)
        model.direct()
        let request = try XCTUnwrap(rewards.requests.last), before = try XCTUnwrap(model.session)
        let bytes = try blockPrimary(model.saveDirectory)
        request.completion(.earned)
        await drainCallbacks()
        XCTAssertTrue(model.rewardRetryPending)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.session, before)
        XCTAssertNil(model.directRevealFeedback)
        try restorePrimary(model.saveDirectory, bytes: bytes)
        model.runReward()
        XCTAssertFalse(model.rewardRetryPending)
        let event = try XCTUnwrap(model.directRevealFeedback)
        XCTAssertEqual(model.session?.found, [event.cell])
        XCTAssertEqual(model.progress.rewardLedger[request.id]?.state, .executed)
        request.completion(.earned)
        await drainCallbacks()
        XCTAssertEqual(model.directRevealFeedback, event)
        XCTAssertEqual(model.session?.found, [event.cell])
    }
}
