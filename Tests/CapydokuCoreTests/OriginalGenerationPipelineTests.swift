import XCTest
@testable import CapydokuCore

final class OriginalGenerationPipelineTests: XCTestCase {
    func testOriginalFirstTwentyRolesAndLongTermCaps() {
        XCTAssertEqual(DifficultyProfile.provisional(level: 1).difficultyRole, "Tutorial")
        for level in 2...5 { XCTAssertEqual(DifficultyProfile.provisional(level: level).difficultyRole, "Entry / Flow") }
        for level in 6...8 { XCTAssertEqual(DifficultyProfile.provisional(level: level).difficultyRole, "Basic Mastery") }
        XCTAssertEqual(DifficultyProfile.provisional(level: 9).difficultyRole, "Scale Up")
        XCTAssertEqual(DifficultyProfile.provisional(level: 15).difficultyRole, "Error Spike")
        XCTAssertEqual(DifficultyProfile.provisional(level: 16).difficultyRole, "Thinking Peak")
        XCTAssertEqual(DifficultyProfile.provisional(level: 17).difficultyBand, .recovery)
        XCTAssertEqual(DifficultyProfile.provisional(level: 20).difficultyRole, "Hard / Compact Hard")
        for start in stride(from: 151, through: 991, by: 10) {
            let profiles = (start..<(start + 10)).map { DifficultyProfile.provisional(level: $0) }
            XCTAssertEqual(profiles.filter { $0.difficultyBand == .flow }.count, 2)
            XCTAssertEqual(profiles.filter { $0.difficultyBand == .recovery }.count, 1)
            XCTAssertEqual(profiles.last?.difficultyBand, .hard)
            XCTAssertTrue(profiles.allSatisfy { $0.reasoningDepthTarget.maximum <= 3 && $0.validationErrors.isEmpty })
        }
        // The first Hard and its following Flow have equal board size; scoring is not size-only.
        XCTAssertEqual(PuzzleGenerator.size(for: 10), PuzzleGenerator.size(for: 11))
    }

    func testProfileImportReportsChangesAndRejectsConcreteReferenceBoards() throws {
        let first = DifficultyProfileCatalog(version: "demo-a", profiles: [.provisional(level: 1)])
        var second = first
        second.version = "demo-b"
        second.profiles[0].candidateDensityTarget = .init(0.1, 0.9)
        let imported = try DifficultyProfileCatalog.importing(JSONEncoder().encode(second), replacing: first)
        XCTAssertEqual(imported.1.changedLevelIDs, [1])
        XCTAssertTrue(imported.1.fieldDifferences["1"]!.contains("candidateDensityTarget"))
        XCTAssertFalse(imported.1.frozenReferenceVerified)
        XCTAssertTrue(imported.1.errors.isEmpty)
        let forbidden = Data("{\"profiles\":[],\"version\":\"a\",\"region_map\":[0,1]}".utf8)
        XCTAssertThrowsError(try DifficultyProfileCatalog.importing(forbidden))
        second.profiles[0].provenance.status = "imported_frozen_reference"
        let incomplete = try DifficultyProfileCatalog.importing(JSONEncoder().encode(second))
        XCTAssertTrue(incomplete.1.errors.contains("L1:incomplete_reference_evidence"))
    }

    func testPipelineProducesAuditableBatchAndRebuildsSameSelectedCandidate() throws {
        let first = try PuzzleGenerator.generateAudited(level: 1, seed: 222)
        let second = try PuzzleGenerator.generateAudited(level: 1, seed: 222)
        let puzzle = try XCTUnwrap(first.puzzle)
        XCTAssertEqual(puzzle, second.puzzle)
        XCTAssertEqual(try PuzzleGenerator.rebuild(puzzle), puzzle)
        XCTAssertEqual(first.report.generatedCandidates, 100)
        XCTAssertEqual(first.report.requestedCandidates, 100)
        XCTAssertEqual(first.report.termination, "selected_best_match")
        XCTAssertGreaterThan(first.report.similarityPassed, 1)
        XCTAssertGreaterThanOrEqual(first.report.solverPassed, first.report.difficultyPassed)
        XCTAssertGreaterThanOrEqual(first.report.difficultyPassed, first.report.similarityPassed)
        XCTAssertEqual(puzzle.generationMetadata, first.report.metadata)
        XCTAssertEqual(first.report.selectedSolverReport?.reasoningDepth, 1)
        XCTAssertEqual(first.report.selectedSolverReport?.trialRequired, false)
        XCTAssertEqual(first.report.selectedSimilarityReport?.originalStrictAcceptance, false)
    }

