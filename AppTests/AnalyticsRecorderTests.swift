import XCTest
@testable import Capydoku

private final class MemoryIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}
final class AnalyticsRecorderTests: XCTestCase {
    @MainActor func testNoCollectionBeforeConsentAndFirstOpenAndBusinessResultsAreIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MemoryIdentity()
        let recorder = AnalyticsRecorder(directory: directory, identityStore: identity)
        XCTAssertFalse(recorder.record("level_start", key: "attempt", level: 1, config: "test", parameters: [:]))
        XCTAssertNil(identity.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        recorder.acceptConsent(); recorder.acceptConsent()
        XCTAssertEqual(recorder.events.map(\.eventName), ["first_open", "session_start"])
        for _ in 0..<20 { recorder.record("level_start", key: "attempt", level: 1, config: "test", parameters: ["attempt_no":"1", "grid_size":"4x4", "is_tutorial":"true", "direct_find_visible":"true", "direct_find_inventory":"1", "hint_inventory":"1", "level_start_free_available":"false"]) }
        XCTAssertEqual(recorder.events.filter { $0.eventName == "level_start" }.count, 1)
        XCTAssertEqual(recorder.events.last?.parameters["attempt_no"], .integer(1))
        XCTAssertEqual(recorder.events.last?.parameters["is_tutorial"], .flag(true))
        let first = recorder.events.first!
        recorder.endSession(reason: "quit"); recorder.endSession(reason: "quit")
        XCTAssertEqual(recorder.events.filter { $0.eventName == "session_end" }.count, 1)
        let restored = AnalyticsRecorder(directory: directory, identityStore: identity)
        restored.acceptConsent()
        XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
        XCTAssertEqual(restored.events.first?.eventTime, first.eventTime)
        XCTAssertEqual(restored.events.first?.userID, first.userID)
        XCTAssertEqual(restored.events.first?.sessionID, first.sessionID)
        XCTAssertFalse(restored.record("coin_change", key: "bad", parameters: [:]))
        XCTAssertFalse(restored.record("cell_tap", key: "bad", parameters: [:]))
        XCTAssertFalse(restored.record("level_start", key: "no-config", level: 2, parameters: [:]))
        XCTAssertTrue(restored.events.allSatisfy { $0.environment == "internal-demo-offline" })
    }

