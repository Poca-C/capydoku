import Foundation

/// A bounded, answer-independent opening prefix. These are local Demo features,
/// not a claim that the first placement matches a human or reference product.
public struct PuzzleOpeningDeduction: Codable, Equatable, Sendable {
    public var rule: String
    public var forcedCell: Int?
    public var excludedCells: [Int]
}
public struct PuzzleOpeningBreakthrough: Codable, Equatable, Sendable {
    public var cell: Int
    /// Zero-based index into deductions, including exclusions before this placement.
    public var deductionIndex: Int
    public var rule: String
}
public struct PuzzleOpeningFingerprint: Codable, Equatable, Sendable {
    public static let currentVersion = "direct-opening-prefix-v1"
    public static let maximumSteps = 16
    public var version: String
    public var deductions: [PuzzleOpeningDeduction]
    public var firstBreakthrough: PuzzleOpeningBreakthrough?
    public var termination: String

    fileprivate static func make(size: Int, regions: [Int]) -> Self? {
        guard (1...16).contains(size), regions.count == size * size,
              regions.allSatisfy({ (0..<size).contains($0) }), Set(regions).count == size else { return nil }
        // Deliberately omit the stored solution. Never use next(), whose fallback
        // can perform exhaustive contradiction searches, inside generation filtering.
        let puzzle = Puzzle(id: 0, size: size, regions: regions, solution: [], seed: 0,
                            generatorVersion: "similarity-opening", difficulty: "local-demo")
        var candidates = Set(regions.indices)
        var steps: [PuzzleOpeningDeduction] = []
        for index in 0..<maximumSteps {
            guard let step = PuzzleHints.deduction(puzzle, candidates: candidates, confirmed: []) else {
                return Self(version: currentVersion, deductions: steps, firstBreakthrough: nil,
                            termination: "no_direct_deduction")
            }
            steps.append(.init(rule: step.rule, forcedCell: step.forced, excludedCells: step.excluded.sorted()))
            if let cell = step.forced {
                return Self(version: currentVersion, deductions: steps,
                            firstBreakthrough: .init(cell: cell, deductionIndex: index, rule: step.rule),
                            termination: "first_forced_placement")
            }
            candidates.subtract(step.excluded)
        }
        return Self(version: currentVersion, deductions: steps, firstBreakthrough: nil,
                    termination: "step_budget_reached")
    }

    /// Position, ordering and deduction kind all contribute; an empty singleton
    /// list no longer makes unrelated openings automatically identical.
    fileprivate var features: Set<String> {
        var result: Set<String> = ["termination:\(termination)"]
        for (index, step) in deductions.enumerated() {
            result.insert("step:\(index):rule:\(step.rule)")
            for cell in step.excludedCells { result.insert("step:\(index):exclude:\(cell)") }
            if let cell = step.forcedCell { result.insert("step:\(index):force:\(cell)") }
        }
        if let firstBreakthrough {
            result.insert("breakthrough:\(firstBreakthrough.deductionIndex):\(firstBreakthrough.cell):\(firstBreakthrough.rule)")
        }
        return result
    }
}

public struct PuzzleFingerprint: Codable, Equatable, Sendable {
    public var gridSize: Int
    public var regionGraph: [Int]
    public var regionSizeDistribution: [Int]
    public var answerPattern: [Int]
    /// Retained unchanged for old JSON/history validation.
    public var openingState: [Int]
    public var serializedBoard: String
    public var openingDetails: PuzzleOpeningFingerprint?

    public init(puzzle: Puzzle) {
        gridSize = puzzle.size
        var labels: [Int: Int] = [:]
        let canonicalRegions = puzzle.regions.map { original in
            if let label = labels[original] { return label }
            let label = labels.count; labels[original] = label; return label
        }
        regionGraph = canonicalRegions
        let counts = Dictionary(grouping: canonicalRegions, by: { $0 }).mapValues(\.count)
        regionSizeDistribution = (0..<max(0, puzzle.size)).map { counts[$0, default: 0] }.sorted()
        answerPattern = puzzle.solution.sorted()
        openingState = canonicalRegions.indices.filter { counts[canonicalRegions[$0]] == 1 }
        serializedBoard = "\(gridSize):\(regionGraph.map(String.init).joined(separator: ",")):\(answerPattern.map(String.init).joined(separator: ","))"
        openingDetails = PuzzleOpeningFingerprint.make(size: gridSize, regions: regionGraph)
    }

