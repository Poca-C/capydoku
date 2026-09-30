import Foundation

public struct DifficultySolverReport: Codable, Equatable, Sendable {
    public var evaluatorVersion = "shared-deduction-metrics-v1"
    public var metricStatus = "Local rule-engine estimates; not calibrated human solve time, failure probability, or proven minimal reasoning depth. trialRequired means this configured deduction engine stalls."
    public var uniqueSolution: Bool
    public var regionConnected: Bool
    public var exactlyOnePerRow: Bool
    public var exactlyOnePerColumn: Bool
    public var exactlyOnePerRegion: Bool
    public var noAdjacentCapybaras: Bool
    public var difficultyScore: Double
    public var reasoningDepth: Int
    public var forcedMoveCount: Int
    public var forcedMoveDensity: Double
    public var candidateDensity: Double
    public var logicalStepCount: Int
    public var errorRisk: Double
    public var trialRequired: Bool
    public var regionComplexity: Double
    public var estimatedSolveTime: Double
    public var estimatedHintPressure: Double
    public var estimatedFailPressure: Double
    public var rulesUsed: [String: Int]
    public var initialForcedCells: [Int]
    public var hardChecksPassed: Bool { uniqueSolution && regionConnected && exactlyOnePerRow && exactlyOnePerColumn && exactlyOnePerRegion && noAdjacentCapybaras }
}

public enum DifficultyEvaluator {
    public static func evaluate(_ puzzle: Puzzle) -> DifficultySolverReport {
        let validation = PuzzleSolver.validate(puzzle), n = puzzle.size
        let cells = Set(puzzle.regions.indices), validShape = n > 0 && n <= 16 && cells.count == n * n
        let answer = puzzle.solution
        let inBounds = validShape && answer.allSatisfy { cells.contains($0) }
        var candidates = cells, confirmed = Set<Int>(), rules: [String: Int] = [:]
        var steps = 0, forced = 0, depth = 0, densitySum = 0.0
        let initial = validShape ? Set(PuzzleHints.units(puzzle).filter { $0.1.count == 1 }.flatMap(\.1)).sorted() : []
        if validation.valid {
            while steps < n * n * 2, let deduction = PuzzleHints.deduction(puzzle, candidates: candidates, confirmed: confirmed) {
                let remainingAnimals = max(1, n - confirmed.count)
                // 0 = only one candidate per remaining animal; 1 = all cells still plausible.
                densitySum += max(0, min(1, Double(candidates.count - remainingAnimals) / Double(max(1, n * remainingAnimals - remainingAnimals))))
                let ruleDepth: Int
                switch deduction.rule {
                case "Single candidate": ruleDepth = 1
                case "Region-row lock", "Region-column lock", "Common conflict": ruleDepth = 2
                default: ruleDepth = 3
                }
                depth = max(depth, ruleDepth)
                rules[deduction.rule, default: 0] += 1
                candidates.subtract(deduction.excluded)
                if let cell = deduction.forced { confirmed.insert(cell); candidates.remove(cell); forced += 1 }
                steps += 1
            }
        }
        let trial = confirmed.count != n
        let forcedDensity = steps == 0 ? 0 : Double(forced) / Double(steps)
        let density = steps == 0 ? 1 : densitySum / Double(steps)
        var perimeter = 0
        if validShape {
            for cell in cells {
                perimeter += 4 - puzzle.orthogonalNeighbors(of: cell).filter { puzzle.regions[$0] == puzzle.regions[cell] }.count
            }
        }
        let complexity = validShape ? min(1, max(0, Double(perimeter - 4 * n) / Double(max(1, 4 * n * n - 4 * n)))) : 1
        // This is an interpretable engine-based ambiguity proxy, never a player failure probability.
        let errorRisk = min(1, density * (1 - forcedDensity * 0.7) + (trial ? 0.3 : 0))
        let score = min(100, max(0, (1 - forcedDensity) * 40 + Double(max(0, depth - 1)) * 15 + density * 20 + errorRisk * 10 + (trial ? 20 : 0)))
        return DifficultySolverReport(uniqueSolution: validation.solutionCount == 1 && validation.valid,
            regionConnected: validation.regionConnected,
            exactlyOnePerRow: inBounds && answer.count == n && Set(answer.map { $0 / n }).count == n,
            exactlyOnePerColumn: inBounds && answer.count == n && Set(answer.map { $0 % n }).count == n,
            exactlyOnePerRegion: inBounds && answer.count == n && Set(answer.map { puzzle.regions[$0] }).count == n,
            noAdjacentCapybaras: inBounds && answer.enumerated().allSatisfy { index, a in
                answer.dropFirst(index + 1).allSatisfy { b in abs(a / n - b / n) > 1 || abs(a % n - b % n) > 1 }
            }, difficultyScore: score, reasoningDepth: depth, forcedMoveCount: forced, forcedMoveDensity: forcedDensity,
            candidateDensity: density, logicalStepCount: steps, errorRisk: errorRisk, trialRequired: trial,
            regionComplexity: complexity, estimatedSolveTime: Double(steps * 5 + max(0, depth - 1) * 15 + (trial ? 90 : 0)),
            estimatedHintPressure: min(1, (1 - forcedDensity) * 0.6 + (trial ? 0.4 : 0)),
            estimatedFailPressure: errorRisk, rulesUsed: rules, initialForcedCells: initial)
    }
}