    @MainActor func testShortBackgroundKeepsSessionAndLongBackgroundEndsOnceWithoutDoubleDuration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AnalyticsRecorder(directory: directory, identityStore: MemoryIdentity(), sessionTimeout: 30)
        let start = Date(timeIntervalSince1970: 1000)
        recorder.acceptConsent(at: start)
        let firstSession = recorder.events.last!.sessionID
        recorder.endSession(reason: "background", at: start.addingTimeInterval(10))
        recorder.endSession(reason: "background", at: start.addingTimeInterval(11))
        recorder.beginSession(source: "resume", at: start.addingTimeInterval(20))
        XCTAssertEqual(recorder.events.filter { $0.eventName == "session_start" }.count, 1)
        XCTAssertTrue(recorder.record("tutorial_start", key: "tutorial", parameters: ["tutorial_id":"first"], at: start.addingTimeInterval(25)))
        XCTAssertEqual(recorder.events.last?.sessionID, firstSession)
        recorder.endSession(reason: "background", at: start.addingTimeInterval(30))
        recorder.beginSession(source: "resume", at: start.addingTimeInterval(100))
        let endings = recorder.events.filter { $0.eventName == "session_end" }
        XCTAssertEqual(endings.count, 1)
        XCTAssertEqual(endings.first?.parameters["duration_sec"], .integer(20))
        XCTAssertEqual(endings.first?.eventTime, start.addingTimeInterval(30))
        XCTAssertEqual(recorder.events.filter { $0.eventName == "session_start" }.count, 2)
        XCTAssertNotEqual(recorder.events.last?.sessionID, firstSession)
    }

    @MainActor func testInterruptedSessionRecoversOriginalIDsAndKnownDuration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MemoryIdentity(), start = Date(timeIntervalSince1970: 1000)
        let first = AnalyticsRecorder(directory: directory, identityStore: identity)
        first.acceptConsent(at: start)
        XCTAssertTrue(first.record("tutorial_start", key: "tutorial", parameters: ["tutorial_id":"first"], at: start.addingTimeInterval(15)))
        let firstSession = first.events.last!.sessionID
        let restored = AnalyticsRecorder(directory: directory, identityStore: identity)
        restored.acceptConsent(at: start.addingTimeInterval(40))
        let ending = try XCTUnwrap(restored.events.first { $0.eventName == "session_end" })
        XCTAssertEqual(ending.sessionID, firstSession)
        XCTAssertEqual(ending.parameters["duration_sec"], .integer(15))
        XCTAssertEqual(ending.parameters["end_reason"], .text("quit"))
        XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
    }

    @MainActor func testContractRejectsMissingFieldsPIIAndWrongEnumsWithoutCoercingStringIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AnalyticsRecorder(directory: directory, identityStore: MemoryIdentity())
        recorder.acceptConsent()
        XCTAssertFalse(recorder.record("level_start", key: "bad", level: 1, config: "test", parameters: ["attempt_no":"1"]))
        XCTAssertFalse(recorder.record("tutorial_start", key: "bad", parameters: ["tutorial_id":"one", "email":"test@example.com"]))
        XCTAssertFalse(recorder.record("session_end", key: "bad", parameters: ["duration_sec":"-1", "end_reason":"bad"]))
        let values = ["offer_id":"123", "placement_id":"hint", "status":"completed", "reward_granted":"true", "error_code":"", "ad_type":"rewarded", "network":"simulation", "ad_unit_id":"456"]
        XCTAssertTrue(recorder.record("ad_result", key: "offer", level: 1, config: "test", parameters: values))
        XCTAssertEqual(recorder.events.last?.parameters["offer_id"], .text("123"))
        XCTAssertEqual(recorder.events.last?.parameters["ad_unit_id"], .text("456"))
        XCTAssertEqual(recorder.events.last?.parameters["reward_granted"], .flag(true))
    }

    @MainActor func testInterstitialContractRequiresSeparatePlacementAndRejectsAnyGameReward() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AnalyticsRecorder(directory: directory, identityStore: MemoryIdentity())
        recorder.acceptConsent()
        let offered = ["offer_id": "one", "placement_id": "demo_interstitial_win_v1", "reward_type": "", "buff_type": "", "reward_amount": "0", "ad_type": "interstitial", "network": "simulation", "ad_unit_id": "internal-demo"]
        let result = ["offer_id": "one", "placement_id": "demo_interstitial_win_v1", "status": "completed", "reward_granted": "false", "error_code": "", "ad_type": "interstitial", "network": "simulation", "ad_unit_id": "internal-demo"]
        XCTAssertTrue(recorder.record("ad_offer_shown", key: "one", level: 2, config: "demo", parameters: offered))
        XCTAssertTrue(recorder.record("ad_result", key: "one:completed", level: 2, config: "demo", parameters: result))
        for (field, value) in [("reward_amount", "1"), ("reward_type", "hint"), ("buff_type", "hint"), ("placement_id", "hint"), ("placement_id", "  ")] {
            var invalid = offered; invalid[field] = value
            XCTAssertFalse(recorder.record("ad_offer_shown", key: UUID().uuidString, level: 2, config: "demo", parameters: invalid))
        }
        var awarded = result; awarded["reward_granted"] = "true"
        XCTAssertFalse(recorder.record("ad_result", key: "invalid-grant", level: 2, config: "demo", parameters: awarded))
        var borrowed = result; borrowed["ad_type"] = "rewarded"
        XCTAssertFalse(recorder.record("ad_result", key: "invalid-rewarded-placement", level: 2, config: "demo", parameters: borrowed))
        var inventedRevenue = result; inventedRevenue["revenue"] = "1"
        XCTAssertFalse(recorder.record("ad_result", key: "invalid-revenue", level: 2, config: "demo", parameters: inventedRevenue))
        XCTAssertEqual(recorder.events.filter { $0.eventName.hasPrefix("ad_") }.count, 2)
    }

    @MainActor func testFailedWritesRetainOriginalEventsAndRetryAfterStorageRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("blocked".utf8).write(to: directory)
        let identity = MemoryIdentity()
        let recorder = AnalyticsRecorder(directory: directory, identityStore: identity)
        let date = Date(timeIntervalSince1970: 1000)
        recorder.acceptConsent(at: date)
        XCTAssertNotNil(recorder.lastError)
        let original = recorder.events.first!
        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(recorder.retryPendingWrites())
        let restored = AnalyticsRecorder(directory: directory, identityStore: identity)
        XCTAssertEqual(restored.events.first?.eventID, original.eventID)
        XCTAssertEqual(restored.events.first?.eventTime, original.eventTime)
        XCTAssertEqual(restored.events.first?.userID, original.userID)
    }

    @MainActor func testFailedCrashSessionSettlementStillStartsNewColdSessionAndRecoveryPreservesEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MemoryIdentity(), start = Date(timeIntervalSince1970: 1000)
        let first = AnalyticsRecorder(directory: directory, identityStore: identity)
        first.acceptConsent(at: start)
        XCTAssertTrue(first.record("tutorial_start", key: "previous-activity", parameters: ["tutorial_id": "first"], at: start.addingTimeInterval(15)))
        let previousID = try XCTUnwrap(first.events.last?.sessionID)

        // Read the real saved active session, then make its directory unwritable
        // by replacing the path with a regular file before crash settlement.
        let current = AnalyticsRecorder(directory: directory, identityStore: identity)
        try FileManager.default.removeItem(at: directory)
        try Data("blocked-directory".utf8).write(to: directory)
        let coldStart = start.addingTimeInterval(40)
        current.acceptConsent(at: coldStart)
        XCTAssertNotNil(current.lastError)
        let ending = try XCTUnwrap(current.events.first { $0.eventName == "session_end" })
        let newStart = try XCTUnwrap(current.events.last { $0.eventName == "session_start" })
        XCTAssertEqual(ending.sessionID, previousID)
        XCTAssertEqual(ending.eventTime, start.addingTimeInterval(15))
        XCTAssertEqual(ending.parameters["duration_sec"], .integer(15))
        XCTAssertEqual(ending.parameters["end_reason"], .text("quit"))
        XCTAssertNotEqual(newStart.sessionID, previousID)
        XCTAssertEqual(newStart.eventTime, coldStart)
        XCTAssertEqual(newStart.parameters["entry_source"], .text("cold_start"))
        XCTAssertFalse(current.record("tutorial_start", key: "new-activity", parameters: ["tutorial_id": "second"], at: coldStart.addingTimeInterval(2)))
        let activity = try XCTUnwrap(current.events.last)
        XCTAssertEqual(activity.sessionID, newStart.sessionID)

        try FileManager.default.removeItem(at: directory)
        current.acceptConsent(at: coldStart.addingTimeInterval(5)) // The existing enabled path retries writes.
        current.beginSession(source: "resume", at: coldStart.addingTimeInterval(6))
        XCTAssertNil(current.lastError)
        XCTAssertEqual(current.events.filter { $0.eventName == "session_start" }.count, 2)
        XCTAssertEqual(current.events.filter { $0.eventName == "session_end" }.count, 1)
        let restored = AnalyticsRecorder(directory: directory, identityStore: identity)
        for expected in [ending, newStart, activity] {
            let actual = try XCTUnwrap(restored.events.first { $0.eventID == expected.eventID })
            XCTAssertEqual(actual.eventTime, expected.eventTime)
            XCTAssertEqual(actual.sessionID, expected.sessionID)
            XCTAssertEqual(actual.userID, expected.userID)
            XCTAssertEqual(actual.parameters, expected.parameters)
        }
        XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
    }

    @MainActor func testFailedLongBackgroundSettlementDoesNotAttachResumeActivityToEndedSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MemoryIdentity(), start = Date(timeIntervalSince1970: 1000)
        let recorder = AnalyticsRecorder(directory: directory, identityStore: identity, sessionTimeout: 30)
        recorder.acceptConsent(at: start)
        let oldID = try XCTUnwrap(recorder.events.last?.sessionID)
        recorder.endSession(reason: "background", at: start.addingTimeInterval(10))
        try FileManager.default.removeItem(at: directory)
        try Data("blocked-directory".utf8).write(to: directory)
        recorder.beginSession(source: "resume", at: start.addingTimeInterval(60))
        XCTAssertNotNil(recorder.lastError)
        let ending = try XCTUnwrap(recorder.events.first { $0.eventName == "session_end" })
        let resumed = try XCTUnwrap(recorder.events.last { $0.eventName == "session_start" })
        XCTAssertEqual(ending.sessionID, oldID)
        XCTAssertEqual(ending.eventTime, start.addingTimeInterval(10))
        XCTAssertEqual(ending.parameters["duration_sec"], .integer(10))
        XCTAssertEqual(resumed.eventTime, start.addingTimeInterval(60))
        XCTAssertEqual(resumed.parameters["entry_source"], .text("resume"))
        XCTAssertNotEqual(resumed.sessionID, oldID)
        XCTAssertFalse(recorder.record("tutorial_start", key: "resumed-activity", parameters: ["tutorial_id": "second"], at: start.addingTimeInterval(61)))
        XCTAssertEqual(recorder.events.last?.sessionID, resumed.sessionID)
        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(recorder.retryPendingWrites())
        recorder.beginSession(source: "resume", at: start.addingTimeInterval(65))
        XCTAssertEqual(recorder.events.filter { $0.eventName == "session_start" }.count, 2)
        XCTAssertEqual(recorder.events.filter { $0.eventName == "session_end" }.count, 1)
        let restored = AnalyticsRecorder(directory: directory, identityStore: identity)
        XCTAssertEqual(restored.events.map(\.eventID), recorder.events.map(\.eventID))
    }
}
