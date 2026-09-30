import XCTest
@testable import Capydoku

private final class BuildEnvironmentMemoryIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}

final class BuildEnvironmentTests: XCTestCase {
    private var directories: [URL] = []
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("build-environment-test-" + UUID().uuidString)
        directories.append(url)
        return url
    }

    private func configuration(_ environment: String, overrides: [String: Any] = [:]) -> AppBuildConfiguration {
        var info: [String: Any] = ["CapydokuEnvironment": environment, "CapydokuAnalyticsEnabled": true]
        info.merge(overrides) { _, new in new }
        return AppBuildConfiguration(info: info, bundleIdentifier: environment == "internal_demo" ? "com.capydoku.demo" : "com.capydoku.isolation." + environment)
    }

    private func canonical(_ event: AnalyticsRecorder.Event) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(event)
    }

    func testDemoKeepsExistingStorageAndAnalyticsIdentityContract() {
        let demo = configuration("internal_demo")
        XCTAssertEqual(demo.environment, .demo)
        XCTAssertEqual(demo.bundleIdentifier, "com.capydoku.demo")
        XCTAssertTrue(demo.analyticsEnabled)
        XCTAssertEqual(demo.analyticsEnvironment, "internal-demo-offline")
        XCTAssertEqual(demo.storageDirectoryName, "Capydoku")
        XCTAssertEqual(demo.identityServicePrefix, "com.capydoku.demo.analytics.namespace.")
        XCTAssertNil(demo.remoteConfigurationEndpoint)
    }

    func testTestingStagingAndProductionHaveSeparateDeclaredScopes() {
        let rawValues = ["testing", "staging", "production"]
        let builds = rawValues.map { configuration($0) }
        XCTAssertEqual(builds.map(\.environment), [.testing, .staging, .production])
        XCTAssertEqual(Set(builds.map(\.bundleIdentifier)).count, 3)
        XCTAssertEqual(Set(builds.map(\.storageDirectoryName)).count, 3)
        XCTAssertEqual(Set(builds.map(\.identityServicePrefix)).count, 3)
        XCTAssertEqual(Set(builds.map(\.analyticsEnvironment)).count, 3)
        for (raw, build) in zip(rawValues, builds) {
            XCTAssertEqual(build.analyticsEnvironment, raw + "-offline")
            XCTAssertEqual(build.storageDirectoryName, "Capydoku-" + raw)
            XCTAssertEqual(build.identityServicePrefix, build.bundleIdentifier + ".analytics." + raw + ".namespace.")
            XCTAssertTrue(build.analyticsEnabled)
            XCTAssertNil(build.remoteConfigurationEndpoint)
        }
    }

    func testMissingUnknownOrMalformedEnvironmentCannotEnableServices() {
        for environment in [nil, "", "Production", "production ", "unconfigured", "future-environment"] as [String?] {
            var info: [String: Any] = [
                "CapydokuAnalyticsEnabled": true,
                "CapydokuRemoteConfigurationEnabled": true,
                "CapydokuRemoteConfigurationEnvironment": environment ?? "production",
                "CapydokuRemoteConfigurationURL": "https://config.example.invalid/gameplay"
            ]
            if let environment { info["CapydokuEnvironment"] = environment }
            let build = AppBuildConfiguration(info: info, bundleIdentifier: "com.capydoku.environment.invalid")
            XCTAssertEqual(build.environment, .unconfigured)
            XCTAssertFalse(build.analyticsEnabled)
            XCTAssertNil(build.remoteConfigurationEndpoint)
        }
        let malformed = AppBuildConfiguration(info: ["CapydokuEnvironment": true, "CapydokuAnalyticsEnabled": true], bundleIdentifier: "com.capydoku.environment.invalid")
        XCTAssertEqual(malformed.environment, .unconfigured)
        XCTAssertFalse(malformed.analyticsEnabled)
        XCTAssertNil(malformed.remoteConfigurationEndpoint)
    }

    func testServiceSwitchesAcceptBuildYESAndPlistBooleanAndOtherwiseStayOff() {
        for enabled in [true, "YES"] as [Any] {
            let build = configuration("testing", overrides: [
                "CapydokuAnalyticsEnabled": enabled,
                "CapydokuRemoteConfigurationEnabled": enabled,
                "CapydokuRemoteConfigurationEnvironment": "testing",
                "CapydokuRemoteConfigurationURL": "https://config.example.invalid/gameplay"
            ])
            XCTAssertTrue(build.analyticsEnabled)
            XCTAssertEqual(build.remoteConfigurationEndpoint?.absoluteString, "https://config.example.invalid/gameplay")
        }
        for disabled in [false, "NO", "", "$(CAPYDOKU_ANALYTICS_ENABLED)", 1, 2] as [Any] {
            let build = configuration("testing", overrides: [
                "CapydokuAnalyticsEnabled": disabled,
                "CapydokuRemoteConfigurationEnabled": disabled,
                "CapydokuRemoteConfigurationEnvironment": "testing",
                "CapydokuRemoteConfigurationURL": "https://config.example.invalid/gameplay"
            ])
            XCTAssertFalse(build.analyticsEnabled)
            XCTAssertNil(build.remoteConfigurationEndpoint)
        }
        let absent = AppBuildConfiguration(info: ["CapydokuEnvironment": "testing"], bundleIdentifier: "com.capydoku.isolation.testing")
        XCTAssertFalse(absent.analyticsEnabled)
        XCTAssertNil(absent.remoteConfigurationEndpoint)
    }

    func testRemoteConfigurationRequiresMatchingEnvironmentAndTrustedHTTPSURL() {
        let endpoint = "https://config.example.invalid/gameplay"
        for raw in ["internal_demo", "testing", "staging", "production"] {
            let valid: [String: Any] = ["CapydokuRemoteConfigurationEnabled": true,
                "CapydokuRemoteConfigurationEnvironment": raw, "CapydokuRemoteConfigurationURL": endpoint]
            XCTAssertEqual(configuration(raw, overrides: valid).remoteConfigurationEndpoint?.absoluteString, endpoint)
            for wrongEnvironment in ["", "unknown", raw == "production" ? "testing" : "production"] {
                var changed = valid; changed["CapydokuRemoteConfigurationEnvironment"] = wrongEnvironment
                XCTAssertNil(configuration(raw, overrides: changed).remoteConfigurationEndpoint)
            }
            var absentTarget = valid; absentTarget.removeValue(forKey: "CapydokuRemoteConfigurationEnvironment")
            XCTAssertNil(configuration(raw, overrides: absentTarget).remoteConfigurationEndpoint)
            for badURL in ["", "http://config.example.invalid/gameplay", "https:///", "not-a-url",
                           "https://user@config.example.invalid/gameplay", "https://user:secret@config.example.invalid/gameplay",
                           "https://config.example.invalid/gameplay#unexpected-fragment"] {
                var changed = valid; changed["CapydokuRemoteConfigurationURL"] = badURL
                XCTAssertNil(configuration(raw, overrides: changed).remoteConfigurationEndpoint, badURL)
            }
            var absentURL = valid; absentURL.removeValue(forKey: "CapydokuRemoteConfigurationURL")
            XCTAssertNil(configuration(raw, overrides: absentURL).remoteConfigurationEndpoint)
        }
    }

    @MainActor func testDisabledAndUnconfiguredAnalyticsDoNotCreateIdentityOrQueueAfterConsent() {
        let builds = [configuration("testing", overrides: ["CapydokuAnalyticsEnabled": false]), configuration("unrecognized")]
        for build in builds {
            let dir = directory(), identity = BuildEnvironmentMemoryIdentity()
            let recorder = AnalyticsRecorder(directory: dir, identityStore: identity, buildConfiguration: build)
            recorder.acceptConsent(at: start)
            XCTAssertFalse(recorder.enabled)
            XCTAssertNil(identity.value)
            XCTAssertTrue(recorder.events.isEmpty)
            XCTAssertNil(recorder.prepare("tutorial_start", key: "unavailable", parameters: ["tutorial_id": "first"], at: start))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        }
    }

    @MainActor func testNewEventsUseBuildEnvironmentAndNeverCollectBeforeConsent() throws {
        for raw in ["testing", "staging", "production"] {
            let dir = directory(), identity = BuildEnvironmentMemoryIdentity()
            let recorder = AnalyticsRecorder(directory: dir, identityStore: identity, buildConfiguration: configuration(raw))
            XCTAssertFalse(recorder.enabled)
            XCTAssertFalse(recorder.record("tutorial_start", key: "before", parameters: ["tutorial_id": "first"], at: start))
            XCTAssertNil(identity.value)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
            recorder.acceptConsent(at: start)
            XCTAssertTrue(recorder.enabled)
            XCTAssertTrue(recorder.record("tutorial_start", key: "after", parameters: ["tutorial_id": "first"], at: start.addingTimeInterval(1)))
            XCTAssertEqual(recorder.events.map(\.eventName), ["first_open", "session_start", "tutorial_start"])
            XCTAssertTrue(recorder.events.allSatisfy { $0.environment == raw + "-offline" && $0.platform == "iOS" })
        }
    }

    @MainActor func testForeignQueueCannotCollectOrRewriteExistingFilesEvenWithSameIdentity() throws {
        for source in ["internal_demo", "testing", "staging", "production"] {
            let dir = directory(), identity = BuildEnvironmentMemoryIdentity()
            let original = AnalyticsRecorder(directory: dir, identityStore: identity, buildConfiguration: configuration(source))
            original.acceptConsent(at: start)
            XCTAssertTrue(original.record("tutorial_start", key: "original", parameters: ["tutorial_id": "first"], at: start.addingTimeInterval(2)))
            original.endSession(reason: "quit", at: start.addingTimeInterval(3))
            let queue = dir.appendingPathComponent("analytics-demo-queue.json"), backup = queue.appendingPathExtension("backup")
            let originalBytes = try Data(contentsOf: queue), backupBytes = try Data(contentsOf: backup)
            let originalIdentity = try XCTUnwrap(identity.value)
            for target in ["internal_demo", "testing", "staging", "production"] where target != source {
                let foreign = AnalyticsRecorder(directory: dir, identityStore: identity, buildConfiguration: configuration(target))
                foreign.acceptConsent(at: start.addingTimeInterval(20))
                XCTAssertFalse(foreign.enabled, "Must reject \(source) queue under \(target).")
                XCTAssertFalse(foreign.record("tutorial_start", key: "foreign", parameters: ["tutorial_id": "first"]))
                XCTAssertEqual(try Data(contentsOf: queue), originalBytes)
                XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
                XCTAssertEqual(identity.value, originalIdentity)
            }
            let same = AnalyticsRecorder(directory: dir, identityStore: identity, buildConfiguration: configuration(source))
            same.acceptConsent(at: start.addingTimeInterval(30))
            XCTAssertTrue(same.enabled)
            XCTAssertEqual(same.events.filter { $0.eventName == "first_open" }.count, 1)
        }
    }

    @MainActor func testCrossEnvironmentPreparedAndRelatedEventsAreRejectedEvenWithSharedUserID() throws {
        let offer = ["offer_id": "one", "placement_id": "hint", "reward_type": "hint", "buff_type": "hint", "reward_amount": "1", "ad_type": "rewarded", "network": "simulation", "ad_unit_id": "internal-demo"]
        let result = ["offer_id": "one", "placement_id": "hint", "status": "completed", "reward_granted": "true", "error_code": "", "ad_type": "rewarded", "network": "simulation", "ad_unit_id": "internal-demo"]
        for source in ["internal_demo", "testing", "staging", "production"] {
            let identity = BuildEnvironmentMemoryIdentity()
            let original = AnalyticsRecorder(directory: directory(), identityStore: identity, buildConfiguration: configuration(source))
            original.acceptConsent(at: start)
            let prepared = try XCTUnwrap(original.prepare("ad_offer_shown", key: "one", level: 1, config: "isolation-test", parameters: offer, at: start.addingTimeInterval(1)))
            XCTAssertTrue(original.commit(prepared))
            XCTAssertNotNil(original.prepareRelated("ad_result", key: "one:completed", to: prepared.event, parameters: result, at: start.addingTimeInterval(2)))
            for target in ["internal_demo", "testing", "staging", "production"] where target != source {
                let foreign = AnalyticsRecorder(directory: directory(), identityStore: identity, buildConfiguration: configuration(target))
                foreign.acceptConsent(at: start.addingTimeInterval(10))
                XCTAssertTrue(foreign.enabled)
                XCTAssertEqual(foreign.events.last?.userID, prepared.event.userID)
                let before = try foreign.events.map(canonical)
                XCTAssertFalse(foreign.commit(prepared), "Must reject \(source) prepared event under \(target).")
                XCTAssertNil(foreign.prepareRelated("ad_result", key: "one:completed", to: prepared.event, parameters: result, at: start.addingTimeInterval(11)))
                XCTAssertEqual(try foreign.events.map(canonical), before)
            }
        }
    }

    @MainActor func testDemoQueueReopensWithoutRelabelingHistoryOrRepeatingFirstOpen() throws {
        let dir = directory(), identity = BuildEnvironmentMemoryIdentity(), demo = configuration("internal_demo")
        // Freeze the pre-environment queue wire format instead of having the new
        // recorder manufacture its own migration input. No environment metadata
        // exists at queue level; every historical event already carries Demo's tag.
        identity.value = AnalyticsIdentity(userID: "legacy-demo-user", installDate: "2023-11-14", firstOpenRecorded: true)
        var history: [[String: Any]] = []
        let definitions: [(String, [String: Any])] = [
            ("first_open", ["install_source": "internal_demo", "is_reinstall": false]),
            ("session_start", ["entry_source": "cold_start"]),
            ("session_end", ["duration_sec": 3, "end_reason": "quit"])
        ]
        for (index, definition) in definitions.enumerated() {
            history.append(["event_id": "legacy-event-\(index)", "event_name": definition.0,
                "event_time": start.addingTimeInterval(Double(index)).timeIntervalSinceReferenceDate,
                "user_id": "legacy-demo-user", "session_id": "legacy-demo-session", "platform": "iOS",
                "app_version": "0.2.19", "country": "CN", "install_date": "2023-11-14",
                "environment": "internal-demo-offline", "parameters": definition.1])
        }
        let legacyQueue: [String: Any] = ["events": history,
            "keys": ["first_open:legacy-demo-user", "session_start:legacy-demo-session", "session_end:legacy-demo-session"],
            "activeSession": NSNull()]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacyQueue, options: .sortedKeys)
            .write(to: dir.appendingPathComponent("analytics-demo-queue.json"))
        let oldEvents = try JSONDecoder().decode([AnalyticsRecorder.Event].self, from: JSONSerialization.data(withJSONObject: history))
        let before = try Dictionary(uniqueKeysWithValues: oldEvents.map { ($0.eventID, try canonical($0)) })
        let restored = AnalyticsRecorder(directory: dir, identityStore: identity, buildConfiguration: demo)
        restored.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
        XCTAssertTrue(restored.events.allSatisfy { $0.environment == "internal-demo-offline" })
        for (id, data) in before {
            XCTAssertEqual(try canonical(XCTUnwrap(restored.events.first { $0.eventID == id })), data)
        }
    }
}
