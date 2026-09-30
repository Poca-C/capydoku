import XCTest
@testable import CapydokuCore

final class LevelResultPhaseTests: XCTestCase {
    private func puzzle(_ level: Int = 1) throws -> Puzzle {
        try PuzzleGenerator.generate(level: level)
    }

    private func lose(_ game: inout GameSession) throws {
        let wrong = try XCTUnwrap(game.puzzle.regions.indices.first { !game.puzzle.solution.contains($0) })
        while game.status == .playing { _ = game.submit(cell: wrong) }
        XCTAssertEqual(game.status, .lost)
    }

    private func win(_ game: inout GameSession) {
        for cell in game.puzzle.solution { _ = game.submit(cell: cell) }
        XCTAssertEqual(game.status, .won)
    }

    func testTwoLossesThenWinHaveDistinctStableResultsWithoutChangingBoardOrAttempt() throws {
        var game = GameSession(puzzle: try puzzle(), attempt: 4)
        let boardID = game.id
        let board = game.puzzle
        _ = game.submit(cell: board.solution[0])
        game.advanceTime(by: 12.5)
        var resultIDs: [String] = []
        for phase in 0..<2 {
            try lose(&game)
            let resultID = try XCTUnwrap(game.claimResult(.lose))
            resultIDs.append(resultID)
            XCTAssertEqual(resultID, boardID.uuidString + ":result:" + String(phase))
            XCTAssertNil(game.claimResult(.lose))
            let marks = game.marks
            let errors = game.errors
            let score = game.score
            XCTAssertTrue(game.revive())
            XCTAssertEqual(game.resultPhase, phase + 1)
            XCTAssertNil(game.resultPhaseEnd)
            XCTAssertEqual(game.id, boardID)
            XCTAssertEqual(game.puzzle, board)
            XCTAssertEqual(game.attempt, 4)
            XCTAssertEqual(game.elapsedSeconds, 12.5)
            XCTAssertEqual(game.marks, marks)
            XCTAssertEqual(game.errors, errors)
            XCTAssertEqual(game.found, [board.solution[0]])
            XCTAssertEqual(game.score, score)
            XCTAssertFalse(game.revive())
            XCTAssertEqual(game.resultPhase, phase + 1)
        }
        win(&game)
        resultIDs.append(try XCTUnwrap(game.claimResult(.win)))
        XCTAssertEqual(Set(resultIDs).count, 3)
        XCTAssertEqual(resultIDs.last, boardID.uuidString + ":result:2")
        XCTAssertNil(game.claimResult(.win))
        XCTAssertFalse(game.resumeAfterQuit())
        XCTAssertFalse(game.revive())
    }

    func testQuitContinueCanRepeatBeforeActualWinAndDoesNotResetProgress() throws {
        var game = GameSession(puzzle: try puzzle(), attempt: 3)
        _ = game.submit(cell: game.puzzle.solution[0])
        _ = game.toggleMark(at: 1)
        game.advanceTime(by: 31)
        let original = game
        XCTAssertFalse(game.resumeAfterQuit())
        for phase in 0..<2 {
            XCTAssertEqual(game.claimResult(.quit), original.id.uuidString + ":result:" + String(phase))
            XCTAssertNil(game.claimResult(.quit))
            XCTAssertFalse(game.revive())
            XCTAssertEqual(game.resultPhaseEnd, .quit)
            XCTAssertTrue(game.resumeAfterQuit())
            XCTAssertFalse(game.resumeAfterQuit(), "A foreground callback cannot reopen the same phase twice")
            XCTAssertEqual(game.resultPhase, phase + 1)
            XCTAssertEqual(game.id, original.id)
            XCTAssertEqual(game.attempt, original.attempt)
            XCTAssertEqual(game.elapsedSeconds, original.elapsedSeconds)
            XCTAssertEqual(game.found, original.found)
            XCTAssertEqual(game.marks, original.marks)
            XCTAssertEqual(game.lives, original.lives)
            XCTAssertEqual(game.score, original.score)
        }
        win(&game)
        XCTAssertEqual(game.claimResult(.win), original.id.uuidString + ":result:2")
        XCTAssertFalse(game.resumeAfterQuit())
    }