    /// Normalize only a missing legacy feature; supplied modern features remain
    /// untouched so the history store can detect inconsistent/tampered records.
    public func upgradingOpeningDetails() -> Self {
        var result = self
        if result.openingDetails == nil {
            result.openingDetails = PuzzleOpeningFingerprint.make(size: gridSize, regions: regionGraph)
        }
        return result
    }

    func matchesLegacyFields(of other: Self) -> Bool {
        gridSize == other.gridSize && regionGraph == other.regionGraph
            && regionSizeDistribution == other.regionSizeDistribution && answerPattern == other.answerPattern
            && openingState == other.openingState && serializedBoard == other.serializedBoard
    }
}

public struct SimilarityCorpusEntry: Codable, Equatable, Sendable {
    public var game: String
    public var levelID: Int
    public var fingerprint: PuzzleFingerprint
    public init(game: String, puzzle: Puzzle) {
        self.game = game; self.levelID = puzzle.id; self.fingerprint = PuzzleFingerprint(puzzle: puzzle)
    }
    private enum CodingKeys: String, CodingKey { case game, levelID, fingerprint }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        game = try values.decode(String.self, forKey: .game)
        levelID = try values.decode(Int.self, forKey: .levelID)
        // Once at the import boundary, never once per candidate × history entry.
        fingerprint = try values.decode(PuzzleFingerprint.self, forKey: .fingerprint).upgradingOpeningDetails()
    }
}

public struct SimilarityWeights: Codable, Equatable, Sendable {
    public var regionGraph: Double
    public var regionSizeDistribution: Double
    public var answerPattern: Double
    public var openingState: Double
    public init(regionGraph: Double, regionSizeDistribution: Double, answerPattern: Double, openingState: Double) {
        self.regionGraph = regionGraph; self.regionSizeDistribution = regionSizeDistribution
        self.answerPattern = answerPattern; self.openingState = openingState
    }
    public static let legacy = SimilarityWeights(regionGraph: 0.45, regionSizeDistribution: 0.15,
                                                 answerPattern: 0.30, openingState: 0.10)
    fileprivate var values: [Double] { [regionGraph, regionSizeDistribution, answerPattern, openingState] }
}

public struct SimilarityConfiguration: Codable, Equatable, Sendable {
    public var version: String
    public var threshold: Double
    public var strictOriginalHardRejections: Bool
    public var crossProductCorpusAvailable: Bool
    public var schemaVersion: Int
    public var weights: SimilarityWeights
    public var provenance: String

    public init(version: String, threshold: Double, strictOriginalHardRejections: Bool,
                crossProductCorpusAvailable: Bool, schemaVersion: Int = 1,
                weights: SimilarityWeights = .legacy, provenance: String = "local demo, uncalibrated") {
        self.version = version; self.threshold = threshold
        self.strictOriginalHardRejections = strictOriginalHardRejections
        self.crossProductCorpusAvailable = crossProductCorpusAvailable; self.schemaVersion = schemaVersion
        self.weights = weights; self.provenance = provenance
    }
    public static let strict = SimilarityConfiguration(version: "local-demo-similarity-v2", threshold: 0.90,
        strictOriginalHardRejections: true, crossProductCorpusAvailable: false)

    public var validationErrors: [String] {
        var errors: [String] = []
        if schemaVersion != 1 { errors.append("unsupported_similarity_configuration_schema") }
        if version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("missing_similarity_configuration_version") }
        if provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("missing_similarity_configuration_provenance") }
        if !threshold.isFinite || threshold <= 0 || threshold > 1 { errors.append("invalid_similarity_threshold") }
        if weights.values.contains(where: { !$0.isFinite || $0 < 0 || $0 > 1 })
            || abs(weights.values.reduce(0, +) - 1) > 0.000_001 { errors.append("invalid_similarity_weights") }
        if !strictOriginalHardRejections { errors.append("Disabling the original hard-rejection rules is unsupported.") }
        return errors
    }
    private enum CodingKeys: String, CodingKey {
        case version, threshold, strictOriginalHardRejections, crossProductCorpusAvailable, schemaVersion, weights, provenance
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        threshold = try values.decode(Double.self, forKey: .threshold)
        strictOriginalHardRejections = try values.decode(Bool.self, forKey: .strictOriginalHardRejections)
        crossProductCorpusAvailable = try values.decode(Bool.self, forKey: .crossProductCorpusAvailable)
        // Original four-field configuration files remain readable. Newly supplied
        // fields must pass the same validation as the bundled global file.
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        weights = try values.decodeIfPresent(SimilarityWeights.self, forKey: .weights) ?? .legacy
        provenance = try values.decodeIfPresent(String.self, forKey: .provenance) ?? "local demo, uncalibrated"
        let errors = validationErrors
        if !errors.isEmpty {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: errors.joined(separator: "; ")))
        }
    }
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
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
    /// Optional so reports embedded in older saved puzzles still decode.
    public var configurationProvenance: String?
    public var configurationWeights: SimilarityWeights?
    public var openingFingerprintVersion: String?
    public var calibrationStatus: String?
}

