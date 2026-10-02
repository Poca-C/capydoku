import Foundation

/// Independent local quality measurements, used only after every acceptance gate.
/// They are not a difficulty score or a calibrated measure of player preference.
public struct PuzzleQualityReport: Codable, Equatable, Sendable {
    public var evaluatorVersion: String
    public var metricStatus: String
    public var regionAreas: [Int]
    public var regionPerimeters: [Int]
    public var deductivelyPlacedAnimals: Int
    public var requiredAnimals: Int
    public var components: [String: Double]
    public var componentWeights: [String: Double]
    public var score: Double
}

public enum PuzzleQualityEvaluator {
    public static let version = "local-geometry-deduction-quality-v1"
    public static let metricStatus = "Uncalibrated local geometry/readability and deduction-coverage heuristics; not reference-product quality or measured player preference. Used only to break equal target-distance ties after all acceptance gates."

    public static func evaluate(puzzle: Puzzle, solver: DifficultySolverReport) -> PuzzleQualityReport {
        let n = puzzle.size
        let weights = ["region_compactness": 0.60, "region_area_balance": 0.25, "deduction_coverage": 0.15]
        guard (1...16).contains(n), puzzle.regions.count == n * n,
              puzzle.regions.allSatisfy({ (0..<n).contains($0) }), Set(puzzle.regions).count == n,
              solver.hardChecksPassed else {
            return PuzzleQualityReport(evaluatorVersion: version, metricStatus: metricStatus,
                regionAreas: [], regionPerimeters: [], deductivelyPlacedAnimals: 0,
                requiredAnimals: max(0, min(16, n)),
                components: weights.mapValues { _ in 0 }, componentWeights: weights, score: 0)
        }
        var areas = Array(repeating: 0, count: n), perimeters = Array(repeating: 0, count: n)
        for cell in puzzle.regions.indices {
            let region = puzzle.regions[cell]
            areas[region] += 1
            perimeters[region] += 4 - puzzle.orthogonalNeighbors(of: cell)
                .filter { puzzle.regions[$0] == region }.count
        }
        // Sorting paired measurements makes floating-point accumulation independent
        // of arbitrary region label numbers, and preserves an auditable pairing.
        let geometry = zip(areas, perimeters).sorted {
            $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
        }
        areas = geometry.map(\.0); perimeters = geometry.map(\.1)
        // A square region approaches 1; a thin or jagged region has more boundary
        // per unit area. Neither geometry measure changes the difficulty target.
        let compactness = geometry.reduce(0.0) { $0 + 4 * sqrt(Double($1.0)) / Double($1.1) } / Double(n)
        let areaBalance = 1 - Double(areas.reduce(0) { $0 + abs($1 - n) }) / Double(2 * n * n)
        let placements = max(0, min(n, solver.forcedMoveCount))
        let coverage = Double(placements) / Double(n)
        let components = ["region_compactness": bounded(compactness),
                          "region_area_balance": bounded(areaBalance), "deduction_coverage": coverage]
        // Fixed accumulation order is part of the deterministic versioned policy.
        let score = 100 * bounded(components["region_compactness"]! * weights["region_compactness"]!
            + components["region_area_balance"]! * weights["region_area_balance"]!
            + components["deduction_coverage"]! * weights["deduction_coverage"]!)
        return PuzzleQualityReport(evaluatorVersion: version, metricStatus: metricStatus,
            regionAreas: areas, regionPerimeters: perimeters, deductivelyPlacedAnimals: placements,
            requiredAnimals: n, components: components, componentWeights: weights, score: score)
    }

    private static func bounded(_ value: Double) -> Double { max(0, min(1, value)) }
}

/// Lexicographic ordering: quality never compensates for a worse target match.
struct GenerationCandidateRank: Equatable {
    static let policyVersion = "target-distance-quality-index-v1"
    static let policyDescription = "After all acceptance gates: lowest normalized target distance, then highest local quality score on exact distance ties, then lowest candidate index on exact quality ties. No distance rounding or tolerance expansion."

    var targetDistance: Double
    var qualityScore: Double
    var candidateIndex: Int

    func isPreferred(over other: GenerationCandidateRank) -> Bool {
        if targetDistance != other.targetDistance { return targetDistance < other.targetDistance }
        if qualityScore != other.qualityScore { return qualityScore > other.qualityScore }
        return candidateIndex < other.candidateIndex
    }
}
