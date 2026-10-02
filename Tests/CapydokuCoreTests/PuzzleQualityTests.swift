import XCTest
@testable import CapydokuCore

final class PuzzleQualityTests: XCTestCase {
    private var fixture: Puzzle {
        Puzzle(id: 1, size: 4, regions: [0, 0, 1, 1, 0, 0, 0, 1, 2, 3, 0, 1, 3, 3, 3, 1],
            solution: [1, 7, 8, 14], seed: 1, generatorVersion: PuzzleGenerator.version, difficulty: "Tutorial")
    }

    func testQualityBreaksEqualDistanceTieBeforeCandidateIndex() {
        let lower = GenerationCandidateRank(targetDistance: 0.2, qualityScore: 70, candidateIndex: 1)
        let higher = GenerationCandidateRank(targetDistance: 0.2, qualityScore: 80, candidateIndex: 99)
        XCTAssertTrue(higher.isPreferred(over: lower))
        XCTAssertFalse(lower.isPreferred(over: higher))
        let earlier = GenerationCandidateRank(targetDistance: 0.2, qualityScore: 80, candidateIndex: 2)
        XCTAssertTrue(earlier.isPreferred(over: higher))
        XCTAssertFalse(earlier.isPreferred(over: earlier))
    }

    func testTargetDistanceAlwaysWinsIncludingAdjacentFloatingPointValues() {
        let nearer = GenerationCandidateRank(targetDistance: 0.2, qualityScore: 0, candidateIndex: 99)
        let farther = GenerationCandidateRank(targetDistance: Double(0.2).nextUp, qualityScore: 100, candidateIndex: 0)
        XCTAssertTrue(nearer.isPreferred(over: farther))
        XCTAssertFalse(farther.isPreferred(over: nearer))
    }