public struct DifficultyFilterReport: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var rejectionReasons: [String]
    public var normalizedTargetDistance: Double
    public var measurements: [String: Double]
    public var targetProvenance: DifficultyProvenance
}

public enum DifficultyFilter {
    public static func evaluate(puzzle: Puzzle, solver: DifficultySolverReport, target: DifficultyProfile) -> DifficultyFilterReport {
        let checks: [(String, Double, DifficultyRange)] = [
            ("difficulty_score", solver.difficultyScore, target.difficultyScoreTarget),
            ("band_score", solver.difficultyScore, target.bandScoreRange),
            ("board_size", Double(puzzle.size), target.boardSizeCurveTarget),
            ("region_count", Double(Set(puzzle.regions).count), target.regionCountTarget),
            ("region_complexity", solver.regionComplexity, target.regionComplexityTarget),
            ("forced_move_density", solver.forcedMoveDensity, target.forcedMoveDensityTarget),
            ("candidate_density", solver.candidateDensity, target.candidateDensityTarget),
            ("reasoning_depth", Double(solver.reasoningDepth), target.reasoningDepthTarget),
            ("logical_step_count", Double(solver.logicalStepCount), target.logicalStepCountTarget),
            ("error_risk", solver.errorRisk, target.errorRiskTarget),
            ("solve_time_estimate", solver.estimatedSolveTime, target.solveTimeTarget),
            ("hint_pressure_estimate", solver.estimatedHintPressure, target.hintPressureTarget),
            ("fail_pressure_estimate", solver.estimatedFailPressure, target.failPressureTarget)
        ]
        var reasons = target.validationErrors
        if !solver.hardChecksPassed { reasons.append("solver_hard_checks") }
        if solver.trialRequired && !target.trialAllowed { reasons.append("trial_not_allowed") }
        for (name, value, range) in checks where !range.contains(value) { reasons.append(name + "_outside_target") }
        // Target score intervals are explicitly supplied; tolerance never permits crossing a band.
        // Estimate-only metrics remain labelled as such even when an imported target accepts them.
        let distance = checks.filter { $0.0 != "band_score" }.reduce(0.0) { result, check in
            result + (check.0 == "difficulty_score" ? 5 : 0.2) * abs(check.1 - check.2.midpoint) / max(1, check.2.maximum - check.2.minimum)
        }
        return DifficultyFilterReport(accepted: reasons.isEmpty, rejectionReasons: reasons,
            normalizedTargetDistance: distance, measurements: Dictionary(uniqueKeysWithValues: checks.map { ($0.0, $0.1) }), targetProvenance: target.provenance)
    }
}
