import XCTest
import CryptoKit
@testable import CapydokuCore

final class GenerationAuditStoreTests: XCTestCase {
    private struct Envelope: Codable { var version: Int; var payload: Data; var sha256: String }
    private func directory() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("generation-audit-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    private func successfulBatch() throws -> GenerationPipelineResult {
        let result = try PuzzleGenerator.generateAudited(level: 1, seed: 222)
        XCTAssertNotNil(result.puzzle)
        return result
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func files(_ store: GenerationAuditStore, subdirectory: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: store.directory.appendingPathComponent(subdirectory), includingPropertiesForKeys: nil)
    }

    func testSuccessfulBatchColdReadRetainsEveryReportOutsidePlayerSave() throws {
        let dir = directory(), result = try successfulBatch(), board = try XCTUnwrap(result.puzzle)
        try GenerationAuditStore(directory: dir).record(result)
        let cold = GenerationAuditStore(directory: dir)
        XCTAssertEqual(try cold.latest(), result)
        XCTAssertEqual(try cold.report(for: board), result)
        let batches = try files(cold, subdirectory: "batches")
        XCTAssertEqual(batches.count, 1)
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: XCTUnwrap(batches.first)))
        XCTAssertEqual(envelope.sha256, digest(envelope.payload))
        XCTAssertEqual(batches.first?.lastPathComponent, digest(try encode(result)) + ".json")
        XCTAssertEqual(try JSONDecoder().decode(GenerationPipelineResult.self, from: envelope.payload), result)
        XCTAssertEqual(try files(cold, subdirectory: "boards").first?.lastPathComponent, digest(try encode(board)) + ".json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("progress.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["GenerationReports"])
    }

    func testFailedLatestAttemptRemainsFailureAndDoesNotEraseEarlierBoardReport() throws {
        let dir = directory(), success = try successfulBatch(), board = try XCTUnwrap(success.puzzle)
        let failure = try PuzzleGenerator.generateAudited(level: 1, seed: 222, maxAttempts: 99)
        let store = GenerationAuditStore(directory: dir)
        try store.record(success); try store.record(failure)
        let cold = GenerationAuditStore(directory: dir)
        XCTAssertEqual(try cold.latest(), failure)
        XCTAssertNil(try cold.latest()?.puzzle)
        XCTAssertEqual(try cold.latest()?.report.termination, "insufficient_candidate_budget")
        XCTAssertEqual(try cold.report(for: board), success)
        XCTAssertEqual(try files(cold, subdirectory: "boards").count, 1)
        XCTAssertEqual(try files(cold, subdirectory: "batches").count, 2)
    }

    func testSameSeedDistinctBatchResultsRemainImmutableAndExactRetryIsIdempotent() throws {
        let dir = directory(), store = GenerationAuditStore(directory: dir)
        let first = try PuzzleGenerator.generateAudited(level: 1, seed: 222, maxAttempts: 98)
        let second = try PuzzleGenerator.generateAudited(level: 1, seed: 222, maxAttempts: 99)
        XCTAssertEqual(first.report.metadata.candidateBatchID, second.report.metadata.candidateBatchID)
        try store.record(first)
        let firstURL = try XCTUnwrap(files(store, subdirectory: "batches").first), firstBytes = try Data(contentsOf: firstURL)
        try store.record(second); try store.record(first)
        XCTAssertEqual(try files(store, subdirectory: "batches").count, 2)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertEqual(try GenerationAuditStore(directory: dir).latest(), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("boards").path))
    }

    func testTimedOutPartialSelectionIsArchivedWithoutPublishingItsCandidate() throws {
        let dir = directory(), store = GenerationAuditStore(directory: dir)
        var interrupted = try successfulBatch()
        // Reproduce the generator's late timeout shape: selected-stage reports
        // may exist, but the batch returns no playable board when time expires.
        let board = try XCTUnwrap(interrupted.puzzle)
        interrupted.puzzle = nil; interrupted.report.termination = "time_budget_exceeded"
        try store.record(interrupted)
        let cold = GenerationAuditStore(directory: dir)
        XCTAssertEqual(try cold.latest(), interrupted)
        XCTAssertNil(try cold.latest()?.puzzle)
        XCTAssertNil(try cold.report(for: board))
        XCTAssertNotNil(try cold.latest()?.report.selectedSolverReport)
    }

    func testInvalidProfileAttemptPreservesItsOriginalRejections() throws {
        let dir = directory(), store = GenerationAuditStore(directory: dir)
        var target = DifficultyProfile.provisional(level: 1)
        target.candidateBatchSize = -1
        let rejected = try PuzzleGenerator.generateAudited(level: 1, seed: 222, profile: target)
        XCTAssertEqual(rejected.report.termination, "invalid_profile")
        XCTAssertNil(rejected.puzzle)
        try store.record(rejected)
        XCTAssertEqual(try GenerationAuditStore(directory: dir).latest(), rejected)
        XCTAssertTrue(try XCTUnwrap(store.latest()).report.rejectionReasons.keys.contains { $0.hasPrefix("profile:") })
    }

    func testMissingArchiveForOldBoardReturnsNilWithoutCreatingEvidence() throws {
        let dir = directory(), board = try XCTUnwrap(successfulBatch().puzzle)
        let store = GenerationAuditStore(directory: dir)
        XCTAssertNil(try store.latest()); XCTAssertNil(try store.report(for: board))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("existing player state".utf8).write(to: dir.appendingPathComponent("progress.json"))
        XCTAssertNil(try store.report(for: board))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("progress.json")), Data("existing player state".utf8))
    }

    func testCorruptLatestIsRejectedAndNeverOverwrittenByANewAttempt() throws {
        let dir = directory(), store = GenerationAuditStore(directory: dir), result = try successfulBatch()
        try store.record(result)
        let latest = store.directory.appendingPathComponent("latest.json"), corrupt = Data("damaged audit evidence".utf8)
        try corrupt.write(to: latest)
        XCTAssertThrowsError(try GenerationAuditStore(directory: dir).latest())
        let retry = try PuzzleGenerator.generateAudited(level: 1, seed: 222, maxAttempts: 99)
        XCTAssertThrowsError(try store.record(retry))
        XCTAssertEqual(try Data(contentsOf: latest), corrupt)
        XCTAssertEqual(try files(store, subdirectory: "batches").count, 1)
        XCTAssertEqual(try store.report(for: XCTUnwrap(result.puzzle)), result)
    }

    func testCorruptOrMissingImmutableBatchCannotBeHiddenByValidIndexes() throws {
        for deleteBatch in [false, true] {
            let dir = directory(), store = GenerationAuditStore(directory: dir), result = try successfulBatch()
            try store.record(result)
            let batch = try XCTUnwrap(files(store, subdirectory: "batches").first)
            if deleteBatch { try FileManager.default.removeItem(at: batch) }
            else { try Data("broken archive".utf8).write(to: batch) }
            XCTAssertThrowsError(try store.latest())
            XCTAssertThrowsError(try store.report(for: XCTUnwrap(result.puzzle)))
            XCTAssertThrowsError(try store.record(result))
            if !deleteBatch { XCTAssertEqual(try Data(contentsOf: batch), Data("broken archive".utf8)) }
        }
    }

    func testBoardLookupRejectsAValidButDifferentPuzzleAndPreservesIndex() throws {
        let dir = directory(), store = GenerationAuditStore(directory: dir), result = try successfulBatch()
        try store.record(result)
        var wrong = try XCTUnwrap(result.puzzle); wrong.id += 1
        let path = store.directory.appendingPathComponent("boards").appendingPathComponent(digest(try encode(wrong)) + ".json")
        let bytes = try Data(contentsOf: store.directory.appendingPathComponent("latest.json"))
        try bytes.write(to: path)
        XCTAssertThrowsError(try store.report(for: wrong))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertEqual(try store.report(for: XCTUnwrap(result.puzzle)), result)
    }

    func testMetadataCountsAndSuccessClaimsAreValidatedBeforeWriting() throws {
        let dir = directory(), store = GenerationAuditStore(directory: dir), result = try successfulBatch()
        var changedSeed = result; changedSeed.report.metadata.generationSeed += 1
        var changedCount = result; changedCount.report.solverPassed = result.report.generatedCandidates + 1
        var failedWithPuzzle = result; failedWithPuzzle.report.termination = "time_budget_exceeded"
        var successWithoutPuzzle = result; successWithoutPuzzle.puzzle = nil
        var rejectedStage = result; rejectedStage.report.selectedDifficultyReport?.accepted = false
        var wrongBoard = result; wrongBoard.puzzle?.regions[0] = 999
        for invalid in [changedSeed, changedCount, failedWithPuzzle, successWithoutPuzzle, rejectedStage, wrongBoard] {
            XCTAssertThrowsError(try store.record(invalid))
            XCTAssertNil(try store.latest())
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    func testChecksumAndInternallyInvalidRechecksummedPayloadAreRejectedOnRead() throws {
        for repairChecksum in [false, true] {
            let dir = directory(), store = GenerationAuditStore(directory: dir), result = try successfulBatch()
            try store.record(result)
            let path = store.directory.appendingPathComponent("latest.json")
            var envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: path))
            var tampered = result; tampered.report.similarityPassed = tampered.report.difficultyPassed + 1
            envelope.payload = try encode(tampered)
            if repairChecksum { envelope.sha256 = digest(envelope.payload) }
            let bytes = try encode(envelope)
            try bytes.write(to: path)
            XCTAssertThrowsError(try store.latest())
            XCTAssertThrowsError(try store.record(result))
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }

    func testFileSizeLimitAndActualFilesystemWriteFailureCannotClaimSuccess() throws {
        let dir = directory(), store = GenerationAuditStore(directory: dir)
        let result = try PuzzleGenerator.generateAudited(level: 1, seed: 222, maxAttempts: 99)
        try Data("not a directory".utf8).write(to: dir)
        XCTAssertThrowsError(try store.record(result))
        XCTAssertEqual(try Data(contentsOf: dir), Data("not a directory".utf8))
        try FileManager.default.removeItem(at: dir)
        try store.record(result)
        XCTAssertEqual(try store.latest(), result)
        let path = store.directory.appendingPathComponent("latest.json")
        let oversized = Data(repeating: 32, count: 4 * 1_024 * 1_024 + 1)
        try oversized.write(to: path)
        XCTAssertThrowsError(try store.latest())
        XCTAssertThrowsError(try store.record(result))
        XCTAssertEqual(try Data(contentsOf: path).count, oversized.count)
        let newRoot = directory(), newStore = GenerationAuditStore(directory: newRoot)
        var oversizedReport = result; oversizedReport.report.referenceAcceptance = String(repeating: "x", count: oversized.count)
        XCTAssertThrowsError(try newStore.record(oversizedReport))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newStore.directory.path))
    }
}
