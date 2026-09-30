import Foundation

public struct PuzzleFingerprint: Codable, Equatable, Sendable {
    public var gridSize: Int
    public var regionGraph: [Int]
    public var regionSizeDistribution: [Int]
    public var answerPattern: [Int]
    public var openingState: [Int]
    public var serializedBoard: String
    public init(puzzle: Puzzle) {
        gridSize = puzzle.size
        var labels: [Int: Int] = [:]
        regionGraph = puzzle.regions.map { original in
            if let label = labels[original] { return label }
            let label = labels.count; labels[original] = label; return label
        }
        regionSizeDistribution = (0..<puzzle.size).map { region in puzzle.regions.filter { $0 == region }.count }.sorted()
        answerPattern = puzzle.solution.sorted()
        openingState = puzzle.regions.indices.filter { cell in puzzle.regions.filter { $0 == puzzle.regions[cell] }.count == 1 }
        serializedBoard = "\(gridSize):\(regionGraph.map(String.init).joined(separator: ",")):\(answerPattern.map(String.init).joined(separator: ","))"
    }
}

public struct SimilarityCorpusEntry: Codable, Equatable, Sendable {
    public var game: String
    public var levelID: Int
    public var fingerprint: PuzzleFingerprint
    public init(game: String, puzzle: Puzzle) { self.game = game; self.levelID = puzzle.id; self.fingerprint = PuzzleFingerprint(puzzle: puzzle) }
}

public struct SimilarityConfiguration: Codable, Equatable, Sendable {
    public var version: String
    public var threshold: Double
    public var strictOriginalHardRejections: Bool
    public var crossProductCorpusAvailable: Bool
    public static let strict = SimilarityConfiguration(version: "original-ch3-strict-v1", threshold: 0.90, strictOriginalHardRejections: true, crossProductCorpusAvailable: false)
}

public struct SimilarityMatchReport: Codable, Equatable, Sendable {
    public var matchedGame: String
    public var matchedLevelID: Int
    public var similarityScore: Double
    public var matchedDimensions: [String]
    public var threshold: Double
    public var decision: String
    public var checkerVersion: String
}
public struct SimilarityReport: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var checkerVersion: String
    public var configurationVersion: String
    public var comparedBoards: Int
    public var crossProductStatus: String
    public var originalStrictAcceptance: Bool
    public var exceptions: [String]
    public var matches: [SimilarityMatchReport]
}

public enum PuzzleSimilarity {
    public static func evaluate(_ puzzle: Puzzle, game: String = "CapyDoku", corpus: [SimilarityCorpusEntry], configuration: SimilarityConfiguration) -> SimilarityReport {
        let candidate = PuzzleFingerprint(puzzle: puzzle)
        var matches: [SimilarityMatchReport] = [], accepted = true, exceptions: [String] = []
        let thresholdValid = configuration.threshold > 0 && configuration.threshold <= 1
        if !thresholdValid { accepted = false; exceptions.append("invalid_similarity_threshold") }
        if !configuration.strictOriginalHardRejections { accepted = false; exceptions.append("Disabling the original hard-rejection rules is unsupported.") }
        for entry in corpus where entry.fingerprint.gridSize == candidate.gridSize {
            let other = entry.fingerprint
            var dimensions: [String] = []
            if candidate.regionGraph == other.regionGraph { dimensions.append("region_graph") }
            if candidate.regionSizeDistribution == other.regionSizeDistribution { dimensions.append("region_size_distribution") }
            if candidate.answerPattern == other.answerPattern { dimensions.append("answer_pattern") }
            if candidate.openingState == other.openingState { dimensions.append("opening_state") }
            if candidate.serializedBoard == other.serializedBoard { dimensions.append("serialized_board") }
            func fraction(_ a: [Int], _ b: [Int]) -> Double {
                guard a.count == b.count else { return 0 }
                if a.isEmpty { return 1 }
                return Double(zip(a, b).filter { $0 == $1 }.count) / Double(a.count)
            }
            let score = fraction(candidate.regionGraph, other.regionGraph) * 0.45
                + fraction(candidate.regionSizeDistribution, other.regionSizeDistribution) * 0.15
                + fraction(candidate.answerPattern, other.answerPattern) * 0.30
                + (candidate.openingState == other.openingState ? 0.10 : 0)
            let hardAnswer = dimensions.contains("answer_pattern")
            let rejected = dimensions.contains("region_graph") || dimensions.contains("serialized_board") || hardAnswer || score > configuration.threshold
            if rejected { accepted = false }
            if rejected || !dimensions.isEmpty {
                matches.append(SimilarityMatchReport(matchedGame: entry.game, matchedLevelID: entry.levelID,
                    similarityScore: score, matchedDimensions: dimensions, threshold: configuration.threshold,
                    decision: rejected ? "Reject" : "Accept with recorded overlap", checkerVersion: "region-answer-opening-v1"))
            }
        }
        return SimilarityReport(accepted: accepted, checkerVersion: "region-answer-opening-v1", configurationVersion: configuration.version,
            comparedBoards: corpus.count, crossProductStatus: configuration.crossProductCorpusAvailable ? "supplied_corpus_checked" : "missing_other_product_corpus",
            originalStrictAcceptance: accepted && configuration.strictOriginalHardRejections && configuration.crossProductCorpusAvailable,
            exceptions: exceptions, matches: matches.sorted { $0.similarityScore > $1.similarityScore })
    }
}
