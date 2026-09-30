import XCTest
@testable import CapydokuCore

final class GameSessionTests: XCTestCase {
    private func puzzle(_ level: Int = 1) throws -> Puzzle {
        try PuzzleGenerator.generate(level: level)
    }

    func testMarksNeverJudgeAndCorrectSubmissionNeverAutoMarks() throws {
        let puzzle = try puzzle()
        var game = GameSession(puzzle: puzzle)
        let answer = puzzle.solution[0]
        XCTAssertTrue(game.toggleMark(at: answer))
        XCTAssertEqual(game.lives, 3)
        XCTAssertTrue(game.toggleMark(at: answer))
        XCTAssertTrue(game.marks.isEmpty)
        _ = game.toggleMark(at: answer)
        XCTAssertEqual(game.submit(cell: answer), .correct(cell: answer, points: 100, won: false))
        XCTAssertEqual(game.found, [answer])
        XCTAssertTrue(game.marks.isEmpty)
        XCTAssertEqual(game.submit(cell: answer), .ignored)
        XCTAssertEqual(game.score, 100)
    }

    func testWrongSubmissionCostsOneLifeAndCannotBeDoubleCharged() throws {
        let puzzle = try puzzle()
        var game = GameSession(puzzle: puzzle)
        let wrong = (0..<16).first { !puzzle.solution.contains($0) }!
        XCTAssertEqual(game.submit(cell: wrong), .incorrect(cell: wrong, livesRemaining: 2))
        XCTAssertEqual(game.submit(cell: wrong), .ignored)
        XCTAssertEqual(game.lives, 2)
        XCTAssertEqual(game.errors, [wrong])
        XCTAssertFalse(game.toggleMark(at: wrong), "Confirmed red errors are protected; only player Xs can be undone")
        XCTAssertEqual(game.errors, [wrong])
        XCTAssertTrue(game.marks.contains(wrong))
        XCTAssertEqual(game.submit(cell: wrong), .ignored)
        XCTAssertEqual(game.submit(cell: -1), .ignored)
        XCTAssertEqual(game.submit(cell: 99), .ignored)
    }

    func testSwipeAddsOnlyAndSkipsFoundAnimals() throws {
        let puzzle = try puzzle()
        var game = GameSession(puzzle: puzzle)
        _ = game.submit(cell: puzzle.solution[0])
        XCTAssertEqual(game.markMany(Array(0..<4)), 3)
        XCTAssertEqual(game.markMany(Array(0..<4)), 0)
        XCTAssertFalse(game.marks.contains(puzzle.solution[0]))
        XCTAssertEqual(game.lives, 3)
    }

    func testWinningFreezesBoardAndTools() throws {
        let puzzle = try puzzle()
        var game = GameSession(puzzle: puzzle)
        for cell in puzzle.regions.indices.filter({ !puzzle.isSolutionCell($0) }).prefix(2) {
            _ = game.submit(cell: cell)
        }
        XCTAssertEqual(game.lives, 1, "The final remaining heart must still permit a win")
        for cell in puzzle.solution { _ = game.submit(cell: cell) }
        XCTAssertEqual(game.status, .won)
        XCTAssertEqual(game.score, 520)
        XCTAssertEqual(game.comboText, "Excellent")
        let frozen = game
        XCTAssertFalse(game.toggleMark(at: 0))
        XCTAssertEqual(game.markMany([0, 1, 2]), 0)
        XCTAssertEqual(game.submit(cell: 0), .ignored)
        XCTAssertNil(game.directFind())
        XCTAssertFalse(game.consumeHint())
        game.advanceTime(by: 5)
        XCTAssertEqual(game, frozen)
    }

    func testLoseReviveTwicePreservesMarksAndErrors() throws {
        let puzzle = try puzzle()
        var game = GameSession(puzzle: puzzle)
        _ = game.submit(cell: puzzle.solution[0])
        let wrong = (0..<16).filter { !puzzle.solution.contains($0) }
        for cell in wrong.prefix(3) { _ = game.submit(cell: cell) }
        XCTAssertEqual(game.status, .lost)
        XCTAssertEqual(game.lives, 0)
        let marks = game.marks
        XCTAssertTrue(game.revive())
        XCTAssertEqual(game.lives, 3)
        XCTAssertEqual(game.marks, marks)
        XCTAssertEqual(game.found, [puzzle.solution[0]])
        XCTAssertFalse(game.revive(), "Calling twice while alive is a no-op")
        for cell in wrong.dropFirst(3).prefix(3) { _ = game.submit(cell: cell) }
        XCTAssertTrue(game.revive())
        XCTAssertEqual(game.errors.count, 6)
        XCTAssertEqual(game.lives, 3)
    }

    func testRestartSameBoardKeepsToolBalanceAndSnapshotsConfig() throws {
        let puzzle = try puzzle()
        var config = DemoConfig.default
        var game = GameSession(puzzle: puzzle, config: config)
        let oldID = game.id
        _ = game.directFind()
        XCTAssertTrue(game.consumeHint())
        game.advanceTime(by: 15)
        config.initialLives = 9
        game.restart()
        XCTAssertEqual(game.puzzle, puzzle)
        XCTAssertNotEqual(game.id, oldID)
        XCTAssertEqual(game.attempt, 2)
        XCTAssertEqual(game.lives, 3)
        XCTAssertEqual(game.directRemaining, 0)
        XCTAssertEqual(game.hintsRemaining, 0)
        XCTAssertEqual(game.elapsedSeconds, 0)
    }

