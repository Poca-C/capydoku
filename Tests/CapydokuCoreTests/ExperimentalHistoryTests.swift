import XCTest
import CryptoKit
@testable import CapydokuCore

final class ExperimentalHistoryTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func board(_ level: Int) throws -> Puzzle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let boards = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent("Resources/levels.json")))
        var puzzle = boards[level == 151 ? 0 : 1]; puzzle.id = level
        return puzzle
    }
    private func legacyCache(_ puzzle: Puzzle, directory: URL) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(puzzle)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let cache = directory.appendingPathComponent("BoardCache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let url = cache.appendingPathComponent(digest + ".json")
        try data.write(to: url); return url
    }

    func testColdHistoryStillRejectsBoardAfterItsCacheFileIsDeleted() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let puzzle = try board(151), cache = try legacyCache(puzzle, directory: dir)
        let store = ExperimentalPuzzleHistoryStore(directory: dir)
        let checkpoint = try store.record(puzzle, checkpoint: nil, requiredLevels: [151])
        try FileManager.default.removeItem(at: cache)
        let cold = try ExperimentalPuzzleHistoryStore(directory: dir).load(checkpoint: checkpoint, requiredLevels: [151])
        XCTAssertEqual(cold.corpus.count, 1)
        XCTAssertTrue(cold.importedLegacyCache)
        XCTAssertFalse(PuzzleSimilarity.evaluate(puzzle, corpus: cold.corpus, configuration: .strict).accepted)
    }

    func testBackupRecoversSameCommittedHistoryAndRepeatedRecordDoesNotGrow() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExperimentalPuzzleHistoryStore(directory: dir), puzzle = try board(151)
        let checkpoint = try store.record(puzzle, checkpoint: nil, requiredLevels: [])
        try Data("broken".utf8).write(to: store.primaryURL)
        XCTAssertEqual(try store.load(checkpoint: checkpoint, requiredLevels: [151]).checkpoint, checkpoint)
        XCTAssertEqual(try store.record(puzzle, checkpoint: checkpoint, requiredLevels: [151]), checkpoint)
        XCTAssertEqual(try Data(contentsOf: store.primaryURL), try Data(contentsOf: store.backupURL))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("experimental-history.preserved-") })
    }

    func testOlderValidBackupCannotSilentlyDropCommittedHistory() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExperimentalPuzzleHistoryStore(directory: dir)
        let first = try store.record(board(151), checkpoint: nil, requiredLevels: [])
        let older = try Data(contentsOf: store.primaryURL)
        let second = try store.record(board(152), checkpoint: first, requiredLevels: [151])
        try Data("broken".utf8).write(to: store.primaryURL)
        try older.write(to: store.backupURL)
        XCTAssertThrowsError(try store.load(checkpoint: second, requiredLevels: [151, 152]))
        XCTAssertEqual(try Data(contentsOf: store.backupURL), older)
    }

    func testMissingBothHistoryFilesDoesNotRemigrateWhenCheckpointExists() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let puzzle = try board(151); _ = try legacyCache(puzzle, directory: dir)
        let store = ExperimentalPuzzleHistoryStore(directory: dir)
        let checkpoint = try store.record(puzzle, checkpoint: nil, requiredLevels: [151])
        try FileManager.default.removeItem(at: store.primaryURL)
        try FileManager.default.removeItem(at: store.backupURL)
        XCTAssertThrowsError(try store.load(checkpoint: checkpoint, requiredLevels: [151]))
    }

    func testLegacyMissingKnownLevelOrInvalidBytesNeverShrinkHistory() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExperimentalPuzzleHistoryStore(directory: dir)
        XCTAssertThrowsError(try store.load(checkpoint: nil, requiredLevels: [151]))
        let cache = try legacyCache(board(151), directory: dir)
        XCTAssertThrowsError(try store.load(checkpoint: nil, requiredLevels: [151, 152]))
        try Data("broken".utf8).write(to: cache)
        XCTAssertThrowsError(try store.load(checkpoint: nil, requiredLevels: [151]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.primaryURL.path))
    }

    func testLegacyWrongFilenameAndUnreadableDirectoryAreErrors() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try legacyCache(board(151), directory: dir)
        try FileManager.default.moveItem(at: cache, to: cache.deletingLastPathComponent().appendingPathComponent("wrong.json"))
        let store = ExperimentalPuzzleHistoryStore(directory: dir)
        XCTAssertThrowsError(try store.load(checkpoint: nil, requiredLevels: []))
        try FileManager.default.removeItem(at: cache.deletingLastPathComponent())
        try Data("not a directory".utf8).write(to: cache.deletingLastPathComponent())
        XCTAssertThrowsError(try store.load(checkpoint: nil, requiredLevels: []))
    }

    func testSameLevelVariantsRemainInHistoryAndChainDetectsDifferentPrefix() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExperimentalPuzzleHistoryStore(directory: dir)
        let original = try board(151); var variant = try board(152); variant.id = 151
        let first = try store.record(original, checkpoint: nil, requiredLevels: [])
        let second = try store.record(variant, checkpoint: first, requiredLevels: [151])
        let snapshot = try store.load(checkpoint: second, requiredLevels: [151])
        XCTAssertEqual(snapshot.corpus.count, 2)
        for puzzle in [original, variant] { XCTAssertFalse(PuzzleSimilarity.evaluate(puzzle, corpus: snapshot.corpus, configuration: .strict).accepted) }
        let wrong = ExperimentalHistoryCheckpoint(count: 1, chainSHA256: second.chainSHA256)
        XCTAssertThrowsError(try store.load(checkpoint: wrong, requiredLevels: [151]))
    }

    func testWriteFailureDoesNotClaimCommitAndCheckpointRoundTripsWithoutBoardData() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExperimentalPuzzleHistoryStore(directory: dir)
        let checkpoint = try store.record(board(151), checkpoint: nil, requiredLevels: [])
        var progress = PlayerProgress(); progress.experimentalHistoryCheckpoint = checkpoint
        let bytes = try JSONEncoder().encode(progress)
        XCTAssertEqual(try JSONDecoder().decode(PlayerProgress.self, from: bytes).experimentalHistoryCheckpoint, checkpoint)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("regionGraph"))
        try FileManager.default.removeItem(at: store.backupURL)
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.record(board(152), checkpoint: checkpoint, requiredLevels: [151]))
        // A partial append is an additional conservative reservation, never a loss.
        let recovered = try store.load(checkpoint: checkpoint, requiredLevels: [151])
        XCTAssertEqual(recovered.corpus.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(PlayerProgress.self, from: bytes), progress)
    }
}
