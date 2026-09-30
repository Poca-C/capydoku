import XCTest
import Security
import CryptoKit
@testable import Capydoku

/// Exercises the production default Keychain path, including OS-style container
/// moves. Every service created here is random/test-owned and deleted afterward.
final class AnalyticsIdentityMigrationTests: XCTestCase {
    private var directories: [URL] = []
    private var services = Set<String>()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() {
        for directory in directories {
            for suffix in ["", ".backup"] {
                if let data = try? Data(contentsOf: namespaceURL(directory).appendingPathExtensionIfNeeded(suffix)),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = object["id"] as? String {
                    services.insert("com.capydoku.demo.analytics.namespace." + id)
                }
            }
        }
        for service in services { delete(service: service) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }
    private func directory() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("analytics-identity-test-" + UUID().uuidString)
        directories.append(value)
        return value
    }
    private func namespaceURL(_ directory: URL) -> URL { directory.appendingPathComponent("analytics-identity-namespace.json") }
    private func queueURL(_ directory: URL) -> URL { directory.appendingPathComponent("analytics-demo-queue.json") }
    private func legacyStore(_ directory: URL) -> KeychainAnalyticsIdentityStore {
        let hash = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let service = "com.capydoku.demo.analytics.internal." + hash
        services.insert(service)
        return KeychainAnalyticsIdentityStore(service: service)
    }
    private func delete(service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: "anonymous-install"] as CFDictionary)
    }
    private func canonical(_ event: AnalyticsRecorder.Event) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(event)
    }
    @MainActor private func oldRecorder(_ directory: URL) -> (AnalyticsRecorder, KeychainAnalyticsIdentityStore) {
        let store = legacyStore(directory)
        let recorder = AnalyticsRecorder(directory: directory, identityStore: store)
        recorder.acceptConsent(at: start)
        XCTAssertTrue(recorder.enabled)
        return (recorder, store)
    }
    private func stableService(_ directory: URL) throws -> String {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: namespaceURL(directory))) as? [String: Any])
        let service = "com.capydoku.demo.analytics.namespace." + (try XCTUnwrap(object["id"] as? String))
        services.insert(service)
        return service
    }

    @MainActor func test00RealKeychainAccessHasRequiredEntitlement() throws {
        let service = legacyStore(directory()).service
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "anonymous-install",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data("anonymous-identity-test-probe".utf8)]
        let status = SecItemAdd(query as CFDictionary, nil)
        let explanation = SecCopyErrorMessageString(status, nil) as String? ?? "No system description"
        XCTAssertEqual(status, errSecSuccess, "Real Keychain access failed: OSStatus \(status) (\(explanation)). Check the simulator app signature and Keychain entitlement; identity tests must not silently use a mock.")
    }

    @MainActor func testDefaultIdentityHasNoDiskOrKeychainCreationBeforeConsent() throws {
        let dir = directory(), legacy = legacyStore(dir)
        let recorder = AnalyticsRecorder(directory: dir)
        XCTAssertFalse(recorder.enabled)
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertNil(legacy.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNil(recorder.prepare("tutorial_start", key: "unconsented", parameters: ["tutorial_id": "first"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    @MainActor func testFreshDirectoriesUseSeparatePersistentIdentities() throws {
        let a = directory(), b = directory()
        let first = AnalyticsRecorder(directory: a), second = AnalyticsRecorder(directory: b)
        first.acceptConsent(at: start); second.acceptConsent(at: start)
        XCTAssertTrue(first.enabled); XCTAssertTrue(second.enabled)
        XCTAssertNotEqual(try stableService(a), try stableService(b))
        XCTAssertNotEqual(first.events.first?.userID, second.events.first?.userID)
        let restored = AnalyticsRecorder(directory: a)
        restored.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertEqual(restored.events.last?.userID, first.events.first?.userID)
        XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
        let namespace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: namespaceURL(a))) as? [String: Any])
        XCTAssertEqual(Set(namespace.keys), ["version", "id", "phase"], "Local namespace must not store the user identity.")
    }

    @MainActor func testContainerMovePreservesIdentityAndPreparedEventAttribution() throws {
        let original = directory(), moved = directory()
        let recorder = AnalyticsRecorder(directory: original)
        recorder.acceptConsent(at: start)
        _ = try stableService(original)
        let previous = try recorder.events.map(canonical)
        let prepared = try XCTUnwrap(recorder.prepare("tutorial_start", key: "outbox", parameters: ["tutorial_id": "first"], at: start.addingTimeInterval(5)))
        try FileManager.default.moveItem(at: original, to: moved)
        let restored = AnalyticsRecorder(directory: moved)
        restored.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(try restored.events.prefix(previous.count).map(canonical), previous)
        XCTAssertTrue(restored.commit(prepared)); XCTAssertTrue(restored.commit(prepared))
        let committed = try XCTUnwrap(restored.events.first { $0.eventID == prepared.event.eventID })
        XCTAssertEqual(try canonical(committed), try canonical(prepared.event))
        XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
        XCTAssertEqual(Set(restored.events.map(\.userID)).count, 1)
    }

    @MainActor func testLegacyCurrentPathMigratesOnlyAfterConsentWithoutChangingHistory() throws {
        let dir = directory(), (old, store) = oldRecorder(dir)
        let previous = try old.events.map(canonical)
        let saved = try XCTUnwrap(store.load())
        let recorder = AnalyticsRecorder(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespaceURL(dir).path))
        XCTAssertFalse(recorder.enabled)
        recorder.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertTrue(recorder.enabled)
        XCTAssertEqual(KeychainAnalyticsIdentityStore(service: try stableService(dir)).load(), saved)
        XCTAssertEqual(try recorder.events.prefix(previous.count).map(canonical), previous)
        XCTAssertEqual(recorder.events.filter { $0.eventName == "first_open" }.count, 1)
    }

    @MainActor func testMovedLegacyQueueFindsExactOwnerAndIgnoresUnrelatedCurrentPathIdentity() throws {
        let original = directory(), moved = directory(), (old, oldStore) = oldRecorder(original)
        let prepared = try XCTUnwrap(old.prepare("tutorial_start", key: "before-move", parameters: ["tutorial_id": "first"], at: start.addingTimeInterval(5)))
        let expected = try XCTUnwrap(oldStore.load())
        let unrelated = legacyStore(moved)
        XCTAssertTrue(unrelated.save(AnalyticsIdentity(userID: UUID().uuidString, installDate: "2020-01-01", firstOpenRecorded: true)))
        try FileManager.default.moveItem(at: original, to: moved)
        let recorder = AnalyticsRecorder(directory: moved)
        recorder.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertTrue(recorder.enabled)
        XCTAssertEqual(recorder.events.last?.userID, expected.userID)
        XCTAssertEqual(recorder.events.last?.installDate, expected.installDate)
        XCTAssertTrue(recorder.commit(prepared))
        XCTAssertEqual(recorder.events.filter { $0.eventName == "first_open" }.count, 1)
    }

    @MainActor func testIdenticalLegacyAliasesMigrateButConflictingIdentityMetadataStopsCollection() throws {
        let original = directory(), moved = directory(), alias = directory()
        let (_, oldStore) = oldRecorder(original), saved = try XCTUnwrap(oldStore.load())
        let otherStore = legacyStore(alias)
        XCTAssertTrue(otherStore.save(saved))
        try FileManager.default.moveItem(at: original, to: moved)
        let success = AnalyticsRecorder(directory: moved)
        success.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertTrue(success.enabled)
        // A separate unchanged legacy queue with the same known owner proves
        // contradictory metadata is rejected, not silently selected by order.
        let conflicting = directory()
        try FileManager.default.createDirectory(at: conflicting, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: queueURL(moved), to: queueURL(conflicting))
        XCTAssertTrue(otherStore.save(AnalyticsIdentity(userID: saved.userID, installDate: "1999-01-01", firstOpenRecorded: saved.firstOpenRecorded)))
        let before = try Data(contentsOf: queueURL(conflicting))
        let rejected = AnalyticsRecorder(directory: conflicting)
        rejected.acceptConsent(at: start.addingTimeInterval(90))
        XCTAssertFalse(rejected.enabled); XCTAssertNotNil(rejected.lastError)
        XCTAssertEqual(try Data(contentsOf: queueURL(conflicting)), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespaceURL(conflicting).path))
    }

    @MainActor func testMissingLegacyOwnerStopsCollectionThenCanRetryWithRecoveredKeychain() throws {
        let original = directory(), moved = directory(), unrelated = directory()
        let (old, store) = oldRecorder(original), expected = try XCTUnwrap(store.load())
        let prepared = try XCTUnwrap(old.prepare("tutorial_start", key: "saved-outbox", parameters: ["tutorial_id": "first"]))
        _ = oldRecorder(unrelated)
        try FileManager.default.moveItem(at: original, to: moved)
        delete(service: store.service)
        let bytes = try Data(contentsOf: queueURL(moved))
        let recorder = AnalyticsRecorder(directory: moved)
        recorder.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertFalse(recorder.enabled); XCTAssertNotNil(recorder.lastError)
        XCTAssertFalse(recorder.commit(prepared))
        XCTAssertEqual(try Data(contentsOf: queueURL(moved)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespaceURL(moved).path))
        XCTAssertTrue(store.save(expected))
        recorder.acceptConsent(at: start.addingTimeInterval(90))
        XCTAssertTrue(recorder.enabled); XCTAssertTrue(recorder.commit(prepared))
        XCTAssertEqual(recorder.events.filter { $0.eventName == "first_open" }.count, 1)
    }

    @MainActor func testNamespaceBackupRecoversCorruptOrMissingPrimaryAcrossMove() throws {
        for corruption in [true, false] {
            let original = directory(), moved = directory(), recorder = AnalyticsRecorder(directory: original)
            recorder.acceptConsent(at: start)
            let expected = try stableService(original), bytes = try Data(contentsOf: namespaceURL(original))
            if corruption { try Data("broken namespace".utf8).write(to: namespaceURL(original)) }
            else { try FileManager.default.removeItem(at: namespaceURL(original)) }
            try FileManager.default.moveItem(at: original, to: moved)
            let restored = AnalyticsRecorder(directory: moved)
            restored.acceptConsent(at: start.addingTimeInterval(60))
            XCTAssertTrue(restored.enabled)
            XCTAssertEqual(try stableService(moved), expected)
            XCTAssertEqual(try Data(contentsOf: namespaceURL(moved)), bytes)
            XCTAssertEqual(restored.events.last?.userID, recorder.events.first?.userID)
            XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
        }
    }

    @MainActor func testUnrecoverableOrConflictingNamespacesNeverSwitchIdentity() throws {
        for conflict in [true, false] {
            let dir = directory(), recorder = AnalyticsRecorder(directory: dir)
            recorder.acceptConsent(at: start)
            _ = try stableService(dir)
            let url = namespaceURL(dir), before = try Data(contentsOf: queueURL(dir))
            if conflict {
                let data = try JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString])
                try data.write(to: url.appendingPathExtension("backup"))
            } else {
                try Data("bad primary".utf8).write(to: url)
                try Data("bad backup".utf8).write(to: url.appendingPathExtension("backup"))
            }
            let restored = AnalyticsRecorder(directory: dir)
            restored.acceptConsent(at: start.addingTimeInterval(60))
            XCTAssertFalse(restored.enabled); XCTAssertNotNil(restored.lastError)
            XCTAssertEqual(try Data(contentsOf: queueURL(dir)), before)
            XCTAssertEqual(restored.events.map(\.eventID), recorder.events.map(\.eventID))
        }
    }

    @MainActor func testNamespaceWriteFailureDoesNotCreateEventsAndRetriesWithoutSwitchingIdentity() throws {
        for blockBackup in [true, false] {
            let dir = directory(), url = namespaceURL(dir)
            if blockBackup {
                try FileManager.default.createDirectory(at: url.appendingPathExtension("backup"), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["version": 1, "id": UUID().uuidString, "phase": "pending"]).write(to: url)
            } else { try Data("blocked directory".utf8).write(to: dir) }
            let recorder = AnalyticsRecorder(directory: dir)
            recorder.acceptConsent(at: start)
            XCTAssertFalse(recorder.enabled); XCTAssertTrue(recorder.events.isEmpty); XCTAssertNotNil(recorder.lastError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL(dir).path))
            if blockBackup {
                XCTAssertNil(KeychainAnalyticsIdentityStore(service: try stableService(dir)).load())
                try FileManager.default.removeItem(at: url.appendingPathExtension("backup"))
            }
            else { try FileManager.default.removeItem(at: dir) }
            recorder.acceptConsent(at: start.addingTimeInterval(60))
            XCTAssertTrue(recorder.enabled)
            XCTAssertEqual(recorder.events.filter { $0.eventName == "first_open" }.count, 1)
            _ = try stableService(dir)
        }
    }

    @MainActor func testCorruptStableKeychainDoesNotFallBackToFreshOrLegacyIdentity() throws {
        let dir = directory(), recorder = AnalyticsRecorder(directory: dir)
        recorder.acceptConsent(at: start)
        let service = try stableService(dir), before = try Data(contentsOf: queueURL(dir))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "anonymous-install"]
        XCTAssertEqual(SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data("corrupt".utf8)] as CFDictionary), errSecSuccess)
        let restored = AnalyticsRecorder(directory: dir)
        restored.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertFalse(restored.enabled); XCTAssertNotNil(restored.lastError)
        XCTAssertEqual(try Data(contentsOf: queueURL(dir)), before)
    }

    @MainActor func testCurrentActiveSessionOwnerTakesPrecedenceOverLaterHistoricalOutboxEvent() throws {
        let dir = directory(), foreignDir = directory(), moved = directory()
        let (active, currentStore) = oldRecorder(dir), (foreign, _) = oldRecorder(foreignDir)
        let currentOwner = try XCTUnwrap(currentStore.load())
        let foreignEvent = try XCTUnwrap(foreign.events.last)
        var queue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: queueURL(dir))) as? [String: Any])
        var events = try XCTUnwrap(queue["events"] as? [[String: Any]])
        events.append(try XCTUnwrap(JSONSerialization.jsonObject(with: canonical(foreignEvent)) as? [String: Any]))
        queue["events"] = events
        try JSONSerialization.data(withJSONObject: queue).write(to: queueURL(dir))
        try FileManager.default.moveItem(at: dir, to: moved)
        let recorder = AnalyticsRecorder(directory: moved)
        recorder.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertTrue(recorder.enabled)
        XCTAssertEqual(recorder.events.last?.userID, currentOwner.userID)
        XCTAssertEqual(recorder.events[active.events.count].userID, foreignEvent.userID)
        XCTAssertEqual(try canonical(recorder.events[active.events.count]), try canonical(foreignEvent))
        XCTAssertEqual(recorder.events.filter { $0.eventName == "first_open" && $0.userID == currentOwner.userID }.count, 1)
    }

    @MainActor func testMissingQueuePrimaryUsesBackupWithoutChangingItsIdentity() throws {
        let original = directory(), moved = directory(), (old, _) = oldRecorder(original)
        XCTAssertTrue(old.record("tutorial_start", key: "activity", parameters: ["tutorial_id": "first"]))
        try FileManager.default.removeItem(at: queueURL(original))
        try FileManager.default.moveItem(at: original, to: moved)
        let recorder = AnalyticsRecorder(directory: moved)
        recorder.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertTrue(recorder.enabled)
        XCTAssertEqual(recorder.events.last?.userID, old.events.first?.userID)
        XCTAssertEqual(recorder.events.filter { $0.eventName == "first_open" }.count, 1)
    }

    @MainActor func testUnreadableLegacyQueueDoesNotCreateNewIdentityEvenWhenOldKeychainExists() throws {
        let dir = directory(), (_, store) = oldRecorder(dir)
        let saved = try XCTUnwrap(store.load())
        for path in [queueURL(dir), queueURL(dir).appendingPathExtension("backup")] {
            try Data("broken queue".utf8).write(to: path)
        }
        let recorder = AnalyticsRecorder(directory: dir)
        recorder.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertFalse(recorder.enabled); XCTAssertNotNil(recorder.lastError)
        XCTAssertEqual(store.load(), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespaceURL(dir).path))
    }

    @MainActor func testCommittedNamespaceWithoutKeychainOrQueueNeverAdoptsLegacyOrCreatesReplacement() throws {
        for hasUnrelatedLegacy in [false, true] {
            let dir = directory(), original = AnalyticsRecorder(directory: dir)
            original.acceptConsent(at: start)
            let service = try stableService(dir), store = KeychainAnalyticsIdentityStore(service: service)
            let saved = try XCTUnwrap(store.load()), namespace = try Data(contentsOf: namespaceURL(dir))
            delete(service: service)
            for path in [queueURL(dir), queueURL(dir).appendingPathExtension("backup")] {
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            }
            if hasUnrelatedLegacy {
                XCTAssertTrue(legacyStore(dir).save(AnalyticsIdentity(userID: UUID().uuidString, installDate: "1999-01-01", firstOpenRecorded: true)))
            }
            let restored = AnalyticsRecorder(directory: dir)
            restored.acceptConsent(at: start.addingTimeInterval(60))
            XCTAssertFalse(restored.enabled); XCTAssertNotNil(restored.lastError)
            XCTAssertTrue(restored.events.isEmpty)
            XCTAssertNil(store.load())
            XCTAssertEqual(try Data(contentsOf: namespaceURL(dir)), namespace)
            XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL(dir).path))
            // Restoring the exact Keychain identity permits retry without any
            // new first_open, even though deleted event history cannot be restored.
            XCTAssertTrue(store.save(saved))
            restored.acceptConsent(at: start.addingTimeInterval(90))
            XCTAssertTrue(restored.enabled)
            XCTAssertEqual(restored.events.last?.userID, saved.userID)
            XCTAssertTrue(restored.events.allSatisfy { $0.eventName != "first_open" })
        }
    }

    @MainActor func testLegacyNamespaceWithoutPhaseIsTreatedAsCommitted() throws {
        for loseIdentity in [false, true] {
            let dir = directory(), original = AnalyticsRecorder(directory: dir)
            original.acceptConsent(at: start)
            let service = try stableService(dir), saved = try XCTUnwrap(KeychainAnalyticsIdentityStore(service: service).load())
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: namespaceURL(dir))) as? [String: Any])
            object.removeValue(forKey: "phase")
            let legacyData = try JSONSerialization.data(withJSONObject: object)
            for path in [namespaceURL(dir), namespaceURL(dir).appendingPathExtension("backup")] { try legacyData.write(to: path) }
            if loseIdentity {
                delete(service: service)
                for path in [queueURL(dir), queueURL(dir).appendingPathExtension("backup")] {
                    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                }
            }
            let restored = AnalyticsRecorder(directory: dir)
            restored.acceptConsent(at: start.addingTimeInterval(60))
            XCTAssertEqual(restored.enabled, !loseIdentity)
            if loseIdentity {
                XCTAssertNotNil(restored.lastError); XCTAssertTrue(restored.events.isEmpty)
                XCTAssertNil(KeychainAnalyticsIdentityStore(service: service).load())
            } else {
                XCTAssertEqual(restored.events.last?.userID, saved.userID)
                XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
            }
        }
    }

    @MainActor func testMixedCommitStagesAreMonotonicInEitherCopyAndDoNotAllowMissingIdentity() throws {
        for primaryCommitted in [false, true] {
            let dir = directory(), original = AnalyticsRecorder(directory: dir)
            original.acceptConsent(at: start)
            let service = try stableService(dir), store = KeychainAnalyticsIdentityStore(service: service)
            let saved = try XCTUnwrap(store.load())
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: namespaceURL(dir))) as? [String: Any])
            for (path, committed) in [(namespaceURL(dir), primaryCommitted), (namespaceURL(dir).appendingPathExtension("backup"), !primaryCommitted)] {
                object["phase"] = committed ? "committed" : "pending"
                try JSONSerialization.data(withJSONObject: object).write(to: path)
            }
            delete(service: service)
            for path in [queueURL(dir), queueURL(dir).appendingPathExtension("backup")] {
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            }
            let restored = AnalyticsRecorder(directory: dir)
            restored.acceptConsent(at: start.addingTimeInterval(60))
            XCTAssertFalse(restored.enabled); XCTAssertTrue(restored.events.isEmpty)
            XCTAssertNil(store.load(), "A pending copy must never downgrade evidence of an established identity.")
            XCTAssertTrue(store.save(saved))
            restored.acceptConsent(at: start.addingTimeInterval(90))
            XCTAssertTrue(restored.enabled)
            XCTAssertEqual(restored.events.last?.userID, saved.userID)
            for path in [namespaceURL(dir), namespaceURL(dir).appendingPathExtension("backup")] {
                let repaired = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
                XCTAssertEqual(repaired["phase"] as? String, "committed")
            }
        }
    }

    @MainActor func testPendingMarkerWithSavedKeychainDoesNotCollectUntilDiskRecoversAndReusesIdentity() throws {
        let dir = directory(), url = namespaceURL(dir), id = UUID().uuidString
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Recreate the durable state of an interrupted commit: the identity was
        // saved, but the pending marker did not finish transitioning on disk.
        try JSONSerialization.data(withJSONObject: ["version": 1, "id": id, "phase": "pending"]).write(to: url)
        let service = try stableService(dir), store = KeychainAnalyticsIdentityStore(service: service)
        let saved = AnalyticsIdentity(userID: UUID().uuidString, installDate: "2023-11-14", firstOpenRecorded: false)
        XCTAssertTrue(store.save(saved))
        let backup = url.appendingPathExtension("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("blocks atomic replacement".utf8).write(to: backup.appendingPathComponent("blocker"))
        let restored = AnalyticsRecorder(directory: dir)
        restored.acceptConsent(at: start)
        XCTAssertFalse(restored.enabled); XCTAssertNotNil(restored.lastError); XCTAssertTrue(restored.events.isEmpty)
        XCTAssertEqual(store.load(), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL(dir).path))
        try FileManager.default.removeItem(at: backup)
        restored.acceptConsent(at: start.addingTimeInterval(60))
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.events.last?.userID, saved.userID)
        XCTAssertEqual(restored.events.last?.installDate, saved.installDate)
        XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
        for path in [url, backup] {
            let committed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            XCTAssertEqual(committed["id"] as? String, id)
            XCTAssertEqual(committed["phase"] as? String, "committed")
        }
    }

    @MainActor func testInjectedStoreRemainsIndependentOfLocalNamespaceResolution() throws {
        let dir = directory(), store = legacyStore(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("deliberately invalid namespace".utf8).write(to: namespaceURL(dir))
        let recorder = AnalyticsRecorder(directory: dir, identityStore: store)
        recorder.acceptConsent(at: start)
        XCTAssertTrue(recorder.enabled)
        XCTAssertEqual(recorder.events.filter { $0.eventName == "first_open" }.count, 1)
        XCTAssertEqual(try Data(contentsOf: namespaceURL(dir)), Data("deliberately invalid namespace".utf8))
    }
}

private extension URL {
    func appendingPathExtensionIfNeeded(_ suffix: String) -> URL {
        suffix.isEmpty ? self : appendingPathExtension(String(suffix.dropFirst()))
    }
}