    func testTargetMetricsRejectRatherThanRelabelingBoard() throws {
        let puzzle = try PuzzleGenerator.generate(level: 1)
        let solver = DifficultyEvaluator.evaluate(puzzle)
        var target = DifficultyProfile.provisional(level: 1)
        target.candidateDensityTarget = .init(0.99, 1)
        target.forcedMoveDensityTarget = .init(0, 0.1)
        let report = DifficultyFilter.evaluate(puzzle: puzzle, solver: solver, target: target)
        XCTAssertFalse(report.accepted)
        XCTAssertTrue(report.rejectionReasons.contains("candidate_density_outside_target"))
        XCTAssertTrue(report.rejectionReasons.contains("forced_move_density_outside_target"))
        target.reasoningDepthTarget = .init(2, 3)
        let result = try PuzzleGenerator.generateAudited(level: 1, profile: target)
        XCTAssertNil(result.puzzle)
        XCTAssertEqual(result.report.termination, "invalid_profile")
    }

    func testStrictSimilarityRejectsRepeatedAnswerAndDocumentsFourByFourLimit() throws {
        let puzzle = try PuzzleGenerator.generate(level: 1)
        var sameAnswer = puzzle
        sameAnswer.id = 2
        var corpusEntry = SimilarityCorpusEntry(game: "CapyDoku", puzzle: sameAnswer)
        // Isolate answer matching without an exact graph or full-board match.
        corpusEntry.fingerprint.regionGraph = Array(repeating: -1, count: 16)
        corpusEntry.fingerprint.serializedBoard = "different"
        let strict = PuzzleSimilarity.evaluate(puzzle, corpus: [corpusEntry], configuration: .strict)
        XCTAssertFalse(strict.accepted)
        XCTAssertTrue(strict.matches[0].matchedDimensions.contains("answer_pattern"))
        var unsupported = SimilarityConfiguration.strict
        unsupported.strictOriginalHardRejections = false
        XCTAssertFalse(PuzzleSimilarity.evaluate(puzzle, corpus: [], configuration: unsupported).accepted)
        corpusEntry.game = "PandaDoku"
        XCTAssertFalse(PuzzleSimilarity.evaluate(puzzle, corpus: [corpusEntry], configuration: .strict).accepted)
        // With one animal per row/column and no touching, 4x4 permits only two permutations.
        // Therefore >2 such levels cannot satisfy a same-product unique-answer hard rule.
        let allAnswers = PuzzleSolver.solutions(size: 4, regions: (0..<16).map { $0 / 4 }, limit: 100)
        XCTAssertEqual(allAnswers.count, 2)
        XCTAssertEqual(PuzzleGenerator.size(for: 2), 4)
        XCTAssertEqual(PuzzleGenerator.size(for: 3), 6, "Use a larger simple board instead of relaxing the original answer-uniqueness rule")
    }

    func testNamespacedSeedsAndExpiredBudgetNeverReleasePartialBatch() throws {
        let capy = try PuzzleGenerator.generateAudited(level: 6, seed: 987, productNamespace: "CapyDoku")
        let panda = try PuzzleGenerator.generateAudited(level: 6, seed: 987, productNamespace: "PandaDoku")
        XCTAssertNotNil(capy.puzzle); XCTAssertNotNil(panda.puzzle)
        XCTAssertNotEqual(capy.puzzle?.fingerprint, panda.puzzle?.fingerprint)
        XCTAssertNotEqual(capy.report.metadata.candidateSeed, panda.report.metadata.candidateSeed)
        let expired = try PuzzleGenerator.generateAudited(level: 101, timeBudgetMilliseconds: 1)
        XCTAssertNil(expired.puzzle)
        XCTAssertEqual(expired.report.termination, "time_budget_exceeded")
        let undersized = try PuzzleGenerator.generateAudited(level: 1, maxAttempts: 99)
        XCTAssertNil(undersized.puzzle)
        XCTAssertEqual(undersized.report.generatedCandidates, 0)
        XCTAssertEqual(undersized.report.termination, "insufficient_candidate_budget")
    }
}
