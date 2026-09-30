import XCTest
@testable import CapydokuCore

final class EndlessCapacityTests: XCTestCase {
    private func completeSixBySixHistory() -> [SimilarityCorpusEntry] {
        let regions = (0..<36).map { $0 / 6 }
        return PuzzleSolver.solutions(size: 6, regions: regions, limit: 1_000).enumerated().map { index, answer in
            let puzzle = Puzzle(id: index + 1, size: 6, regions: regions, solution: answer,
                                seed: UInt64(index), generatorVersion: "synthetic-answer-capacity", difficulty: "synthetic")
            return SimilarityCorpusEntry(game: "CapyDoku", puzzle: puzzle)
        }
    }

    func testCapacityMatchesIndependentSolverAndIgnoresInvalidOrRepeatedAnswers() {
        for size in [4, 6, 8] {
            let answers = PuzzleSolver.solutions(size: size, regions: (0..<(size * size)).map { $0 / size }, limit: 100_000)
            XCTAssertEqual(PuzzleAnswerCapacity.total(size: size), answers.count)
        }
        let history = completeSixBySixHistory()
        XCTAssertEqual(history.count, 90)
        XCTAssertEqual(PuzzleAnswerCapacity.used(size: 6, corpus: history + history), 90)
        var invalid = history[0]
        invalid.fingerprint.answerPattern = [0, 7, 14, 21, 28, 35] // Adjacent animals.
        XCTAssertEqual(PuzzleAnswerCapacity.used(size: 6, corpus: [invalid]), 0)
        invalid.fingerprint.answerPattern = [0, 8, 16, 18, 26, 36] // Outside the board.
        XCTAssertEqual(PuzzleAnswerCapacity.used(size: 6, corpus: [invalid]), 0)
        XCTAssertEqual(PuzzleAnswerCapacity.total(size: 5), 0)
    }

    func testExhaustedFixedProfileStopsWithoutSpendingCandidateBudgetOrChangingTarget() throws {
        var fixed = DifficultyProfile.provisional(level: 291)
        fixed.boardSizeCurveTarget = .init(6, 6)
        fixed.regionCountTarget = .init(6, 6)
        let result = try PuzzleGenerator.generateAudited(level: 291, profile: fixed, corpus: completeSixBySixHistory())
        XCTAssertNil(result.puzzle)
        XCTAssertEqual(result.report.target, fixed)
        XCTAssertEqual(result.report.generatedCandidates, 0)
        XCTAssertEqual(result.report.termination, "answer_space_exhausted")
        XCTAssertEqual(result.report.rejectionReasons["capacity:size_6_answer_space_exhausted"], 1)
    }

    func testEndlessFlowContinuesAfterAllSixBySixAnswersAreUsedWithoutRelaxingDifficulty() throws {
        let history = completeSixBySixHistory()
        let result = try PuzzleGenerator.generateAudited(level: 291, corpus: history)
        let puzzle = try XCTUnwrap(result.puzzle, "\(result.report.termination): \(result.report.rejectionReasons)")
        XCTAssertTrue([8, 10].contains(puzzle.size))
        XCTAssertEqual(result.report.target.difficultyBand, .flow)
        XCTAssertEqual(result.report.target.difficultyScoreTarget, .init(25.5, 34.5))
        XCTAssertEqual(result.report.target.reasoningDepthTarget.maximum, 2)
        XCTAssertEqual(result.report.generatedCandidates, 100)
        XCTAssertEqual(result.report.rejectionReasons["capacity:size_6_answer_space_exhausted"], 1)
        XCTAssertTrue(PuzzleSolver.validate(puzzle).valid)
        XCTAssertEqual(result.report.selectedDifficultyReport?.accepted, true)
        XCTAssertEqual(result.report.selectedSimilarityReport?.accepted, true)
        XCTAssertEqual(result.report.selectedSolverReport?.trialRequired, false)
        XCTAssertEqual(try PuzzleGenerator.rebuild(puzzle), puzzle)
    }

    func testEndlessProfilesKeepWaveAndCapsAcrossTheSupportedLevelRange() {
        for level in [151, 152, 153, 156, 159, 160, 291, 996, 99_999, 100_000] {
            let profile = DifficultyProfile.provisional(level: level)
            XCTAssertTrue(profile.validationErrors.isEmpty)
            XCTAssertEqual(profile.profileVersion, DifficultyProfile.provisionalEndlessVersion)
            XCTAssertEqual(profile.boardSizeCurveTarget.maximum, 10)
            XCTAssertLessThanOrEqual(profile.reasoningDepthTarget.maximum, 3)
            XCTAssertFalse(profile.trialAllowed)
            XCTAssertEqual(profile.regionCountTarget, profile.boardSizeCurveTarget)
        }
        for level in 1...150 {
            let profile = DifficultyProfile.provisional(level: level)
            XCTAssertEqual(profile.profileVersion, DifficultyProfile.provisionalVersion)
            XCTAssertEqual(profile.boardSizeCurveTarget.minimum, profile.boardSizeCurveTarget.maximum)
        }
    }
}
