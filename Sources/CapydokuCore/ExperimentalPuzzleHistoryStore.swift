import Foundation
import CryptoKit

/// A small commitment in player state; concrete board/fingerprint data remains
/// outside the player save (Original [404], authorized 151+ Demo experiment).
public struct ExperimentalHistoryCheckpoint: Codable, Equatable, Sendable {
    public let count: Int
    public let chainSHA256: String
}

/// Append-only, checksummed history used by the runtime generator, including
/// previously played variants of the same level. Never silently drops a record.
public final class ExperimentalPuzzleHistoryStore: @unchecked Sendable {
    public struct Snapshot: Sendable {
        fileprivate var records: [Record]
        public let importedLegacyCache: Bool
        public var corpus: [SimilarityCorpusEntry] { records.map(\.entry) }
        public var checkpoint: ExperimentalHistoryCheckpoint { Self.checkpoint(records) }
        fileprivate static func checkpoint(_ records: [Record]) -> ExperimentalHistoryCheckpoint {
            var chain = ExperimentalPuzzleHistoryStore.digest(Data("capydoku-history-v1".utf8))
            for record in records { chain = ExperimentalPuzzleHistoryStore.digest(Data((chain + ":" + record.boardSHA256).utf8)) }
            return .init(count: records.count, chainSHA256: chain)
        }
    }
    fileprivate struct Record: Codable, Equatable, Sendable {
        var boardSHA256: String
        var entry: SimilarityCorpusEntry
    }
    private struct Payload: Codable { var records: [Record]; var importedLegacyCache: Bool }
    private struct Envelope: Codable { var version: Int; var payload: Data; var sha256: String }
    public enum HistoryError: LocalizedError {
        case incomplete
        public var errorDescription: String? {
            "Experimental level history could not be verified. New level generation is paused; your current board is unchanged."
        }
    }
    public let directory: URL
    public var primaryURL: URL { directory.appendingPathComponent("experimental-history.json") }
    public var backupURL: URL { directory.appendingPathComponent("experimental-history.backup.json") }
    private let lock = NSRecursiveLock()
    private let manager = FileManager.default
    private static let maximumBytes = 64_000_000
    public init(directory: URL) { self.directory = directory }

