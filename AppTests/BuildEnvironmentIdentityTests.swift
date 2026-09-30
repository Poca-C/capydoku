import XCTest
import Security
import CryptoKit
@testable import Capydoku

/// Uses real Keychain services, with random test-owned directories and complete
/// cleanup. This verifies environment namespacing inside the test host; distinct
/// installed-app access groups require separate build/install verification.
final class BuildEnvironmentIdentityTests: XCTestCase {
    private var directories: [URL: String] = [:]
    private var services = Set<String>()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        // Also discover a service if an assertion threw before stableService().
        for (directory, prefix) in directories {
            let namespace = directory.appendingPathComponent("analytics-identity-namespace.json")
            for path in [namespace, namespace.appendingPathExtension("backup")] {
                if let data = try? Data(contentsOf: path),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = object["id"] as? String {
                    services.insert(prefix + id)
                }
            }
        }
        for service in services {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: "anonymous-install"] as CFDictionary)
        }
        for directory in directories.keys { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func configuration(_ environment: String) -> AppBuildConfiguration {
        AppBuildConfiguration(info: ["CapydokuEnvironment": environment, "CapydokuAnalyticsEnabled": true],
                              bundleIdentifier: "com.capydoku.identity-test." + environment)
    }

    private func directory(for configuration: AppBuildConfiguration) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("environment-keychain-test-" + UUID().uuidString)
        directories[directory] = configuration.identityServicePrefix
        return directory
    }

    private func legacyService(_ directory: URL) -> String {
        let hash = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        let service = "com.capydoku.demo.analytics.internal." + hash
        services.insert(service)
        return service
    }

    private func stableService(_ directory: URL, configuration: AppBuildConfiguration) throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent("analytics-identity-namespace.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let id = try XCTUnwrap(object["id"] as? String)
        XCTAssertNotNil(UUID(uuidString: id))
        let service = configuration.identityServicePrefix + id
        services.insert(service)
        return service
    }

    private func keychainData(_ service: String) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "anonymous-install", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess, "Real Keychain read failed: \(status); do not replace this path with an in-memory identity.")
        return try XCTUnwrap(result as? Data)
    }

    private func canonical(_ event: AnalyticsRecorder.Event) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(event)
    }

    @MainActor func testTestingBuildDoesNotAdoptExistingLegacyDemoIdentityWithoutQueue() throws {
        let configuration = configuration("testing"), directory = directory(for: configuration)
        let oldService = legacyService(directory), oldStore = KeychainAnalyticsIdentityStore(service: oldService)
        let oldIdentity = AnalyticsIdentity(userID: "legacy-demo-test-" + UUID().uuidString,
                                            installDate: "2022-04-01", firstOpenRecorded: true)
        XCTAssertTrue(oldStore.save(oldIdentity), "This test requires the real signed simulator Keychain entitlement.")
        let originalBytes = try keychainData(oldService)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let recorder = AnalyticsRecorder(directory: directory, buildConfiguration: configuration)
        XCTAssertFalse(recorder.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        recorder.acceptConsent(at: start)
        XCTAssertTrue(recorder.enabled)
        let newIdentity = try XCTUnwrap(recorder.events.first)
        XCTAssertNotEqual(newIdentity.userID, oldIdentity.userID)
        XCTAssertNotEqual(newIdentity.installDate, oldIdentity.installDate)
        XCTAssertEqual(newIdentity.environment, "testing-offline")
        XCTAssertEqual(recorder.events.filter { $0.eventName == "first_open" }.count, 1)
        let newService = try stableService(directory, configuration: configuration)
        XCTAssertNotEqual(newService, oldService)
        let savedIdentity = try JSONDecoder().decode(AnalyticsIdentity.self, from: keychainData(newService))
        XCTAssertEqual(savedIdentity.userID, newIdentity.userID)
        XCTAssertTrue(savedIdentity.firstOpenRecorded)
        XCTAssertEqual(try keychainData(oldService), originalBytes)
        XCTAssertEqual(oldStore.load(), oldIdentity)
    }

    @MainActor func testStagingIdentityAndHistoricalEventsSurviveContainerMoveAndColdStart() throws {
        let configuration = configuration("staging"), original = directory(for: configuration), moved = directory(for: configuration)
        let recorder = AnalyticsRecorder(directory: original, buildConfiguration: configuration)
        recorder.acceptConsent(at: start)
        XCTAssertTrue(recorder.enabled, "This test requires the real signed simulator Keychain entitlement.")
        XCTAssertTrue(recorder.record("tutorial_start", key: "before-move", parameters: ["tutorial_id": "first"], at: start.addingTimeInterval(5)))
        let oldService = try stableService(original, configuration: configuration)
        let identity = try JSONDecoder().decode(AnalyticsIdentity.self, from: keychainData(oldService))
        let history = try recorder.events.map(canonical)
        let prepared = try XCTUnwrap(recorder.prepare("tutorial_end", key: "pending-before-move", parameters: ["tutorial_id": "first", "result": "quit", "duration_sec": "5"], at: start.addingTimeInterval(6)))
        let namespace = try Data(contentsOf: original.appendingPathComponent("analytics-identity-namespace.json"))

        try FileManager.default.moveItem(at: original, to: moved)
        let restored = AnalyticsRecorder(directory: moved, buildConfiguration: configuration)
        XCTAssertFalse(restored.enabled)
        restored.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(try stableService(moved, configuration: configuration), oldService)
        XCTAssertEqual(try JSONDecoder().decode(AnalyticsIdentity.self, from: keychainData(oldService)), identity)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("analytics-identity-namespace.json")), namespace)
        XCTAssertEqual(try restored.events.prefix(history.count).map(canonical), history)
        XCTAssertTrue(restored.commit(prepared))
        XCTAssertTrue(restored.commit(prepared))
        let committed = try XCTUnwrap(restored.events.first { $0.eventID == prepared.event.eventID })
        XCTAssertEqual(try canonical(committed), try canonical(prepared.event))
        XCTAssertEqual(restored.events.filter { $0.eventID == prepared.event.eventID }.count, 1)
        XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
        XCTAssertEqual(Set(restored.events.map(\.userID)).count, 1)
        XCTAssertTrue(restored.events.allSatisfy { $0.environment == "staging-offline" })

        let cold = AnalyticsRecorder(directory: moved, buildConfiguration: configuration)
        cold.acceptConsent(at: start.addingTimeInterval(120))
        XCTAssertTrue(cold.enabled)
        XCTAssertEqual(try stableService(moved, configuration: configuration), oldService)
        XCTAssertEqual(cold.events.filter { $0.eventName == "first_open" }.count, 1)
        XCTAssertEqual(try cold.events.prefix(history.count).map(canonical), history)
        XCTAssertEqual(try canonical(XCTUnwrap(cold.events.first { $0.eventID == prepared.event.eventID })), try canonical(prepared.event))
        XCTAssertEqual(try JSONDecoder().decode(AnalyticsIdentity.self, from: keychainData(oldService)), identity)
    }
}
