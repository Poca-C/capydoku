import XCTest
import CapydokuCore
@testable import Capydoku

private final class GenerationHistoryIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}

/// Real AppModel generation and local files, without analytics consent, fake
/// generator output, or a preassembled similarity corpus. A fresh model stands
/// in for the app-process state loss; the separate UI test terminates the app.
final class ExperimentalGenerationHistoryTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("generation-history-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor private func model(_ directory: URL) -> AppModel {
        let feedback = FeedbackPlayer(manifest: .silent, resourceResolver: { _ in nil },
                                      playerFactory: { _ in nil }, sessionControl: { _ in true }, observeSystem: false)
        let app = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false,
                           analyticsIdentityStore: GenerationHistoryIdentity(), feedbackPlayer: feedback)
        app.progress.tutorialCompleted = true
        return app
    }

    @MainActor private func finishGeneration(_ app: AppModel, level: Int,
                                             file: StaticString = #filePath, line: UInt = #line) async throws {
        app.errorMessage = nil
        app.start(level: level)
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while app.loading && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(app.loading, "Generation must terminate within its bounded test wait.", file: file, line: line)
        app.flushPendingSaves()
    }

    @MainActor private func generate(_ app: AppModel, level: Int, expectedHistory: Int,
                                    file: StaticString = #filePath, line: UInt = #line) async throws -> Puzzle {
        try await finishGeneration(app, level: level, file: file, line: line)
        XCTAssertNil(app.errorMessage, app.errorMessage ?? "", file: file, line: line)
        let puzzle = try XCTUnwrap(app.session?.puzzle, file: file, line: line)
        XCTAssertEqual(puzzle.id, level, file: file, line: line)
        XCTAssertEqual(app.lastGenerationReport?.selectedSimilarityReport?.comparedBoards, 150 + expectedHistory,
                       "The actual runtime pipeline must include every previously registered board.", file: file, line: line)
        XCTAssertEqual(app.lastGenerationReport?.selectedSimilarityReport?.accepted, true, file: file, line: line)
        XCTAssertEqual(app.progress.experimentalHistoryCheckpoint?.count, expectedHistory + 1, file: file, line: line)
        XCTAssertEqual(app.lastGenerationReport?.generatedCandidates, 100, file: file, line: line)
        return puzzle
    }

    private func currentCache(_ directory: URL) throws -> URL {
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("progress.json"))) as! [String: Any]
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        let progress = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let session = try XCTUnwrap(progress["session"] as? [String: Any])
        let reference = try XCTUnwrap(session["puzzleReference"] as? [String: Any])
        return directory.appendingPathComponent("BoardCache/" + (try XCTUnwrap(reference["checksum"] as? String)) + ".json")
    }

    private func assertDistinct(_ puzzles: [Puzzle], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(puzzles.map { PuzzleFingerprint(puzzle: $0).answerPattern }).count, puzzles.count, file: file, line: line)
        XCTAssertEqual(Set(puzzles.map { PuzzleFingerprint(puzzle: $0).regionGraph }).count, puzzles.count, file: file, line: line)
    }

    @MainActor func testColdGenerationRetainsEarlierHistoryAfterOldBoardCacheIsDeleted() async throws {
        let directory = directory()
        var warm: AppModel? = model(directory)
        let first = try await generate(try XCTUnwrap(warm), level: 151, expectedHistory: 0)
        let firstCache = try currentCache(directory)
        let second = try await generate(try XCTUnwrap(warm), level: 152, expectedHistory: 1)
        let savedProgress = try XCTUnwrap(warm).progress
        XCTAssertEqual(savedProgress.attemptCounts["151"], 1)
        XCTAssertEqual(savedProgress.attemptCounts["152"], 1)
        try FileManager.default.removeItem(at: firstCache)
        warm = nil

        let cold = model(directory)
        XCTAssertEqual(cold.progress, savedProgress)
        let history = ExperimentalPuzzleHistoryStore(directory: directory)
        let prior = try history.load(checkpoint: cold.progress.experimentalHistoryCheckpoint, requiredLevels: [151, 152])
        XCTAssertEqual(prior.corpus.count, 2)
        XCTAssertEqual(prior.checkpoint, cold.progress.experimentalHistoryCheckpoint)
        XCTAssertEqual(prior.corpus.first { $0.levelID == 151 }?.fingerprint, PuzzleFingerprint(puzzle: first))
        let third = try await generate(cold, level: 153, expectedHistory: 2)
        assertDistinct([first, second, third])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCache.path), "History must survive independently of an old board's cache file.")
        let nextCold = model(directory)
        XCTAssertEqual(nextCold.progress, cold.progress)
        let restoredHistory = try history.load(checkpoint: nextCold.progress.experimentalHistoryCheckpoint, requiredLevels: [151, 152, 153])
        XCTAssertEqual(restoredHistory.corpus.count, 3)
        XCTAssertEqual(restoredHistory.checkpoint, nextCold.progress.experimentalHistoryCheckpoint)
    }

    @MainActor func testCorruptBothHistoryCopiesStopsGenerationWithoutChangingPlayableState() async throws {
        let directory = directory(), app = model(directory)
        _ = try await generate(app, level: 151, expectedHistory: 0)
        app.progress.bonusHints = 3; app.progress.bonusDirect = 2; app.save(force: true)
        let before = app.progress
        let savedBytes = try Data(contentsOf: directory.appendingPathComponent("progress.json"))
        let history = ExperimentalPuzzleHistoryStore(directory: directory)
        let broken = Data("damaged history".utf8)
        try broken.write(to: history.primaryURL, options: .atomic)
        try broken.write(to: history.backupURL, options: .atomic)
        try await finishGeneration(app, level: 152)
        XCTAssertTrue(app.errorMessage?.contains("history could not be verified") == true)
        XCTAssertNil(app.lastGenerationReport, "Unverified history must stop before generating candidates.")
        XCTAssertEqual(app.progress, before)
        XCTAssertNil(app.progress.attemptCounts["152"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("progress.json")), savedBytes)
        XCTAssertEqual(try Data(contentsOf: history.primaryURL), broken)
        XCTAssertEqual(try Data(contentsOf: history.backupURL), broken)
        XCTAssertEqual(model(directory).progress, before, "A damaged history does not invalidate the intact current-board save.")
    }

    @MainActor func testLegacySaveWithMissingKnownHistoricalBoardCannotSilentlyImportPartialHistory() async throws {
        let directory = directory(), app = model(directory)
        _ = try await generate(app, level: 151, expectedHistory: 0)
        let oldCache = try currentCache(directory)
        _ = try await generate(app, level: 152, expectedHistory: 1)
        // Simulate a pre-ledger save using actual generated boards and the old
        // nil checkpoint shape. Its attempt history still proves L151 existed.
        app.progress.experimentalHistoryCheckpoint = nil
        app.save(force: true)
        let history = ExperimentalPuzzleHistoryStore(directory: directory)
        try FileManager.default.removeItem(at: history.primaryURL)
        try FileManager.default.removeItem(at: history.backupURL)
        try FileManager.default.removeItem(at: oldCache)
        let cold = model(directory)
        let before = cold.progress
        XCTAssertNil(before.experimentalHistoryCheckpoint)
        XCTAssertEqual(before.attemptCounts["151"], 1)
        XCTAssertEqual(before.session?.puzzle.id, 152)
        try await finishGeneration(cold, level: 153)
        XCTAssertTrue(cold.errorMessage?.contains("history could not be verified") == true)
        XCTAssertNil(cold.lastGenerationReport)
        XCTAssertEqual(cold.progress, before)
        XCTAssertNil(cold.progress.attemptCounts["153"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.primaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.backupURL.path))
    }

    @MainActor func testNewBoardPlayerSaveFailureKeepsOldProgressAndRetainsReservedHistory() async throws {
        let directory = directory(), app = model(directory)
        let first = try await generate(app, level: 151, expectedHistory: 0)
        app.progress.bonusHints = 3; app.progress.bonusDirect = 2; app.save(force: true)
        let before = app.progress
        let primary = directory.appendingPathComponent("progress.json")
        let backup = directory.appendingPathComponent("progress.backup.json")
        let primaryBytes = try Data(contentsOf: primary), backupBytes = try Data(contentsOf: backup)
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        try await finishGeneration(app, level: 152)
        XCTAssertTrue(app.errorMessage?.contains("Generation stopped safely") == true)
        XCTAssertEqual(app.lastGenerationReport?.selectedSimilarityReport?.comparedBoards, 151)
        XCTAssertEqual(app.progress, before, "A candidate whose player save failed must never replace the playable board or charge another attempt.")
        XCTAssertNil(app.progress.attemptCounts["152"])
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
        let history = ExperimentalPuzzleHistoryStore(directory: directory)
        let reserved = try history.load(checkpoint: before.experimentalHistoryCheckpoint, requiredLevels: [151])
        XCTAssertEqual(reserved.corpus.count, 2)
        XCTAssertTrue(reserved.corpus.contains { $0.levelID == 152 }, "Conservatively reserving an unused candidate must not forget it on the next request.")

        try FileManager.default.removeItem(at: primary)
        try primaryBytes.write(to: primary, options: .atomic)
        let cold = model(directory)
        XCTAssertEqual(cold.progress, before)
        let third = try await generate(cold, level: 153, expectedHistory: 2)
        XCTAssertNotEqual(PuzzleFingerprint(puzzle: third).answerPattern, PuzzleFingerprint(puzzle: first).answerPattern)
        XCTAssertTrue(reserved.corpus.allSatisfy { $0.fingerprint.answerPattern != PuzzleFingerprint(puzzle: third).answerPattern })
        XCTAssertEqual(cold.progress.attemptCounts["151"], 1)
        XCTAssertNil(cold.progress.attemptCounts["152"])
        XCTAssertEqual(cold.progress.attemptCounts["153"], 1)
    }

    @MainActor func testRegeneratingSameLevelStillChecksItsPreviousVariant() async throws {
        let directory = directory(), app = model(directory)
        let first = try await generate(app, level: 151, expectedHistory: 0)
        let second = try await generate(app, level: 151, expectedHistory: 1)
        assertDistinct([first, second])
        XCTAssertEqual(app.progress.attemptCounts["151"], 2)
        let history = try ExperimentalPuzzleHistoryStore(directory: directory)
            .load(checkpoint: app.progress.experimentalHistoryCheckpoint, requiredLevels: [151])
        XCTAssertEqual(history.corpus.map(\.levelID), [151, 151])
        XCTAssertEqual(model(directory).progress, app.progress)
    }
}
