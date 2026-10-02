import XCTest
import CryptoKit
@testable import CapydokuCore

final class TutorialPlanStorageTests: XCTestCase {
    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tutorial-version-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func progress() throws -> PlayerProgress {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let puzzle = try XCTUnwrap(JSONDecoder().decode([Puzzle].self,
            from: Data(contentsOf: root.appendingPathComponent("Resources/levels.json"))).first)
        var value = PlayerProgress(); value.begin(puzzle: puzzle)
        value.tutorialPlanVersion = .legacy
        let plan = PuzzleHints.tutorial(puzzle: puzzle, version: .legacy)
        value.tutorialStep = try XCTUnwrap(plan.firstIndex { $0.id == "undo" })
        _ = value.session?.toggleMark(at: try XCTUnwrap(plan[value.tutorialStep].targetCells.first))
        value.session?.advanceTime(by: 12)
        value.bonusHints = 7; value.settings.language = .english
        value.checkIn = .init(lastClaimedDay: 20_000, streak: 3, cycleDay: 3)
        return value
    }
    private func payload(_ progress: PlayerProgress) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as? [String: Any])
    }
    @discardableResult private func write(_ payload: [String: Any], schema: Int, to url: URL) throws -> Data {
        let raw = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let envelope: [String: Any] = ["schemaVersion": schema, "payload": raw.base64EncodedString(),
            "checksum": SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()]
        let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return bytes
    }
    func testActualSchemaThreeMissingVersionMigratesWithoutReinterpretingTheUnfinishedStep() throws {
        let expected = try progress(), store = SaveStore(directory: directory())
        var old = try payload(expected); old.removeValue(forKey: "tutorialPlanVersion")
        let oldBytes = try write(old, schema: 3, to: store.primaryURL)
        let result = store.load()
        XCTAssertTrue(result.didMigrate); XCTAssertEqual(result.source, .primary)
        XCTAssertEqual(result.progress, expected)
        XCTAssertEqual(result.progress.tutorialPlanVersion, .legacy)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), oldBytes)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.primaryURL)) as? [String: Any])
        XCTAssertEqual(envelope["schemaVersion"] as? Int, 4)
        XCTAssertEqual(store.load().progress, expected)
        XCTAssertFalse(store.load().didMigrate)
        let puzzle = try XCTUnwrap(expected.session?.puzzle)
        XCTAssertEqual(PuzzleHints.tutorial(puzzle: puzzle, version: result.progress.tutorialPlanVersion)[result.progress.tutorialStep].id, "undo")
    }
    func testAllExplicitPlansRoundTripButOnlyNewUnfinishedAttemptsAdoptTheCurrentPlan() throws {
        for version in [TutorialPlanVersion.legacy, .boardDriven, .playAlong] {
            var value = try progress(); value.tutorialPlanVersion = version
            let store = SaveStore(directory: directory()); try store.save(value)
            XCTAssertEqual(store.load().progress, value)
            XCTAssertFalse(store.load().didMigrate)
            value.restart()
            XCTAssertEqual(value.tutorialPlanVersion, .current)
            XCTAssertEqual(value.tutorialStep, 0)
            XCTAssertEqual(value.session?.marks, [])
        }
        var completed = try progress()
        completed.tutorialCompleted = true; completed.tutorialStep = 9
        completed.restart()
        XCTAssertTrue(completed.tutorialCompleted)
        XCTAssertEqual(completed.tutorialPlanVersion, .legacy)
        XCTAssertEqual(completed.tutorialStep, 9)
    }
    func testCurrentSchemaRequiresExplicitKnownPlanAndPreservesRejectedPrimaryOnBackupRecovery() throws {
        let expected = try progress()
        for bad in [nil, NSNull(), 99, "2", true] as [Any?] {
            let store = SaveStore(directory: directory())
            try store.save(expected); try store.save(expected)
            var invalid = try payload(expected)
            if let bad { invalid["tutorialPlanVersion"] = bad } else { invalid.removeValue(forKey: "tutorialPlanVersion") }
            let bytes = try write(invalid, schema: 4, to: store.primaryURL)
            let result = store.load()
            XCTAssertEqual(result.source, .backup)
            XCTAssertEqual(result.progress, expected)
            let retained = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("progress.preserved-") }
            XCTAssertTrue(try retained.contains { try Data(contentsOf: $0) == bytes })
            XCTAssertEqual(store.load().progress, expected)
        }
    }
    func testOldSchemasDefaultOnlyMissingPlanNotExplicitInvalidValues() throws {
        let expected = try progress()
        for schema in 1...3 {
            let store = SaveStore(directory: directory())
            for bad in [NSNull(), 99, "2", true] as [Any] {
                var invalid = try payload(expected); invalid["tutorialPlanVersion"] = bad
                let bytes = try write(invalid, schema: schema, to: store.primaryURL)
                XCTAssertEqual(store.load().source, .resetAfterCorruption)
                XCTAssertEqual(try Data(contentsOf: store.primaryURL), bytes)
            }
            var old = try payload(expected); old.removeValue(forKey: "tutorialPlanVersion")
            try write(old, schema: schema, to: store.primaryURL)
            XCTAssertEqual(store.load().progress, expected)
        }
    }
    func testFutureSchemaIsNotMisinterpretedAsTheCurrentTeachingPlan() throws {
        let store = SaveStore(directory: directory()), expected = try progress()
        let bytes = try write(payload(expected), schema: SaveStore.currentSchemaVersion + 1, to: store.primaryURL)
        XCTAssertEqual(store.load().source, .resetAfterCorruption)
        XCTAssertEqual(try Data(contentsOf: store.primaryURL), bytes)
        try store.save(PlayerProgress())
        let retained = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("progress.preserved-") }
        XCTAssertTrue(try retained.contains { try Data(contentsOf: $0) == bytes })
    }
}
