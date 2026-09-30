import Foundation

public struct PuzzleGenerationMetadata: Codable, Equatable, Sendable {
    public var productNamespace: String
    public var generationSeed: UInt64
    public var candidateSeed: UInt64
    public var candidateBatchID: String
    public var candidateIndex: Int
    public var generatorVersion: String
    public var profileVersion: String
}

public struct GenerationPipelineReport: Codable, Equatable, Sendable {
    public var createdAtUTC = ISO8601DateFormatter().string(from: Date())
    public var target: DifficultyProfile
    public var metadata: PuzzleGenerationMetadata
    public var requestedCandidates: Int
    public var generatedCandidates: Int
    public var solverPassed: Int
    public var difficultyPassed: Int
    public var similarityPassed: Int
    public var rejectionReasons: [String: Int]
    public var termination: String
    public var elapsedMilliseconds: Int
    public var selectedSolverReport: DifficultySolverReport?
    public var selectedDifficultyReport: DifficultyFilterReport?
    public var selectedSimilarityReport: SimilarityReport?
    public var similarityRejectionExamples: [SimilarityReport]?
    public var referenceAcceptance = "unverified: frozen Pawdoku profiles, calibrated player metrics, and cross-product corpus are required"
}

public struct GenerationPipelineResult: Codable, Equatable, Sendable {
    public var puzzle: Puzzle?
    public var report: GenerationPipelineReport
}