    func testOnlyResultMatchingActualStatusCanClaimOpenPhase() throws {
        var game = GameSession(puzzle: try puzzle())
        XCTAssertNil(game.claimResult(.win))
        XCTAssertNil(game.claimResult(.lose))
        XCTAssertNil(game.resultPhaseEnd)
        try lose(&game)
        XCTAssertNil(game.claimResult(.win))
        XCTAssertNil(game.claimResult(.quit))
        XCTAssertFalse(game.resumeAfterQuit())
        XCTAssertNotNil(game.claimResult(.lose))
        XCTAssertNil(game.claimResult(.quit))
        XCTAssertTrue(game.revive())
        win(&game)
        XCTAssertNil(game.claimResult(.lose))
        XCTAssertNil(game.claimResult(.quit))
        XCTAssertNotNil(game.claimResult(.win))
    }

    func testReviveWithoutClaimDoesNotInventEndedPhase() throws {
        var game = GameSession(puzzle: try puzzle())
        try lose(&game)
        XCTAssertTrue(game.revive())
        XCTAssertEqual(game.resultPhase, 0)
        XCTAssertNil(game.resultPhaseEnd)
        win(&game)
        XCTAssertEqual(game.claimResult(.win), game.id.uuidString + ":result:0")
    }

    func testRestartStartsIndependentBoardIdentityAndPhaseZero() throws {
        var game = GameSession(puzzle: try puzzle(), attempt: 7)
        XCTAssertNotNil(game.claimResult(.quit))
        XCTAssertTrue(game.resumeAfterQuit())
        try lose(&game)
        let previousResult = try XCTUnwrap(game.claimResult(.lose))
        let previousID = game.id
        game.restart()
        XCTAssertNotEqual(game.id, previousID)
        XCTAssertEqual(game.resultPhase, 0)
        XCTAssertNil(game.resultPhaseEnd)
        XCTAssertEqual(game.attempt, 8)
        XCTAssertNotEqual(game.claimResult(.quit), previousResult)
    }

    func testLegacyTerminalSavesAreClosedWithoutReplayingAnInventedResult() throws {
        let initial = GameSession(puzzle: try puzzle())
        for status: GameStatus in [.playing, .lost, .won] {
            var original = initial
            if status == .lost { try lose(&original) }
            if status == .won { win(&original) }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            object.removeValue(forKey: "resultPhase")
            object.removeValue(forKey: "resultPhaseEnd")
            let legacyData = try JSONSerialization.data(withJSONObject: object)
            var restored = try JSONDecoder().decode(GameSession.self, from: legacyData)
            XCTAssertEqual(restored.id, initial.id)
            XCTAssertEqual(restored.resultPhase, 0)
            switch status {
            case .playing:
                XCTAssertNil(restored.resultPhaseEnd)
                XCTAssertNotNil(restored.claimResult(.quit))
            case .lost:
                XCTAssertEqual(restored.resultPhaseEnd, .lose)
                XCTAssertNil(restored.claimResult(.lose))
                XCTAssertTrue(restored.revive())
                XCTAssertEqual(restored.resultPhase, 1)
                XCTAssertNil(restored.resultPhaseEnd)
            case .won:
                XCTAssertEqual(restored.resultPhaseEnd, .win)
                XCTAssertNil(restored.claimResult(.win))
                XCTAssertFalse(restored.resumeAfterQuit())
            }
        }
    }

    func testCurrentRoundTripPreservesOpenClosedAndUnclaimedTerminalPhases() throws {
        var game = GameSession(puzzle: try puzzle())
        var snapshots = [game]
        XCTAssertNotNil(game.claimResult(.quit))
        snapshots.append(game)
        XCTAssertTrue(game.resumeAfterQuit())
        snapshots.append(game)
        try lose(&game)
        snapshots.append(game)
        XCTAssertNotNil(game.claimResult(.lose))
        snapshots.append(game)
        XCTAssertTrue(game.revive())
        win(&game)
        snapshots.append(game)
        XCTAssertNotNil(game.claimResult(.win))
        snapshots.append(game)
        for snapshot in snapshots {
            let restored = try JSONDecoder().decode(GameSession.self, from: JSONEncoder().encode(snapshot))
            XCTAssertEqual(restored, snapshot)
        }
    }

