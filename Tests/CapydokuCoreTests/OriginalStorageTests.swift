import XCTest
@testable import CapydokuCore

final class OriginalStorageTests: XCTestCase {
    private func payload(_ store: SaveStore) throws -> [String: Any] {
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: store.primaryURL)) as! [String: Any]
        let data = Data(base64Encoded: envelope["payload"] as! String)!
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func testPackagedPuzzleIsNotWrittenIntoPlayerSaveAndLegacyMigrates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let puzzle = try PuzzleGenerator.generate(level: 1)
        var progress = PlayerProgress(); progress.begin(puzzle: puzzle)
        _ = progress.session?.toggleMark(at: 0)
        let legacy = SaveStore(directory: directory)
        try legacy.save(progress)
        let store = SaveStore(directory: directory, packagedPuzzle: { $0 == 1 ? puzzle : nil })
        XCTAssertEqual(store.load().progress, progress)
        try store.save(progress)
        let session = try XCTUnwrap(try payload(store)["session"] as? [String: Any])
        XCTAssertNil(session["puzzle"])
        XCTAssertNotNil(session["puzzleReference"])
        XCTAssertEqual(store.load().progress, progress)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("BoardCache").path))
    }
    func testExperimentalBoardUsesSeparateImmutableCacheAndRestoresSameBoard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let puzzle = try PuzzleGenerator.generate(level: 151)
        var progress = PlayerProgress(); progress.begin(puzzle: puzzle)
        let store = SaveStore(directory: directory, packagedPuzzle: { _ in nil })
        try store.save(progress)
        let session = try XCTUnwrap(try payload(store)["session"] as? [String: Any])
        XCTAssertNil(session["puzzle"])
        XCTAssertEqual(store.load().progress, progress)
        let cache = directory.appendingPathComponent("BoardCache")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).count, 1)
        _ = progress.session?.toggleMark(at: 0); try store.save(progress)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).count, 1)
        XCTAssertEqual(store.load().progress, progress)
    }

    func testDamagedExperimentalCacheIsPreservedAndRepairedBeforeWritingSaveReference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let puzzle = try PuzzleGenerator.generate(level: 151)
        var progress = PlayerProgress(); progress.begin(puzzle: puzzle)
        let store = SaveStore(directory: directory, packagedPuzzle: { _ in nil })
        try store.save(progress)
        _ = progress.session?.toggleMark(at: 0); try store.save(progress)

        let savedSession = try XCTUnwrap(try payload(store)["session"] as? [String: Any])
        let reference = try XCTUnwrap(savedSession["puzzleReference"] as? [String: Any])
        let digest = try XCTUnwrap(reference["checksum"] as? String)
        let cache = directory.appendingPathComponent("BoardCache", isDirectory: true)
        let boardURL = cache.appendingPathComponent(digest + ".json")
        let originalBoardBytes = try Data(contentsOf: boardURL)
        let damaged = Data("damaged experimental board".utf8)
        try damaged.write(to: boardURL, options: .atomic)

        try store.transaction(progress: &progress) { candidate in
            _ = candidate.session?.toggleMark(at: 1)
        }
        XCTAssertEqual(try Data(contentsOf: boardURL), originalBoardBytes)
        let preserved = try FileManager.default.contentsOfDirectory(
            at: cache.appendingPathComponent("Preserved", isDirectory: true), includingPropertiesForKeys: nil)
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preserved.first)), damaged)

        // A fresh SaveStore has no warm validation cache. Both player files may
        // reference this board, so verify the repaired dependency on cold load.
        let cold = SaveStore(directory: directory, packagedPuzzle: { _ in nil }).load()
        XCTAssertEqual(cold.source, .primary)
        XCTAssertEqual(cold.progress, progress)
        XCTAssertNil(cold.warning)
        XCTAssertEqual(cold.progress.session?.marks, [0, 1])
    }

    func testFailedDamagedBoardPreservationThrowsWithoutPublishingNewPlayerState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let packaged = try PuzzleGenerator.generate(level: 1)
        let experimental = try PuzzleGenerator.generate(level: 151)
        let store = SaveStore(directory: directory, packagedPuzzle: { $0 == 1 ? packaged : nil })
        var progress = PlayerProgress(); progress.begin(puzzle: packaged)
        _ = progress.session?.toggleMark(at: 0)
        let previousPackagedProgress = progress
        try store.save(progress)
        progress.begin(puzzle: experimental); try store.save(progress)
        let beforeTransaction = progress
        let beforePrimary = try Data(contentsOf: store.primaryURL)
        let beforeBackup = try Data(contentsOf: store.backupURL)

        let savedSession = try XCTUnwrap(try payload(store)["session"] as? [String: Any])
        let reference = try XCTUnwrap(savedSession["puzzleReference"] as? [String: Any])
        let digest = try XCTUnwrap(reference["checksum"] as? String)
        let cache = directory.appendingPathComponent("BoardCache", isDirectory: true)
        let boardURL = cache.appendingPathComponent(digest + ".json")
        let damaged = Data("damaged experimental board".utf8)
        try damaged.write(to: boardURL, options: .atomic)
        // Real filesystem failure: a file occupies the required preservation
        // directory. Do not discard the evidence to claim a successful repair.
        let obstruction = Data("preservation directory unavailable".utf8)
        try obstruction.write(to: cache.appendingPathComponent("Preserved"), options: .atomic)

        XCTAssertThrowsError(try store.transaction(progress: &progress) { candidate in
            _ = candidate.session?.toggleMark(at: 1)
        })
        XCTAssertEqual(progress, beforeTransaction)
        XCTAssertEqual(try Data(contentsOf: store.primaryURL), beforePrimary)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), beforeBackup)
        XCTAssertEqual(try Data(contentsOf: boardURL), damaged)
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent("Preserved")), obstruction)

        let cold = SaveStore(directory: directory, packagedPuzzle: { $0 == 1 ? packaged : nil }).load()
        XCTAssertEqual(cold.source, .backup)
        XCTAssertEqual(cold.progress, previousPackagedProgress)
        XCTAssertNotNil(cold.warning)
    }

    func testExperimentalHistoryCheckpointRejectsMalformedCountsAndDigests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SaveStore(directory: directory)
        var progress = PlayerProgress()
        progress.experimentalHistoryCheckpoint = .init(count: 0, chainSHA256: String(repeating: "a", count: 64))
        try store.save(progress)
        let saved = try Data(contentsOf: store.primaryURL)
        XCTAssertEqual(store.load().progress.experimentalHistoryCheckpoint, progress.experimentalHistoryCheckpoint)
        for (count, hash) in [(-1, String(repeating: "a", count: 64)),
                              (100_001, String(repeating: "a", count: 64)),
                              (1, String(repeating: "A", count: 64)),
                              (1, String(repeating: "g", count: 64)),
                              (1, String(repeating: "a", count: 63))] {
            progress.experimentalHistoryCheckpoint = .init(count: count, chainSHA256: hash)
            XCTAssertThrowsError(try store.save(progress))
            XCTAssertEqual(try Data(contentsOf: store.primaryURL), saved)
        }
    }

    func testUpgradeKeepsAnOldInProgressBoardWhileNewGamesUseTheNewPack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func first(_ name: String) throws -> Puzzle {
            try XCTUnwrap(JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent("Resources/\(name).json"))).first)
        }
        let old = try first("levels-legacy-v2"), current = try first("levels")
        XCTAssertNotEqual(old, current)
        var progress = PlayerProgress(); progress.begin(puzzle: old)
        _ = progress.session?.submit(cell: old.solution[0]); _ = progress.session?.toggleMark(at: 0)
        progress.bonusHints = 3; progress.checkIn.streak = 2
        try SaveStore(directory: directory).save(progress)
        let upgraded = SaveStore(directory: directory, packagedPuzzle: { $0 == 1 ? current : nil }, archivedPuzzles: { $0 == 1 ? [old] : [] })
        XCTAssertEqual(upgraded.load().progress, progress)
        try upgraded.save(progress)
        XCTAssertEqual(upgraded.load().progress, progress)
        let saved = try XCTUnwrap(try payload(upgraded)["session"] as? [String: Any])
        XCTAssertNil(saved["puzzle"])
        XCTAssertEqual(upgraded.load().progress.session?.puzzle, old)
    }
    func testTutorialTargetsAreIndependentOfStoredSolution() throws {
        let puzzle = try PuzzleGenerator.generate(level: 1)
        let expected = PuzzleHints.tutorial(puzzle: puzzle)
        var noAnswer = puzzle; noAnswer.solution = []
        XCTAssertEqual(PuzzleHints.tutorial(puzzle: noAnswer), expected)
        for step in expected where step.action == "tap" || step.action == "swipe" || step.action == "exclude" {
            for cell in step.targetCells {
                XCTAssertTrue(PuzzleSolver.solutions(size: puzzle.size, regions: puzzle.regions, limit: 1, required: [cell]).isEmpty)
            }
        }
    }
}