extension PuzzleGenerator {
    /// Deterministic candidate batch. Budget expiry returns no board; callers may retry with the same seed.
    /// Selects after all requested candidates have been evaluated, never the first legal board.
    public static func generateAudited(level: Int, seed: UInt64? = nil, profile: DifficultyProfile? = nil,
        productNamespace: String = "CapyDoku", corpus: [SimilarityCorpusEntry] = [],
        similarityConfiguration: SimilarityConfiguration = .strict,
        maxAttempts: Int = 500, timeBudgetMilliseconds: Int = 8_000) throws -> GenerationPipelineResult {
        guard level > 0, maxAttempts > 0, timeBudgetMilliseconds > 0 else { throw PuzzleGenerationError.invalidLevel }
        let target = profile ?? .provisional(level: level)
        let requested = min(500, min(maxAttempts, target.candidateBatchSize))
        let baseSeed = seed ?? (UInt64(level) &* 0x9E3779B97F4A7C15 &+ 0xCA9D0C0)
        let started = ProcessInfo.processInfo.systemUptime
        let budget = min(generationTimeBudget * 1_000, Double(timeBudgetMilliseconds))
        func elapsed() -> Int { Int((ProcessInfo.processInfo.systemUptime - started) * 1_000) }
        let namespacedSeed = stableSeed(productNamespace, seed: baseSeed)
        var report = GenerationPipelineReport(target: target,
            metadata: PuzzleGenerationMetadata(productNamespace: productNamespace, generationSeed: baseSeed,
                candidateSeed: 0, candidateBatchID: "\(version):\(target.profileVersion):\(productNamespace):\(baseSeed)",
                candidateIndex: -1, generatorVersion: version, profileVersion: target.profileVersion),
            requestedCandidates: requested, generatedCandidates: 0, solverPassed: 0, difficultyPassed: 0,
            similarityPassed: 0, rejectionReasons: [:], termination: "no_candidate_matched", elapsedMilliseconds: 0)
        guard target.levelID == level, target.validationErrors.isEmpty else {
            for reason in target.validationErrors { report.rejectionReasons["profile:" + reason, default: 0] += 1 }
            if target.levelID != level { report.rejectionReasons["profile:level_mismatch"] = 1 }
            report.termination = "invalid_profile"
            return .init(puzzle: nil, report: report)
        }
        guard requested >= 100 else {
            report.rejectionReasons["budget:minimum_100_candidates_required"] = 1
            report.termination = "insufficient_candidate_budget"
            return .init(puzzle: nil, report: report)
        }
        let sizes = [4, 6, 8, 10].filter { target.boardSizeCurveTarget.contains(Double($0)) }
        guard !sizes.isEmpty else { report.termination = "unsupported_size_range"; return .init(puzzle: nil, report: report) }
        var best: Puzzle?, bestDistance = Double.infinity
        for index in 0..<requested {
            let remaining = Int(budget) - elapsed()
            guard remaining > 0 else {
                report.termination = "time_budget_exceeded"; report.elapsedMilliseconds = elapsed()
                return .init(puzzle: nil, report: report)
            }
            let candidateSeed = namespacedSeed &+ UInt64(index) &* 0xD1B54A32D192ED03
            report.generatedCandidates += 1
            let candidate: Puzzle
            do {
                candidate = try generateCandidate(level: level, seed: candidateSeed, size: sizes[index % sizes.count],
                                                   variation: index, timeBudgetMilliseconds: remaining)
            } catch PuzzleGenerationError.timeBudgetExceeded {
                report.termination = "time_budget_exceeded"; report.elapsedMilliseconds = elapsed()
                return .init(puzzle: nil, report: report)
            } catch {
                report.rejectionReasons["solver:invalid_or_non_unique", default: 0] += 1
                continue
            }
            let solver = DifficultyEvaluator.evaluate(candidate)
            guard solver.hardChecksPassed else { report.rejectionReasons["solver:hard_checks", default: 0] += 1; continue }
            report.solverPassed += 1
            let difficulty = DifficultyFilter.evaluate(puzzle: candidate, solver: solver, target: target)
            guard difficulty.accepted else {
                for reason in difficulty.rejectionReasons { report.rejectionReasons["difficulty:" + reason, default: 0] += 1 }
                continue
            }
            report.difficultyPassed += 1
            let similarity = PuzzleSimilarity.evaluate(candidate, game: productNamespace, corpus: corpus, configuration: similarityConfiguration)
            guard similarity.accepted else {
                report.rejectionReasons["similarity:rejected", default: 0] += 1
                let matched = Set(similarity.matches.filter { $0.decision == "Reject" }.flatMap(\.matchedDimensions))
                for dimension in matched { report.rejectionReasons["similarity:" + dimension, default: 0] += 1 }
                if (report.similarityRejectionExamples?.count ?? 0) < 2 {
                    if report.similarityRejectionExamples == nil { report.similarityRejectionExamples = [] }
                    report.similarityRejectionExamples?.append(similarity)
                }
                continue
            }
            report.similarityPassed += 1
            let distance = difficulty.normalizedTargetDistance
            if distance < bestDistance {
                bestDistance = distance; best = candidate
                report.metadata.candidateIndex = index; report.metadata.candidateSeed = candidateSeed
                report.selectedSolverReport = solver; report.selectedDifficultyReport = difficulty; report.selectedSimilarityReport = similarity
            }
        }
        report.elapsedMilliseconds = elapsed()
        if report.elapsedMilliseconds >= Int(budget) {
            report.termination = "time_budget_exceeded"; return .init(puzzle: nil, report: report)
        }
        if var selected = best {
            selected.seed = baseSeed
            selected.difficulty = target.difficultyBand.rawValue
            selected.generationMetadata = report.metadata
            report.termination = "selected_best_match"
            return .init(puzzle: selected, report: report)
        }
        return .init(puzzle: nil, report: report)
    }

    /// Rebuild the selected candidate directly from its production metadata. This is
    /// independent of later additions to the similarity corpus and does not read its map/answer.
    public static func rebuild(_ original: Puzzle, timeBudgetMilliseconds: Int = 8_000) throws -> Puzzle {
        guard let metadata = original.generationMetadata, metadata.generatorVersion == version,
              metadata.candidateIndex >= 0 else { throw PuzzleGenerationError.invalidLevel }
        var rebuilt = try generateCandidate(level: original.id, seed: metadata.candidateSeed, size: original.size,
            variation: metadata.candidateIndex, timeBudgetMilliseconds: timeBudgetMilliseconds)
        rebuilt.seed = metadata.generationSeed
        rebuilt.difficulty = original.difficulty
        rebuilt.generationMetadata = metadata
        return rebuilt
    }

    private static func stableSeed(_ namespace: String, seed: UInt64) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in namespace.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return seed ^ hash
    }
}