    func testPendingResultBytesSurviveAtomicSaveCurrentBoardReplacementAndColdLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let firstBoard = try puzzle()
        let secondBoard = try puzzle(2)
        let store = SaveStore(directory: directory, packagedPuzzle: { $0 == 1 ? firstBoard : secondBoard })
        var progress = PlayerProgress()
        progress.begin(puzzle: firstBoard)
        let payload = Data("{\"event_time\":123456,\"result\":\"quit\"}".utf8)
        let eventID = UUID().uuidString
        try store.transaction(progress: &progress) { candidate in
            XCTAssertNotNil(candidate.session?.claimResult(.quit))
            candidate.pendingLevelResultEvents[eventID] = payload
        }
        XCTAssertEqual(store.load().progress, progress)
        XCTAssertEqual(store.load().progress.session?.resultPhaseEnd, .quit)
        progress.begin(puzzle: secondBoard)
        try store.save(progress)
        let coldStore = SaveStore(directory: directory, packagedPuzzle: { $0 == 1 ? firstBoard : secondBoard })
        let restored = coldStore.load()
        XCTAssertEqual(restored.source, .primary)
        XCTAssertEqual(restored.progress, progress)
        XCTAssertEqual(restored.progress.pendingLevelResultEvents, [eventID: payload])
        XCTAssertEqual(restored.progress.session?.puzzle, secondBoard)
        XCTAssertEqual(restored.progress.session?.resultPhase, 0)
        progress.session = nil
        try store.save(progress)
        XCTAssertEqual(coldStore.load().progress.pendingLevelResultEvents, [eventID: payload])
    }

    func testFailedAtomicCommitLeavesBothPhaseAndOutboxUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a directory".utf8).write(to: directory)
        let store = SaveStore(directory: directory)
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle())
        let before = progress
        XCTAssertThrowsError(try store.transaction(progress: &progress) { candidate in
            XCTAssertNotNil(candidate.session?.claimResult(.quit))
            candidate.pendingLevelResultEvents[UUID().uuidString] = Data("frozen result".utf8)
        }) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain,
                           "The valid transaction must reach the injected filesystem failure")
            XCTAssertFalse(error is SaveStoreError)
        }
        XCTAssertEqual(progress, before)
        XCTAssertNil(progress.session?.resultPhaseEnd)
        XCTAssertTrue(progress.pendingLevelResultEvents.isEmpty)
    }

    func testLegacyProgressWithoutPendingEventsDefaultsToEmpty() throws {
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as? [String: Any])
        object.removeValue(forKey: "pendingLevelResultEvents")
        let decoded = try JSONDecoder().decode(PlayerProgress.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, progress)
        XCTAssertTrue(decoded.pendingLevelResultEvents.isEmpty)
    }

    func testInvalidCountersAreRejectedAndBoundaryCannotOverflowOrProduceUnreadableSave() throws {
        var game = GameSession(puzzle: try puzzle())
        XCTAssertNotNil(game.claimResult(.quit))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(game)) as? [String: Any])
        for invalid in [-1, Int.max] {
            object["resultPhase"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(GameSession.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        object["resultPhase"] = Int.max - 1
        var boundaryQuit = try JSONDecoder().decode(GameSession.self, from: JSONSerialization.data(withJSONObject: object))
        let beforeQuit = boundaryQuit
        XCTAssertFalse(boundaryQuit.resumeAfterQuit())
        XCTAssertEqual(boundaryQuit, beforeQuit)

        game = GameSession(puzzle: game.puzzle)
        try lose(&game)
        XCTAssertNotNil(game.claimResult(.lose))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(game)) as? [String: Any])
        object["resultPhase"] = Int.max - 1
        var boundaryLoss = try JSONDecoder().decode(GameSession.self, from: JSONSerialization.data(withJSONObject: object))
        let beforeRevive = boundaryLoss
        XCTAssertFalse(boundaryLoss.revive())
        XCTAssertEqual(boundaryLoss, beforeRevive)
        XCTAssertEqual(try JSONDecoder().decode(GameSession.self, from: JSONEncoder().encode(boundaryLoss)), beforeRevive)
    }
}