public enum PuzzleSimilarity {
    public static let checkerVersion = "region-answer-opening-v2"
    public static func evaluate(_ puzzle: Puzzle, game: String = "CapyDoku", corpus: [SimilarityCorpusEntry], configuration: SimilarityConfiguration) -> SimilarityReport {
        let candidate = PuzzleFingerprint(puzzle: puzzle)
        var matches: [SimilarityMatchReport] = []
        var exceptions = configuration.validationErrors
        var accepted = exceptions.isEmpty
        var hasLegacyOpening = false
        for entry in corpus where entry.fingerprint.gridSize == candidate.gridSize {
            let other = entry.fingerprint
            var dimensions: [String] = []
            if candidate.regionGraph == other.regionGraph { dimensions.append("region_graph") }
            if candidate.regionSizeDistribution == other.regionSizeDistribution { dimensions.append("region_size_distribution") }
            if candidate.answerPattern == other.answerPattern { dimensions.append("answer_pattern") }
            let openingScore: Double
            if let opening = candidate.openingDetails, let otherOpening = other.openingDetails,
               opening.version == otherOpening.version {
                let lhs = opening.features, rhs = otherOpening.features
                openingScore = Double(lhs.intersection(rhs).count) / Double(max(1, lhs.union(rhs).count))
                if opening == otherOpening { dimensions.append("opening_state") }
            } else {
                // Public legacy fingerprints created without JSON import remain
                // usable, but do not silently claim the richer check was performed.
                hasLegacyOpening = true
                openingScore = candidate.openingState == other.openingState ? 1 : 0
                if openingScore == 1 { dimensions.append("opening_state_legacy") }
            }
            if candidate.serializedBoard == other.serializedBoard { dimensions.append("serialized_board") }
            func fraction(_ a: [Int], _ b: [Int]) -> Double {
                guard a.count == b.count else { return 0 }
                if a.isEmpty { return 1 }
                return Double(zip(a, b).filter { $0 == $1 }.count) / Double(a.count)
            }
            let weights = configuration.weights
            let score = fraction(candidate.regionGraph, other.regionGraph) * weights.regionGraph
                + fraction(candidate.regionSizeDistribution, other.regionSizeDistribution) * weights.regionSizeDistribution
                + fraction(candidate.answerPattern, other.answerPattern) * weights.answerPattern
                + openingScore * weights.openingState
            // These original rules are unconditional, including zero-weight
            // dimensions and threshold 1. Configuration cannot bypass them.
            let rejected = dimensions.contains("region_graph") || dimensions.contains("serialized_board")
                || dimensions.contains("answer_pattern") || score > configuration.threshold
            if rejected { accepted = false }
            if rejected || !dimensions.isEmpty {
                matches.append(SimilarityMatchReport(matchedGame: entry.game, matchedLevelID: entry.levelID,
                    similarityScore: score.isFinite ? score : 0, matchedDimensions: dimensions, threshold: configuration.threshold,
                    decision: rejected ? "Reject" : "Accept with recorded overlap", checkerVersion: checkerVersion))
            }
        }
        if hasLegacyOpening { exceptions.append("legacy_opening_features_not_upgraded") }
        let normalizedGame = game.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suppliedOtherProduct = corpus.contains {
            let name = $0.game.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !name.isEmpty && name != normalizedGame
        }
        let checkedOtherProduct = configuration.crossProductCorpusAvailable && suppliedOtherProduct
        // There is no approved human calibration evidence in this Demo. Merely
        // setting a flag or supplying another product name is not formal acceptance.
        return SimilarityReport(accepted: accepted, checkerVersion: checkerVersion, configurationVersion: configuration.version,
            comparedBoards: corpus.count, crossProductStatus: checkedOtherProduct ? "supplied_corpus_checked" : "missing_other_product_corpus",
            originalStrictAcceptance: false, exceptions: exceptions, matches: matches.sorted { $0.similarityScore > $1.similarityScore },
            configurationProvenance: configuration.provenance, configurationWeights: configuration.weights,
            openingFingerprintVersion: PuzzleOpeningFingerprint.currentVersion, calibrationStatus: "local_demo_uncalibrated")
    }
}