    /// Check the saved commitment before using any history. Legacy migration can
    /// account only for files and levels still evidenced by the old save; it is
    /// explicitly labelled and cannot prove that older variants were never lost.
    public func load(checkpoint: ExperimentalHistoryCheckpoint?, requiredLevels: Set<Int>) throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let existing = [primaryURL, backupURL].filter { manager.fileExists(atPath: $0.path) }
        let valid = existing.compactMap { try? read($0) }
        var snapshot: Snapshot
        if let first = valid.first {
            snapshot = first
            for other in valid.dropFirst() {
                let shorter = min(snapshot.records.count, other.records.count)
                guard Array(snapshot.records.prefix(shorter)) == Array(other.records.prefix(shorter)) else { throw HistoryError.incomplete }
                if other.records.count > snapshot.records.count { snapshot = other }
            }
        } else {
            guard existing.isEmpty, checkpoint == nil else { throw HistoryError.incomplete }
            snapshot = try legacySnapshot()
        }
        if let checkpoint {
            guard checkpoint.count >= 0, checkpoint.count <= snapshot.records.count,
                  Snapshot.checkpoint(Array(snapshot.records.prefix(checkpoint.count))) == checkpoint else { throw HistoryError.incomplete }
        }
        guard requiredLevels.isSubset(of: Set(snapshot.records.map { $0.entry.levelID })) else { throw HistoryError.incomplete }
        return snapshot
    }

    /// Commit history before publishing a generated board. A failed append may
    /// conservatively reserve an unused board, but cannot forget a played board.
    public func record(_ puzzle: Puzzle, checkpoint: ExperimentalHistoryCheckpoint?, requiredLevels: Set<Int>) throws -> ExperimentalHistoryCheckpoint {
        lock.lock(); defer { lock.unlock() }
        var snapshot = try load(checkpoint: checkpoint, requiredLevels: requiredLevels)
        let record = try Self.record(puzzle)
        if !snapshot.records.contains(where: { $0.boardSHA256 == record.boardSHA256 }) {
            guard snapshot.records.count < 100_000 else { throw HistoryError.incomplete }
            snapshot.records.append(record)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(Payload(records: snapshot.records, importedLegacyCache: snapshot.importedLegacyCache))
        guard payload.count < Self.maximumBytes else { throw HistoryError.incomplete }
        let bytes = try encoder.encode(Envelope(version: 1, payload: payload, sha256: Self.digest(payload)))
        guard bytes.count < Self.maximumBytes else { throw HistoryError.incomplete }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Each successful commit keeps two copies of the full current history.
        // A partial write leaves either the old valid prefix or the new superset.
        for url in [primaryURL, backupURL] {
            if manager.fileExists(atPath: url.path), (try? read(url)) == nil {
                let old = try Data(contentsOf: url)
                let preserved = directory.appendingPathComponent("experimental-history.preserved-" + Self.digest(old) + ".json")
                if !manager.fileExists(atPath: preserved.path) { try old.write(to: preserved, options: .atomic) }
            }
            try bytes.write(to: url, options: .atomic)
        }
        return snapshot.checkpoint
    }

    private func read(_ url: URL) throws -> Snapshot {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Self.maximumBytes
        guard size < Self.maximumBytes else { throw HistoryError.incomplete }
        let bytes = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.version == 1, Self.digest(envelope.payload) == envelope.sha256 else { throw HistoryError.incomplete }
        let payload = try JSONDecoder().decode(Payload.self, from: envelope.payload)
        guard payload.records.count <= 100_000,
              Set(payload.records.map(\.boardSHA256)).count == payload.records.count else { throw HistoryError.incomplete }
        // Normalize verified legacy fingerprints before comparing primary/backup
        // prefixes. The saved board hashes and player checkpoint stay unchanged.
        let upgraded = payload.records.compactMap(Self.verifiedRecord)
        guard upgraded.count == payload.records.count else { throw HistoryError.incomplete }
        return Snapshot(records: upgraded, importedLegacyCache: payload.importedLegacyCache)
    }

    private func legacySnapshot() throws -> Snapshot {
        let cache = directory.appendingPathComponent("BoardCache", isDirectory: true)
        let files: [URL]
        do { files = try manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey]) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return Snapshot(records: [], importedLegacyCache: false)
        }
        var records: [Record] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Self.maximumBytes
            guard size < 1_000_000 else { throw HistoryError.incomplete }
            let data = try Data(contentsOf: file)
            guard file.deletingPathExtension().lastPathComponent == Self.digest(data) else { throw HistoryError.incomplete }
            let puzzle = try JSONDecoder().decode(Puzzle.self, from: data)
            let record = try Self.record(puzzle)
            guard record.boardSHA256 == Self.digest(data) else { throw HistoryError.incomplete }
            records.append(record)
        }
        return Snapshot(records: records, importedLegacyCache: !records.isEmpty)
    }

    private static func record(_ puzzle: Puzzle) throws -> Record {
        guard (151...100_000).contains(puzzle.id), [4, 6, 8, 10].contains(puzzle.size),
              PuzzleSolver.validate(puzzle).valid else { throw HistoryError.incomplete }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Record(boardSHA256: digest(try encoder.encode(puzzle)), entry: SimilarityCorpusEntry(game: "CapyDoku", puzzle: puzzle))
    }

    private static func verifiedRecord(_ record: Record) -> Record? {
        let entry = record.entry, f = entry.fingerprint, n = f.gridSize
        guard record.boardSHA256.count == 64, record.boardSHA256.allSatisfy({ $0.isHexDigit }),
              entry.game == "CapyDoku", (151...100_000).contains(entry.levelID), [4, 6, 8, 10].contains(n),
              f.regionGraph.count == n * n, f.regionGraph.allSatisfy({ (0..<n).contains($0) }),
              Set(f.regionGraph).count == n, f.answerPattern.count == n,
              f.answerPattern.allSatisfy({ (0..<(n * n)).contains($0) }) else { return nil }
        let puzzle = Puzzle(id: entry.levelID, size: n, regions: f.regionGraph, solution: f.answerPattern, seed: 0, generatorVersion: "history", difficulty: "history")
        let current = PuzzleFingerprint(puzzle: puzzle)
        guard current.matchesLegacyFields(of: f),
              f.openingDetails == nil || f.openingDetails == current.openingDetails,
              Set(f.answerPattern.map { $0 / n }).count == n,
              Set(f.answerPattern.map { $0 % n }).count == n,
              Set(f.answerPattern.map { f.regionGraph[$0] }).count == n,
              zip(f.answerPattern, f.answerPattern.dropFirst()).allSatisfy({ abs($0 % n - $1 % n) > 1 }) else { return nil }
        var result = record
        result.entry.fingerprint = current
        return result
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
