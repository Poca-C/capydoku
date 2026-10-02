import XCTest
@testable import CapydokuCore

final class DeductionTraceTests: XCTestCase {
    private func shipped(_ level: Int) throws -> Puzzle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent("Resources/levels.json")))
        return try XCTUnwrap(puzzles.first { $0.id == level })
    }

    func testTraceReplaysActualCandidateRemovalAndCompleteSolution() throws {
        for level in [1, 6, 10, 11, 16, 17, 20] {
            let puzzle = try shipped(level), report = DifficultyEvaluator.evaluate(puzzle)
            let trace = try XCTUnwrap(report.deductionTrace)
            var candidates = Set(puzzle.regions.indices), confirmed = Set<Int>()
            var longest = 0, chain = 0
            for (index, step) in trace.enumerated() {
                let deduction = try XCTUnwrap(PuzzleHints.deduction(puzzle, candidates: candidates, confirmed: confirmed))
                XCTAssertEqual(step.index, index)
                XCTAssertEqual(step.rule, deduction.rule)
                XCTAssertEqual(step.candidatesBefore, candidates.count)
                XCTAssertEqual(Set(step.excludedCells), deduction.excluded.intersection(candidates))
                XCTAssertEqual(step.confirmedCell, deduction.forced)
                candidates.subtract(step.excludedCells)
                if let cell = step.confirmedCell { confirmed.insert(cell); candidates.remove(cell) }
                else { chain += 1; longest = max(longest, chain) }
                XCTAssertEqual(step.eliminationChainLength, chain)
                XCTAssertEqual(step.candidatesAfter, candidates.count)
                XCTAssertLessThan(step.candidatesAfter, step.candidatesBefore)
                if step.confirmedCell != nil { chain = 0 }
            }
            XCTAssertEqual(confirmed, Set(puzzle.solution))
            XCTAssertEqual(report.logicalStepCount, trace.count)
            XCTAssertEqual(report.maximumEliminationChainLength, longest)
            XCTAssertFalse(report.trialRequired)
        }
    }

    func testObservedChainIsASeparateMetricFromRuleTierAndIsFiltered() throws {
        let puzzle = try shipped(10), solver = DifficultyEvaluator.evaluate(puzzle)
        let chain = try XCTUnwrap(solver.maximumEliminationChainLength)
        XCTAssertGreaterThan(chain, 0)
        var target = DifficultyProfile.provisional(level: 10)
        target.eliminationChainLengthTarget = .init(Double(chain + 1), Double(chain + 2))
        let filtered = DifficultyFilter.evaluate(puzzle: puzzle, solver: solver, target: target)
        XCTAssertFalse(filtered.accepted)
        XCTAssertTrue(filtered.rejectionReasons.contains("elimination_chain_length_outside_target"))
    }

    func testHistoricalReportsDecodeWithoutInventedTrace() throws {
        let puzzle = try shipped(1), original = DifficultyEvaluator.evaluate(puzzle)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "deductionTrace")
        json.removeValue(forKey: "maximumEliminationChainLength")
        json["evaluatorVersion"] = "shared-deduction-metrics-v1"
        let decoded = try JSONDecoder().decode(DifficultySolverReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.deductionTrace)
        XCTAssertEqual(decoded.evaluatorVersion, "shared-deduction-metrics-v1")
        XCTAssertTrue(DifficultyFilter.evaluate(puzzle: puzzle, solver: decoded,
            target: .provisional(level: 1)).rejectionReasons.contains("missing_deduction_trace"))
    }

    func testProvisionalRolesHaveEffectiveBoundsAndRemainUncalibrated() throws {
        let flow = DifficultyProfile.provisional(level: 11), hard = DifficultyProfile.provisional(level: 10)
        XCTAssertEqual(flow.boardSizeCurveTarget, hard.boardSizeCurveTarget)
        XCTAssertGreaterThan(flow.forcedMoveDensityTarget.minimum, hard.forcedMoveDensityTarget.maximum)
        for level in 1...180 {
            let p = DifficultyProfile.provisional(level: level)
            XCTAssertTrue(p.validationErrors.isEmpty, "L\(level): \(p.validationErrors)")
            XCTAssertFalse(p.provenance.isFrozenReference)
            for range in [p.regionComplexityTarget, p.candidateDensityTarget, p.hintPressureTarget, p.failPressureTarget] {
                XCTAssertLessThan(range.maximum - range.minimum, 1)
            }
            XCTAssertLessThan(p.solveTimeTarget.maximum, 3600)
        }
    }
}