    func testQualityIsBoundedAuditableAndIndependentOfRegionLabels() throws {
        let puzzle = fixture, solver = DifficultyEvaluator.evaluate(fixture)
        XCTAssertTrue(solver.hardChecksPassed)
        let quality = PuzzleQualityEvaluator.evaluate(puzzle: puzzle, solver: solver)
        XCTAssertEqual(quality.evaluatorVersion, PuzzleQualityEvaluator.version)
        XCTAssertTrue(quality.metricStatus.contains("Uncalibrated"))
        XCTAssertTrue((0...100).contains(quality.score))
        XCTAssertTrue(quality.components.values.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(quality.regionAreas.reduce(0, +), 16)
        XCTAssertEqual(quality.regionPerimeters.count, 4)
        XCTAssertEqual(quality.deductivelyPlacedAnimals, 4)
        XCTAssertEqual(quality.requiredAnimals, 4)
        XCTAssertEqual(quality.componentWeights.values.reduce(0, +), 1, accuracy: 0.000_000_001)
        let compactness = zip(quality.regionAreas, quality.regionPerimeters)
            .reduce(0.0) { $0 + 4 * sqrt(Double($1.0)) / Double($1.1) } / 4
        XCTAssertEqual(try XCTUnwrap(quality.components["region_compactness"]), compactness, accuracy: 0.000_000_001)
        let recomputed = quality.components.keys.sorted().reduce(0.0) {
            $0 + quality.components[$1]! * quality.componentWeights[$1]! * 100
        }
        XCTAssertEqual(quality.score, recomputed, accuracy: 0.000_000_001)
        var renamed = puzzle
        renamed.regions = renamed.regions.map { [2, 0, 3, 1][$0] }
        XCTAssertEqual(PuzzleQualityEvaluator.evaluate(puzzle: renamed, solver: solver), quality)
        XCTAssertEqual(try JSONDecoder().decode(PuzzleQualityReport.self, from: JSONEncoder().encode(quality)), quality)
    }

    func testMalformedShapeProducesZeroQualityWithoutOverflowOrIndexing() {
        var puzzle = fixture
        let solver = DifficultyEvaluator.evaluate(puzzle)
        puzzle.size = Int.max
        let quality = PuzzleQualityEvaluator.evaluate(puzzle: puzzle, solver: solver)
        XCTAssertEqual(quality.score, 0)
        XCTAssertTrue(quality.regionAreas.isEmpty)
        XCTAssertTrue(quality.components.values.allSatisfy { $0 == 0 })
    }

    func testSelectedQualityIsStoredAndHistoricalReportsStillDecode() throws {
        let result = try PuzzleGenerator.generateAudited(level: 1, seed: 222)
        let puzzle = try XCTUnwrap(result.puzzle)
        let solver = try XCTUnwrap(result.report.selectedSolverReport)
        XCTAssertEqual(result.report.selectedQualityReport, PuzzleQualityEvaluator.evaluate(puzzle: puzzle, solver: solver))
        XCTAssertEqual(result.report.selectionPolicyVersion, GenerationCandidateRank.policyVersion)
        XCTAssertEqual(result.report.selectionPolicy, GenerationCandidateRank.policyDescription)
        XCTAssertEqual(result.report.generatedCandidates, 100)
        XCTAssertEqual(try PuzzleGenerator.rebuild(puzzle), puzzle)
        let data = try JSONEncoder().encode(result.report)
        XCTAssertEqual(try JSONDecoder().decode(GenerationPipelineReport.self, from: data), result.report)

        var historical = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["selectedQualityReport", "selectionPolicyVersion", "selectionPolicy"] {
            historical.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(GenerationPipelineReport.self,
            from: JSONSerialization.data(withJSONObject: historical))
        XCTAssertNil(decoded.selectedQualityReport)
        XCTAssertNil(decoded.selectionPolicyVersion)
        XCTAssertNil(decoded.selectionPolicy)
        XCTAssertEqual(decoded.selectedSolverReport, result.report.selectedSolverReport)
        XCTAssertEqual(decoded.metadata, result.report.metadata)
    }

    func testRealHundredCandidateBatchUsesQualityToImproveAnExactDistanceTie() throws {
        let result = try PuzzleGenerator.generateAudited(level: 1, seed: 222)
        XCTAssertNotNil(result.puzzle)
        let metadata = result.report.metadata
        let firstSeed = metadata.candidateSeed &- UInt64(metadata.candidateIndex) &* 0xD1B54A32D192ED03
        var ranks = [GenerationCandidateRank]()
        for index in 0..<100 {
            guard let puzzle = try? PuzzleGenerator.generateCandidate(level: 1,
                seed: firstSeed &+ UInt64(index) &* 0xD1B54A32D192ED03, size: 4,
                variation: index, timeBudgetMilliseconds: 8_000) else { continue }
            let solver = DifficultyEvaluator.evaluate(puzzle)
            let difficulty = DifficultyFilter.evaluate(puzzle: puzzle, solver: solver, target: result.report.target)
            guard solver.hardChecksPassed, difficulty.accepted,
                  PuzzleSimilarity.evaluate(puzzle, corpus: [], configuration: .strict).accepted else { continue }
            ranks.append(GenerationCandidateRank(targetDistance: difficulty.normalizedTargetDistance,
                qualityScore: PuzzleQualityEvaluator.evaluate(puzzle: puzzle, solver: solver).score, candidateIndex: index))
        }
        let oldWinner = try XCTUnwrap(ranks.min {
            $0.targetDistance == $1.targetDistance ? $0.candidateIndex < $1.candidateIndex : $0.targetDistance < $1.targetDistance
        })
        let newWinner = try XCTUnwrap(ranks.min { $0.isPreferred(over: $1) })
        XCTAssertEqual(result.report.metadata.candidateIndex, newWinner.candidateIndex)
        XCTAssertEqual(result.report.selectedQualityReport?.score, newWinner.qualityScore)
        XCTAssertEqual(newWinner.targetDistance, oldWinner.targetDistance)
        XCTAssertGreaterThan(newWinner.qualityScore, oldWinner.qualityScore,
            "This fixed real batch must demonstrate a quality decision, not only an unused report field.")
        XCTAssertNotEqual(newWinner.candidateIndex, oldWinner.candidateIndex)
    }

    func testQualityCannotBypassDifficultyOrCandidateAndTimeBudgets() throws {
        var profile = DifficultyProfile.provisional(level: 1)
        profile.candidateDensityTarget = .init(0.99, 1)
        let rejected = try PuzzleGenerator.generateAudited(level: 1, profile: profile)
        XCTAssertNil(rejected.puzzle)
        XCTAssertEqual(rejected.report.generatedCandidates, 100)
        XCTAssertEqual(rejected.report.difficultyPassed, 0)
        XCTAssertNil(rejected.report.selectedQualityReport)

        let insufficient = try PuzzleGenerator.generateAudited(level: 1, maxAttempts: 99)
        XCTAssertNil(insufficient.puzzle)
        XCTAssertEqual(insufficient.report.termination, "insufficient_candidate_budget")
        XCTAssertNil(insufficient.report.selectedQualityReport)
        let expired = try PuzzleGenerator.generateAudited(level: 101, timeBudgetMilliseconds: 1)
        XCTAssertNil(expired.puzzle)
        XCTAssertEqual(expired.report.termination, "time_budget_exceeded")
    }
}
