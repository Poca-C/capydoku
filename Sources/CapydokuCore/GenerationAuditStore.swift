import Foundation
import CryptoKit

/// Original [190–194]: complete local generation evidence, independent of player
/// saves. Recording is a prerequisite for publishing a newly generated board.
public final class GenerationAuditStore: @unchecked Sendable {
    public enum AuditError: LocalizedError {
        case invalidReport, corruptArchive, oversizedFile
        public var errorDescription: String? {
            switch self {
            case .invalidReport: return "The generation report is internally inconsistent. The new board has not been released."
            case .corruptArchive: return "The generation report archive could not be verified. Existing evidence is preserved."
            case .oversizedFile: return "The generation report exceeds the local archive size limit."
            }
        }
    }
    private struct Envelope: Codable {
        var version: Int
        var payload: Data
        var sha256: String
    }
    /// The caller supplies its application storage root, not the player-save file.
    public let directory: URL
    private static let maximumBytes = 4 * 1_024 * 1_024
    // Serialize writers even when a cold reader/store is recreated in the same
    // process. No network, clock rewrite, or regeneration is involved in reads.
    private static let lock = NSRecursiveLock()
    private let manager = FileManager.default
    public init(directory: URL) { self.directory = directory.appendingPathComponent("GenerationReports", isDirectory: true) }