    func testHintConsumeDoesNotAlterBoardAndOnlyApplyMarks() throws {
        let puzzle = try puzzle()
        var game = GameSession(puzzle: puzzle)
        XCTAssertTrue(game.consumeHint())
        XCTAssertTrue(game.marks.isEmpty)
        XCTAssertFalse(game.consumeHint())
        let exclusions = (0..<16).filter { !puzzle.solution.contains($0) }
        XCTAssertEqual(game.markMany(exclusions), exclusions.count)
        XCTAssertTrue(game.found.isEmpty)
        XCTAssertEqual(game.lives, 3)
    }

    func testNoUsefulHintDoesNotConsumeFreeOrBonusInventory() throws {
        let puzzle = try puzzle()
        var progress = PlayerProgress()
        progress.begin(puzzle: puzzle)
        progress.bonusHints = 3
        _ = progress.session?.markMany((0..<16).filter { !puzzle.solution.contains($0) })
        XCTAssertFalse(progress.session?.hasUnmarkedExclusions == true)
        XCTAssertFalse(progress.consumeHint())
        XCTAssertEqual(progress.availableHints, 4)
        XCTAssertFalse(progress.canReceiveReward(.hint))
    }

    func testConfigurationCeilingMatchesGenerator() {
        let config = DemoConfig(generatorBudgetMilliseconds: 60_000, generatorCandidateLimit: 1_000)
        XCTAssertEqual(config.maximumBoardSize, PuzzleGenerator.maximumBoardSize)
        XCTAssertEqual(config.generatorBudgetMilliseconds, 8_000)
        XCTAssertEqual(config.generatorCandidateLimit, 500)
    }

    func testToolGrantsCannotBeFarmedByReplayAndBonusUsedAfterFree() throws {
        let first = try puzzle()
        let second = try puzzle(2)
        var progress = PlayerProgress()
        progress.bonusHints = 2
        progress.bonusDirect = 2
        progress.begin(puzzle: first)
        XCTAssertTrue(progress.consumeHint())
        XCTAssertEqual(progress.bonusHints, 2)
        XCTAssertNotNil(progress.directFind())
        XCTAssertEqual(progress.bonusDirect, 2)
        XCTAssertTrue(progress.consumeHint())
        XCTAssertEqual(progress.bonusHints, 1)
        progress.begin(puzzle: second)
        progress.begin(puzzle: first)
        XCTAssertEqual(progress.session?.hintsRemaining, 0)
        XCTAssertEqual(progress.session?.directRemaining, 0)
        XCTAssertEqual(progress.session?.attempt, 2)
        progress.restart()
        XCTAssertEqual(progress.session?.attempt, 3)
        XCTAssertEqual(progress.session?.directRemaining, 0)
    }

    func testWinProgressionIdempotent() throws {
        let puzzle = try puzzle()
        var progress = PlayerProgress()
        progress.begin(puzzle: puzzle)
        XCTAssertFalse(progress.finishWin())
        for cell in puzzle.solution { _ = progress.session?.submit(cell: cell) }
        XCTAssertTrue(progress.finishWin())
        XCTAssertTrue(progress.finishWin())
        XCTAssertEqual(progress.unlockedLevel, 2)
        XCTAssertEqual(progress.completedLevels, [1])
    }

    func testCheckInUTCDateBoundaryAndRollback() {
        var progress = PlayerProgress()
        let midnight = Date(timeIntervalSince1970: 2_000 * 86_400)
        XCTAssertEqual(progress.claimCheckIn(on: midnight.addingTimeInterval(-1)),
                       .claimed(streak: 1, cycleDay: 1, hints: 1, direct: 0))
        XCTAssertEqual(progress.claimCheckIn(on: midnight),
                       .claimed(streak: 2, cycleDay: 2, hints: 1, direct: 0))
        XCTAssertEqual(progress.claimCheckIn(on: midnight.addingTimeInterval(3_600)), .alreadyClaimed)
        XCTAssertEqual(progress.claimCheckIn(on: midnight.addingTimeInterval(-86_400)), .clockRollback)
        XCTAssertEqual(progress.bonusHints, 2)
        XCTAssertFalse(progress.checkIn.canClaim(on: midnight))
    }

    func testSevenDayCycleRewardsOnceAndGapRestartsStreak() {
        var progress = PlayerProgress()
        let start = Date(timeIntervalSince1970: 2_000 * 86_400)
        for day in 0..<7 { _ = progress.claimCheckIn(on: start.addingTimeInterval(Double(day * 86_400))) }
        XCTAssertEqual(progress.checkIn.streak, 7)
        XCTAssertEqual(progress.checkIn.cycleDay, 7)
        XCTAssertEqual(progress.checkIn.completedCycles, 1)
        XCTAssertEqual(progress.bonusHints, 7)
        XCTAssertEqual(progress.bonusDirect, 1)
        _ = progress.claimCheckIn(on: start.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(progress.checkIn.streak, 8)
        XCTAssertEqual(progress.checkIn.cycleDay, 1)
        _ = progress.claimCheckIn(on: start.addingTimeInterval(10 * 86_400))
        XCTAssertEqual(progress.checkIn.streak, 1)
        XCTAssertEqual(progress.checkIn.cycleDay, 1)
        XCTAssertEqual(progress.bonusDirect, 1)
    }

    func testTimeIgnoresInvalidInputsAndSettingsRoundTrip() throws {
        var session = GameSession(puzzle: try puzzle())
        session.advanceTime(by: 2.5)
        session.advanceTime(by: -.infinity)
        session.advanceTime(by: .nan)
        session.advanceTime(by: -20)
        XCTAssertEqual(session.elapsedSeconds, 2.5)
        let settings = GameSettings(musicEnabled: false, soundEnabled: true,
                                    voiceEnabled: false, hapticsEnabled: true)
        XCTAssertEqual(try JSONDecoder().decode(GameSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
