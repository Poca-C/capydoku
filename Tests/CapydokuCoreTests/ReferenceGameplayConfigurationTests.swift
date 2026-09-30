import XCTest
import CryptoKit
@testable import CapydokuCore

final class ReferenceGameplayConfigurationTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    /// Fabricated data exercises parser behavior only; never bundled as a Pawdoku baseline.
    private func fixture() throws -> [String: Any] {
        let row = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/reference-gameplay-synthetic-row.json")))
        return ["schemaVersion": 1, "status": "frozen", "configVersion": "synthetic-tests-only",
                "baseline": ["product": "Pawdoku", "storeVersion": "test-only", "capturedAt": "2026-09-30T00:00:00Z", "device": "test-only", "osVersion": "test-only", "sourceArchiveSHA256": String(repeating: "a", count: 64), "evidenceFiles": ["synthetic-test-only"]],
                "importedSourceSHA256": String(repeating: "b", count: 64),
                "levels": (1...150).map { ["level": $0, "configuration": row] }]
    }

    private func encode(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    func testPendingTemplateNeverControlsGameplay() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("Reference/gameplay-template.json"))
        let configuration = try ReferenceGameplayConfiguration.load(data: data)
        XCTAssertFalse(configuration.isReadyForUse)
        XCTAssertNil(configuration.level(1))
        XCTAssertNil(configuration.level(150))
        XCTAssertThrowsError(try configuration.validate(requireFrozen: true))
        XCTAssertEqual(configuration.levels.count, 150)
    }

    func testCompleteFrozenFixtureLoadsOnlyExactLevel() throws {
        let value = try ReferenceGameplayConfiguration.load(data: encode(fixture()))
        XCTAssertTrue(value.isReadyForUse)
        XCTAssertEqual(value.level(150)?.directFind.inventoryAcrossLevels, .retain)
        XCTAssertEqual(value.level(1)?.hint.regrantPolicy, .everyAttempt)
        XCTAssertNil(value.level(151))
    }

    func testSourceChecksumAndPackChecksumRejectInvalidInput() throws {
        var json = try fixture()
        let data = try encode(json)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try ReferenceGameplayConfiguration.load(data: data, expectedSHA256: digest))
        XCTAssertThrowsError(try ReferenceGameplayConfiguration.load(data: data, expectedSHA256: String(repeating: "0", count: 64)))
        json["importedSourceSHA256"] = "unverified"
        XCTAssertThrowsError(try ReferenceGameplayConfiguration.load(data: encode(json)))
    }

    func testMissingDuplicateOrUnknownLevelsCannotBeAccepted() throws {
        var json = try fixture()
        var rows = json["levels"] as! [[String: Any]]
        rows[149]["level"] = 1
        json["levels"] = rows
        XCTAssertThrowsError(try ReferenceGameplayConfiguration.load(data: encode(json)))
        rows[149]["level"] = 151
        json["levels"] = rows
        XCTAssertThrowsError(try ReferenceGameplayConfiguration.load(data: encode(json)))
        json["levels"] = Array(rows.dropLast())
        XCTAssertThrowsError(try ReferenceGameplayConfiguration.load(data: encode(json)))
    }

    func testCompetitorBoardAndUnknownFieldsAreRejectedAtAnyDepth() throws {
        var json = try fixture()
        json["regionMap"] = [0, 1, 2]
        XCTAssertThrowsError(try ReferenceGameplayConfiguration.load(data: encode(json)))
        json.removeValue(forKey: "regionMap")
        var rows = json["levels"] as! [[String: Any]]
        var value = rows[0]["configuration"] as! [String: Any]
        var tool = value["hint"] as! [String: Any]
        tool["answerCoordinates"] = [1, 2]
        value["hint"] = tool
        rows[0]["configuration"] = value
        json["levels"] = rows
        XCTAssertThrowsError(try ReferenceGameplayConfiguration.load(data: encode(json)))
    }

    func testCannotInventTemplateValuesOrNegativeInventory() throws {
        var json = try fixture()
        json["status"] = "awaiting_baseline"
        XCTAssertThrowsError(try ReferenceGameplayConfiguration.load(data: encode(json)))
        json["status"] = "frozen"
        var rows = json["levels"] as! [[String: Any]]
        var value = rows[0]["configuration"] as! [String: Any]
        var tool = value["directFind"] as! [String: Any]
        tool["initialFreeCount"] = -1
        value["directFind"] = tool
        rows[0]["configuration"] = value
        json["levels"] = rows
        XCTAssertThrowsError(try ReferenceGameplayConfiguration.load(data: encode(json)))
    }

    func testCaptureMustBeUTCAndOptionalFieldsMustBeExplicit() throws {
        var json = try fixture()
        var baseline = json["baseline"] as! [String: Any]
        baseline["capturedAt"] = "2026-09-30T08:00:00+08:00"
        json["baseline"] = baseline
        XCTAssertThrowsError(try ReferenceGameplayConfiguration.load(data: encode(json)))
        var pending = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Reference/gameplay-template.json"))) as! [String: Any]
        pending.removeValue(forKey: "configVersion")
        XCTAssertThrowsError(try ReferenceGameplayConfiguration.load(data: encode(pending)))
    }
}