    public func record(_ result: GenerationPipelineResult) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try Self.validate(result)
        let payload = try Self.encode(result)
        guard payload.count <= Self.maximumBytes else { throw AuditError.oversizedFile }
        let hash = Self.digest(payload)
        let bytes = try Self.encode(Envelope(version: 1, payload: payload, sha256: hash))
        guard bytes.count <= Self.maximumBytes else { throw AuditError.oversizedFile }
        let batch = batchURL(hash)
        let board = try result.puzzle.map { try boardURL($0) }
        // A damaged index is evidence, not permission to replace it silently.
        _ = try latest()
        if let puzzle = result.puzzle { _ = try report(for: puzzle) }
        if manager.fileExists(atPath: batch.path) {
            guard try read(batch, expectedHash: hash).payload == payload else { throw AuditError.corruptArchive }
        }
        try manager.createDirectory(at: directory.appendingPathComponent("batches"), withIntermediateDirectories: true)
        if board != nil { try manager.createDirectory(at: directory.appendingPathComponent("boards"), withIntermediateDirectories: true) }
        // Full-content addressing keeps every distinct result, including failures
        // and retries using the same seed. An identical delivery is idempotent.
        if !manager.fileExists(atPath: batch.path) { try bytes.write(to: batch, options: .atomic) }
        if let board { try bytes.write(to: board, options: .atomic) }
        try bytes.write(to: latestURL, options: .atomic)
    }

    /// Most recently committed attempt, which may be a failure with no puzzle.
    public func latest() throws -> GenerationPipelineResult? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try readIndex(latestURL)
    }

    /// No report for an old board is normal. Never regenerate to invent evidence.
    public func report(for puzzle: Puzzle) throws -> GenerationPipelineResult? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let result = try readIndex(boardURL(puzzle)) else { return nil }
        guard result.puzzle == puzzle else { throw AuditError.corruptArchive }
        return result
    }

    private var latestURL: URL { directory.appendingPathComponent("latest.json") }
    private func batchURL(_ hash: String) -> URL { directory.appendingPathComponent("batches").appendingPathComponent(hash + ".json") }
    private func boardURL(_ puzzle: Puzzle) throws -> URL {
        directory.appendingPathComponent("boards").appendingPathComponent(Self.digest(try Self.encode(puzzle)) + ".json")
    }
    private func readIndex(_ url: URL) throws -> GenerationPipelineResult? {
        if manager.fileExists(atPath: directory.path) {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw AuditError.corruptArchive }
        }
        guard manager.fileExists(atPath: url.path) else { return nil }
        let index = try read(url)
        let archived = try read(batchURL(index.sha256), expectedHash: index.sha256)
        guard index.payload == archived.payload else { throw AuditError.corruptArchive }
        return try JSONDecoder().decode(GenerationPipelineResult.self, from: index.payload)
    }
    private func read(_ url: URL, expectedHash: String? = nil) throws -> Envelope {
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw AuditError.corruptArchive }
        guard let size = properties.fileSize, size <= Self.maximumBytes else { throw AuditError.oversizedFile }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= Self.maximumBytes else { throw AuditError.oversizedFile }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard envelope.version == 1, Self.digest(envelope.payload) == envelope.sha256,
                  expectedHash == nil || envelope.sha256 == expectedHash else { throw AuditError.corruptArchive }
            let result = try JSONDecoder().decode(GenerationPipelineResult.self, from: envelope.payload)
            try Self.validate(result)
            return envelope
        } catch let error as AuditError { throw error }
        catch { throw AuditError.corruptArchive }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func validate(_ result: GenerationPipelineResult) throws {
        let report = result.report, metadata = report.metadata
        let stages = [report.generatedCandidates, report.solverPassed, report.difficultyPassed, report.similarityPassed]
        let selected = [report.selectedSolverReport != nil, report.selectedDifficultyReport != nil, report.selectedSimilarityReport != nil]
        guard !metadata.productNamespace.isEmpty, !metadata.generatorVersion.isEmpty,
              metadata.profileVersion == report.target.profileVersion,
              metadata.candidateBatchID == "\(metadata.generatorVersion):\(metadata.profileVersion):\(metadata.productNamespace):\(metadata.generationSeed)",
              !report.termination.isEmpty, !report.referenceAcceptance.isEmpty,
              ISO8601DateFormatter().date(from: report.createdAtUTC) != nil,
              report.elapsedMilliseconds >= 0, report.requestedCandidates <= 500,
              report.generatedCandidates <= max(0, report.requestedCandidates),
              stages.allSatisfy({ (0...500).contains($0) }),
              zip(stages, stages.dropFirst()).allSatisfy({ $0 >= $1 }),
              report.rejectionReasons.allSatisfy({ !$0.key.isEmpty && $0.value > 0 }),
              selected.allSatisfy({ $0 == (report.similarityPassed > 0) }) else { throw AuditError.invalidReport }
        if report.termination != "invalid_profile" {
            guard report.target.validationErrors.isEmpty, report.requestedCandidates > 0 else { throw AuditError.invalidReport }
        }
        if report.similarityPassed == 0 {
            guard metadata.candidateIndex == -1, metadata.candidateSeed == 0 else { throw AuditError.invalidReport }
        } else {
            guard (0..<report.generatedCandidates).contains(metadata.candidateIndex),
                  let solver = report.selectedSolverReport, solver.hardChecksPassed,
                  let difficulty = report.selectedDifficultyReport, difficulty.accepted, difficulty.rejectionReasons.isEmpty,
                  difficulty.targetProvenance == report.target.provenance,
                  difficulty.normalizedTargetDistance.isFinite, difficulty.normalizedTargetDistance >= 0,
                  difficulty.measurements.values.allSatisfy(\.isFinite),
                  let similarity = report.selectedSimilarityReport, similarity.accepted,
                  similarity.comparedBoards >= similarity.matches.count,
                  !similarity.matches.contains(where: { $0.decision == "Reject" }),
                  !similarity.originalStrictAcceptance || similarity.crossProductStatus == "supplied_corpus_checked"
            else { throw AuditError.invalidReport }
        }
        guard let puzzle = result.puzzle else {
            guard report.termination != "selected_best_match" else { throw AuditError.invalidReport }
            return // A timed-out batch may retain a partial best candidate report, never a playable puzzle.
        }
        guard report.termination == "selected_best_match", (100...500).contains(report.requestedCandidates),
              report.generatedCandidates == report.requestedCandidates, report.similarityPassed > 0,
              puzzle.id == report.target.levelID, [4, 6, 8, 10].contains(puzzle.size),
              puzzle.seed == metadata.generationSeed, puzzle.generatorVersion == metadata.generatorVersion,
              puzzle.generationMetadata == metadata, puzzle.difficulty == report.target.difficultyBand.rawValue,
              report.selectedDifficultyReport?.measurements["board_size"] == Double(puzzle.size),
              report.selectedDifficultyReport?.measurements["region_count"] == Double(Set(puzzle.regions).count),
              PuzzleSolver.validate(puzzle).valid else { throw AuditError.invalidReport }
    }
}
