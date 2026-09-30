import XCTest
import CryptoKit
@testable import CapydokuCore

final class SaveHardeningTests: XCTestCase {
    private var directory: URL!
    private var store: SaveStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CapydokuHardening-\(UUID())")
        store = SaveStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func freshProgress(level: Int = 1) throws -> PlayerProgress {
        var progress = PlayerProgress()
        progress.begin(puzzle: try PuzzleGenerator.generate(level: level))
        return progress
    }

    /// Models a buggy old client which wrote a well-formed envelope, not a random damaged byte.
    private func replacePayload(_ mutate: (inout [String: Any]) -> Void, schema: Int = 2) throws {
        let data = try Data(contentsOf: store.primaryURL)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        mutate(&payload)
        let changed = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        envelope["payload"] = changed.base64EncodedString()
        envelope["checksum"] = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
        envelope["schemaVersion"] = schema
        try JSONSerialization.data(withJSONObject: envelope).write(to: store.primaryURL)
    }

    func testInvalidRegionLabelsFallBackToKnownGoodBackup() throws {
        var progress = try freshProgress()
        try store.save(progress)
        let expectedBackup = progress
        progress.bonusHints = 2
        try store.save(progress)
        try replacePayload { payload in
            var session = payload["session"] as! [String: Any]
            var puzzle = session["puzzle"] as! [String: Any]
            var regions = puzzle["regions"] as! [Int]
            regions[0] = -1
            puzzle["regions"] = regions; session["puzzle"] = puzzle; payload["session"] = session
        }
        let loaded = store.load()
        XCTAssertEqual(loaded.source, .backup)
        XCTAssertEqual(loaded.progress, expectedBackup)
        XCTAssertEqual(store.load().progress, expectedBackup)
    }

    func testStoredAnswerMustObeyAllFourRules() throws {
        var progress = try freshProgress()
        progress.session?.puzzle.solution = [0, 1, 2, 3]
        XCTAssertThrowsError(try store.save(progress))
    }

    func testDisconnectedAndAmbiguousRegionsAreRejected() throws {
        var progress = try freshProgress()
        progress.session?.puzzle.regions = Array(0..<16).map { $0 % 4 }
        // Four column regions are connected but both legal 4x4 solutions are allowed.
        XCTAssertThrowsError(try store.save(progress))
        progress.session?.puzzle.regions = Array(0..<16).map { ($0 / 4 + $0 % 4) % 4 }
        XCTAssertThrowsError(try store.save(progress))
    }

    func testDecodedConfigCannotBypassInitializerBounds() throws {
        for (field, badValue) in [("baseScore", -1), ("comboBonus", Int.max),
                                   ("initialLives", 100), ("hintsPerLevel", -1),
                                   ("generatorCandidateLimit", 0), ("checkInCycleDays", 0)] {
            try store.save(try freshProgress())
            if FileManager.default.fileExists(atPath: store.backupURL.path) {
                try FileManager.default.removeItem(at: store.backupURL)
            }
            try replacePayload { payload in
                var session = payload["session"] as! [String: Any]
                var config = session["config"] as! [String: Any]
                config[field] = badValue; session["config"] = config; payload["session"] = session
            }
            XCTAssertEqual(store.load().source, .resetAfterCorruption, field)
        }
    }

    func testInconsistentSessionAndProgressAreRejected() throws {
        var progress = try freshProgress()
        progress.currentLevel = 2
        XCTAssertThrowsError(try store.save(progress))
        progress = try freshProgress()
        progress.tutorialStep = -1
        XCTAssertThrowsError(try store.save(progress))
        progress = try freshProgress()
        progress.checkIn.completedCycles = -1
        XCTAssertThrowsError(try store.save(progress))
        progress = try freshProgress()
        progress.session?.advanceTime(by: Double(Int.max))
        XCTAssertThrowsError(try store.save(progress), "Elapsed time must remain safe for display conversions")
    }

    func testMigrationFailureRetainsPrimaryAndUsesBackup() throws {
        let expected = try freshProgress()
        try store.save(expected)
        try store.save(expected)
        try replacePayload({ payload in payload["bonusDirect"] = -1 }, schema: 1)
        let incompatible = try Data(contentsOf: store.primaryURL)
        let loaded = store.load()
        XCTAssertEqual(loaded.source, .backup)
        XCTAssertEqual(loaded.progress, expected)
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("preserved") }
        XCTAssertTrue(try preserved.contains { try Data(contentsOf: $0) == incompatible })
    }

    func testTwoCorruptOriginalsSurviveTwoSubsequentSaves() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let primary = Data("distinct damaged primary".utf8)
        let backup = Data("distinct damaged backup".utf8)
        try primary.write(to: store.primaryURL)
        try backup.write(to: store.backupURL)
        let loaded = store.load()
        XCTAssertEqual(loaded.source, .resetAfterCorruption)
        try store.save(loaded.progress)
        var next = loaded.progress
        next.bonusHints = 1
        try store.save(next)
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("preserved") }
        let originals = try preserved.map { try Data(contentsOf: $0) }
        XCTAssertTrue(originals.contains(primary), "Damaged primary must be retained")
        XCTAssertTrue(originals.contains(backup), "Damaged backup must be retained before replacement")
        XCTAssertEqual(store.load().progress, next)
        try Data("later primary damage".utf8).write(to: store.primaryURL)
        XCTAssertEqual(store.load().progress, loaded.progress, "Replacement backup must contain the preceding valid save")
    }

    func testTwoHundredFortyDeterministicMutationsAndRestores() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent("Resources/levels.json")))
        var progress = PlayerProgress()
        progress.begin(puzzle: try XCTUnwrap(catalog.first { $0.size == 10 }))
        let boardSize = progress.session!.puzzle.size
        XCTAssertEqual(boardSize, 10)
        let started = Date()
        for index in 0..<240 {
            switch index % 6 {
            case 0: _ = progress.session?.toggleMark(at: (index / 6) % (boardSize * boardSize))
            case 1: progress.session?.advanceTime(by: 1.5)
            case 2: progress.settings.soundEnabled.toggle()
            case 3: _ = progress.claimCheckIn(on: Date(timeIntervalSince1970: Double(20_000 + index) * 86_400))
            case 4: progress.restart()
            default:
                let cell = progress.session!.puzzle.solution[0]
                _ = progress.session?.submit(cell: cell)
            }
            progress.captureSessionBalance()
            try store.save(progress)
            // A fresh store deliberately discards the validation cache, as a new process does.
            let restored = SaveStore(directory: directory).load()
            XCTAssertEqual(restored.source, .primary, "operation \(index)")
            XCTAssertEqual(restored.progress, progress, "operation \(index)")
            progress = restored.progress
        }
        let elapsed = Date().timeIntervalSince(started)
        let bytes = try Data(contentsOf: store.primaryURL).count
        print("SAVE_STRESS board=10x10 operations=240 fresh_store_each_restore=true save+restore_seconds=\(elapsed) final_bytes=\(bytes)")
    }
}
