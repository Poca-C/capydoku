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
        for step in expected where step.action == "tap" || step.action == "swipe" {
            for cell in step.targetCells {
                XCTAssertTrue(PuzzleSolver.solutions(size: puzzle.size, regions: puzzle.regions, limit: 1, required: [cell]).isEmpty)
            }
        }
    }
}
