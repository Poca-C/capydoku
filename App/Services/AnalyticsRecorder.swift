import Foundation
import Security
import CryptoKit

struct AnalyticsIdentity: Codable, Equatable {
    let userID: String
    let installDate: String
    var firstOpenRecorded: Bool
}
protocol AnalyticsIdentityStore {
    func load() -> AnalyticsIdentity?
    func save(_ identity: AnalyticsIdentity) -> Bool
}
struct KeychainAnalyticsIdentityStore: AnalyticsIdentityStore {
    let service: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "anonymous-install"]
    }
    func load() -> AnalyticsIdentity? { try? checkedLoad() }
    func checkedLoad() throws -> AnalyticsIdentity? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let identity = try? JSONDecoder().decode(AnalyticsIdentity.self, from: data),
              !identity.userID.isEmpty, !identity.installDate.isEmpty else {
            throw LocalAnalyticsIdentity.Error.keychainUnavailable
        }
        return identity
    }
    func save(_ identity: AnalyticsIdentity) -> Bool {
        guard let data = try? JSONEncoder().encode(identity) else { return false }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = query; insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

/// A directory carries an opaque namespace when the OS relocates its container.
/// The anonymous identity itself remains in Keychain. Resolution and migration
/// are called only after consent; missing evidence never creates a replacement ID.
private enum LocalAnalyticsIdentity {
    enum Error: Swift.Error {
        case namespaceUnavailable, namespaceConflict, keychainUnavailable, identityUnavailable, identityConflict
    }
    enum Phase: String, Codable { case pending, committed }
    struct Namespace: Codable, Equatable {
        let version: Int
        let id: UUID
        var phase: Phase
        init(id: UUID) { self.version = 1; self.id = id; self.phase = .pending }
        private enum CodingKeys: String, CodingKey { case version, id, phase }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            id = try values.decode(UUID.self, forKey: .id)
            // Existing version 1 files predate the phase field. They may have
            // collected events already, so absence never means a fresh install.
            phase = try values.decodeIfPresent(Phase.self, forKey: .phase) ?? .committed
        }
    }
    static let legacyPrefix = "com.capydoku.demo.analytics.internal."
    static let prefix = "com.capydoku.demo.analytics.namespace."
    static func legacyService(directory: URL) -> String {
        let hash = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return legacyPrefix + hash
    }
    static func resolve(directory: URL, expected: AnalyticsIdentity?, hasPreviousQueue: Bool,
                        at date: Date) throws -> (KeychainAnalyticsIdentityStore, AnalyticsIdentity) {
        var namespace = try readNamespace(directory: directory)
        let store = KeychainAnalyticsIdentityStore(service: prefix + namespace.id.uuidString)
        var identity = try store.checkedLoad()
        if let current = identity, let expected,
           (current.userID != expected.userID || current.installDate != expected.installDate) {
            throw Error.identityConflict
        }
        if identity == nil {
            // A committed namespace proves an identity previously existed. If
            // both Keychain and queue ownership are lost, neither an old path
            // alias nor a fresh ID can prove continuity.
            guard namespace.phase == .pending || expected != nil else { throw Error.identityUnavailable }
            let legacy = try KeychainAnalyticsIdentityStore(service: legacyService(directory: directory)).checkedLoad()
            if let expected {
                // Search only this app's old namespace, and only for the saved
                // current session's owner. Other test/install identities cannot match.
                var candidates = try legacyIdentities(matching: expected.userID)
                if let legacy, legacy.userID == expected.userID { candidates.append(legacy) }
                guard let first = candidates.first else { throw Error.identityUnavailable }
                guard first.installDate == expected.installDate,
                      candidates.allSatisfy({ $0 == first }) else { throw Error.identityConflict }
                identity = first
            } else if let legacy {
                identity = legacy
            } else {
                guard !hasPreviousQueue else { throw Error.identityUnavailable }
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                identity = AnalyticsIdentity(userID: UUID().uuidString, installDate: formatter.string(from: date), firstOpenRecorded: false)
            }
        }
        guard let identity else { throw Error.identityUnavailable }
        // Persist the namespace before writing Keychain or events. A disk failure
        // must not enable collection with an identity that cannot be found again.
        try persistNamespace(namespace, directory: directory)
        guard store.save(identity) else { throw Error.keychainUnavailable }
        if namespace.phase == .pending {
            namespace.phase = .committed
            // Collection remains off until this marker is durable. If either
            // copy fails, retry must retain the Keychain identity just saved.
            try persistNamespace(namespace, directory: directory)
        }
        return (store, identity)
    }
    private static func readNamespace(directory: URL) throws -> Namespace {
        let url = directory.appendingPathComponent("analytics-identity-namespace.json")
        let backup = url.appendingPathExtension("backup")
        let existing = [url, backup].filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty { return Namespace(id: UUID()) }
        let candidates = existing.compactMap { path -> Namespace? in
            guard let data = try? Data(contentsOf: path),
                  let namespace = try? JSONDecoder().decode(Namespace.self, from: data),
                  namespace.version == 1 else { return nil }
            return namespace
        }
        guard var first = candidates.first else { throw Error.namespaceUnavailable }
        guard candidates.allSatisfy({ $0.id == first.id && $0.version == first.version }) else { throw Error.namespaceConflict }
        // A crash may leave one copy committed and one pending. Never regress
        // the established state while repairing the other copy.
        if candidates.contains(where: { $0.phase == .committed }) { first.phase = .committed }
        return first
    }
    private static func persistNamespace(_ namespace: Namespace, directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("analytics-identity-namespace.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(namespace)
            // The namespace ID is immutable; phase only advances to committed.
            // Repair copies without changing the established identity scope.
            for target in [url, url.appendingPathExtension("backup")] {
                if let previous = try? Data(contentsOf: target),
                   let decoded = try? JSONDecoder().decode(Namespace.self, from: previous), decoded == namespace { continue }
                try data.write(to: target, options: .atomic)
            }
        } catch { throw Error.namespaceUnavailable }
    }
    private static func legacyIdentities(matching userID: String) throws -> [AnalyticsIdentity] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "anonymous-install", kSecReturnAttributes as String: true,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw Error.keychainUnavailable }
        return rows.compactMap { row in
            guard let service = row[kSecAttrService as String] as? String, service.hasPrefix(legacyPrefix),
                  let data = row[kSecValueData as String] as? Data,
                  let identity = try? JSONDecoder().decode(AnalyticsIdentity.self, from: data),
                  identity.userID == userID else { return nil }
            return identity
        }
    }
}

/// SDK-independent local event contract for original section 6. No transport or network calls.
/// A live adapter can consume this queue after consent with its own test/production source.
@MainActor
final class AnalyticsRecorder {
    enum Value: Codable, Equatable {
        case text(String), integer(Int), flag(Bool)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
            else if let number = try? value.decode(Int.self) { self = .integer(number) }
            else { self = .text(try value.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self { case .text(let text): try value.encode(text); case .integer(let number): try value.encode(number); case .flag(let flag): try value.encode(flag) }
        }
    }
    struct Event: Codable {
        let eventID: String
        let eventName: String
        let eventTime: Date
        let userID: String
        let sessionID: String
        let platform: String
        let appVersion: String
        let country: String
        let installDate: String
        let environment: String
        let levelID: Int?
        let pawdokuConfigVersion: String?
        var parameters: [String: Value]
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", eventName = "event_name", eventTime = "event_time", userID = "user_id", sessionID = "session_id"
            case platform, appVersion = "app_version", country, installDate = "install_date", environment
            case levelID = "level_id", pawdokuConfigVersion = "pawdoku_config_version", parameters
        }
    }
    /// Frozen with the gameplay save before delivery. Recovery must retain the
    /// original event, user, analytics session and occurrence time.
    struct PreparedEvent: Codable {
        let key: String
        var event: Event
    }
    private struct Cache: Codable {
        var events: [Event] = []
        var keys: Set<String> = []
        var activeSession: PersistedSession?
    }
    private struct PersistedSession: Codable {
        var id: String
        var startedAt: Date
        var lastActiveAt: Date
        var activePeriodStartedAt: Date
        var activeSeconds: TimeInterval = 0
        var backgroundAt: Date?
        func duration(at date: Date) -> Int {
            let current = backgroundAt == nil ? max(0, date.timeIntervalSince(activePeriodStartedAt)) : 0
            return Int(max(0, min(Double(Int.max / 2), activeSeconds + current)))
        }
    }
    private static let supported: Set<String> = ["first_open", "session_start", "session_end", "tutorial_start", "tutorial_end", "level_start", "level_end", "level_restart", "ad_offer_shown", "ad_result", "buff_use"]
    private let url: URL
    private var identityStore: AnalyticsIdentityStore?
    private let usesLocalIdentity: Bool
    private var hasPreviousQueue = false
    private var queueUnreadable = false
    private var identity: AnalyticsIdentity?
    private var cache = Cache()
    /// Provisional internal-test timeout. The frozen production session timeout is not supplied.
    private let sessionTimeout: TimeInterval
    private var hasPendingWrite = false
    private(set) var enabled = false
    private(set) var lastError: String?
    var events: [Event] { cache.events }

    init(directory: URL, identityStore: AnalyticsIdentityStore? = nil, sessionTimeout: TimeInterval = 300) {
        url = directory.appendingPathComponent("analytics-demo-queue.json")
        self.identityStore = identityStore
        self.usesLocalIdentity = identityStore == nil
        self.sessionTimeout = sessionTimeout.isFinite ? max(1, sessionTimeout) : 300
        let backup = url.appendingPathExtension("backup")
        hasPreviousQueue = FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: backup.path)
        if hasPreviousQueue {
            do { cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: url)) }
            catch {
                lastError = "Local event queue could not be read; the original file is preserved."
                if let data = try? Data(contentsOf: backup), let loaded = try? JSONDecoder().decode(Cache.self, from: data) { cache = loaded }
                else { queueUnreadable = true }
                let preserved = url.deletingLastPathComponent().appendingPathComponent("analytics-preserved-\(UUID().uuidString).json")
                try? FileManager.default.copyItem(at: url, to: preserved)
            }
        }
    }
    func acceptConsent(at date: Date = Date()) {
        guard !enabled else { _ = retryPendingWrites(); return }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if usesLocalIdentity {
            do {
                guard !queueUnreadable else { throw LocalAnalyticsIdentity.Error.identityUnavailable }
                let owner: Event?
                if let active = cache.activeSession {
                    guard let event = cache.events.last(where: { $0.sessionID == active.id }) else {
                        throw LocalAnalyticsIdentity.Error.identityUnavailable
                    }
                    owner = event
                } else { owner = cache.events.last }
                let expected = owner.map { AnalyticsIdentity(userID: $0.userID, installDate: $0.installDate, firstOpenRecorded: false) }
                let resolved = try LocalAnalyticsIdentity.resolve(directory: url.deletingLastPathComponent(), expected: expected,
                                                                   hasPreviousQueue: hasPreviousQueue, at: date)
                identityStore = resolved.0; identity = resolved.1
            } catch {
                lastError = "Anonymous analytics identity could not be recovered; collection is disabled to preserve existing event ownership."
                return
            }
        } else {
            identity = identityStore?.load() ?? AnalyticsIdentity(userID: UUID().uuidString, installDate: formatter.string(from: date), firstOpenRecorded: false)
            guard let identity, identityStore?.save(identity) == true else { lastError = "Anonymous analytics identity could not be saved."; return }
        }
        enabled = true
        // Recover a persisted interruption before starting a new cold-start session.
        if let previous = cache.activeSession {
            _ = record("session_start", key: previous.id, parameters: ["entry_source": "cold_start"], at: previous.startedAt)
            guard finishSession(reason: previous.backgroundAt == nil ? "quit" : "background", at: previous.backgroundAt ?? previous.lastActiveAt) else { return }
        }
        beginSession(source: "cold_start", at: date)
    }
    func beginSession(source: String, at date: Date = Date()) {
        guard enabled, ["cold_start", "resume"].contains(source), var identity else { return }
        if var current = cache.activeSession {
            guard let background = current.backgroundAt else { _ = retryPendingWrites(); return }
            if date.timeIntervalSince(background) < sessionTimeout && date >= background {
                current.backgroundAt = nil; current.activePeriodStartedAt = date; current.lastActiveAt = date
                cache.activeSession = current; hasPendingWrite = true; _ = retryPendingWrites()
                return
            }
            guard finishSession(reason: "background", at: background) else { return }
        }
        let sessionID = UUID().uuidString
        cache.activeSession = PersistedSession(id: sessionID, startedAt: date, lastActiveAt: date, activePeriodStartedAt: date)
        if !identity.firstOpenRecorded {
            if record("first_open", key: identity.userID, parameters: ["install_source": "internal_demo", "is_reinstall": "false"], at: date) {
                identity.firstOpenRecorded = true; _ = identityStore?.save(identity); self.identity = identity
            }
        }
        _ = record("session_start", key: sessionID, parameters: ["entry_source": source], at: date)
    }
    func endSession(reason: String, at date: Date = Date()) {
        guard enabled, var current = cache.activeSession else { return }
        if reason == "background" {
            guard current.backgroundAt == nil else { return }
            current.activeSeconds += max(0, date.timeIntervalSince(current.activePeriodStartedAt))
            current.backgroundAt = date; current.lastActiveAt = max(date, current.lastActiveAt)
            cache.activeSession = current; hasPendingWrite = true; _ = retryPendingWrites()
        } else {
            _ = finishSession(reason: reason, at: date)
        }
    }
    private func finishSession(reason: String, at date: Date) -> Bool {
        guard let current = cache.activeSession else { return true }
        _ = record("session_end", key: current.id,
                   parameters: ["duration_sec": "\(current.duration(at: date))", "end_reason": reason], at: date)
        // record returns false both for rejected events and for accepted events
        // awaiting a disk retry. Only rejection should block the lifecycle: once
        // the old end is queued, new events must belong to a new session even if
        // storage is temporarily unavailable. The original queued IDs and times
        // are retained and committed together when writing succeeds again.
        guard cache.keys.contains("session_end:" + current.id) else { return false }
        cache.activeSession = nil; hasPendingWrite = true
        _ = retryPendingWrites()
        return true
    }
    @discardableResult
    func record(_ name: String, key: String, level: Int? = nil, config: String? = nil,
                parameters: [String: String], at date: Date = Date()) -> Bool {
        guard let prepared = prepare(name, key: key, level: level, config: config, parameters: parameters, at: date) else { return false }
        return commit(prepared)
    }

    func prepare(_ name: String, key: String, level: Int? = nil, config: String? = nil,
                 parameters: [String: String], at date: Date = Date()) -> PreparedEvent? {
        guard enabled, Self.supported.contains(name), !key.isEmpty, let identity, let session = cache.activeSession else { return nil }
        let levelEvent = ["level_start", "level_end", "level_restart", "ad_offer_shown", "ad_result", "buff_use"].contains(name)
        guard !levelEvent || ((level ?? 0) > 0 && !(config ?? "").isEmpty),
              let typed = Self.validateParameters(name: name, parameters: parameters) else { lastError = "Event contract rejected \(name)."; return nil }
        let eventKey = name + ":" + key
        let event = Event(eventID: UUID().uuidString, eventName: name, eventTime: date, userID: identity.userID,
                          sessionID: session.id, platform: "iOS",
                          appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "internal",
                          country: Locale.current.regionCode ?? "ZZ", installDate: identity.installDate,
                          environment: "internal-demo-offline", levelID: level, pawdokuConfigVersion: config, parameters: typed)
        return PreparedEvent(key: eventKey, event: event)
    }

    /// True only once the event is durably queued, including an already queued
    /// duplicate. A failed write must not acknowledge the gameplay outbox.
    @discardableResult func commit(_ prepared: PreparedEvent) -> Bool {
        guard enabled, let identity, identity.userID == prepared.event.userID else { return false }
        if cache.keys.contains(prepared.key) { return retryPendingWrites() }
        cache.events.append(prepared.event); cache.keys.insert(prepared.key)
        if let current = cache.activeSession, current.id == prepared.event.sessionID {
            cache.activeSession?.lastActiveAt = max(prepared.event.eventTime, current.lastActiveAt)
        }
        hasPendingWrite = true
        return retryPendingWrites()
    }

    /// Complete an offer or record its direct effect using frozen attribution,
    /// even if the foreground analytics session changed during the ad.
    func prepareRelated(_ name: String, key: String, to original: Event,
                        parameters: [String: String], at date: Date = Date()) -> PreparedEvent? {
        guard enabled, identity?.userID == original.userID, !key.isEmpty,
              ["ad_result", "buff_use"].contains(name),
              let typed = Self.validateParameters(name: name, parameters: parameters) else { return nil }
        let event = Event(eventID: UUID().uuidString, eventName: name, eventTime: date,
            userID: original.userID, sessionID: original.sessionID, platform: original.platform,
            appVersion: original.appVersion, country: original.country, installDate: original.installDate,
            environment: original.environment, levelID: original.levelID,
            pawdokuConfigVersion: original.pawdokuConfigVersion, parameters: typed)
        return PreparedEvent(key: name + ":" + key, event: event)
    }

    /// Retains failed writes in memory with original IDs/timestamps; a later lifecycle/event retries them.
    @discardableResult func retryPendingWrites() -> Bool {
        guard enabled else { return false }
        guard hasPendingWrite else { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let previous = try? Data(contentsOf: url), (try? JSONDecoder().decode(Cache.self, from: previous)) != nil {
                try previous.write(to: url.appendingPathExtension("backup"), options: .atomic)
            }
            try JSONEncoder().encode(cache).write(to: url, options: .atomic)
            hasPendingWrite = false; lastError = nil
            return true
        } catch { lastError = "Local event queue could not be saved."; return false }
    }

    private enum Field {
        case string, integer, boolean, choice(Set<String>)
    }
    private static func validateParameters(name: String, parameters: [String: String]) -> [String: Value]? {
        let string = Field.string, integer = Field.integer, boolean = Field.boolean
        let tool: Set<String> = ["direct_find", "hint"]
        let placement: Set<String> = ["direct_find", "hint", "revive", "level_start_free"]
        let schemas: [String: [String: Field]] = [
            "first_open": ["install_source": string, "is_reinstall": boolean],
            "session_start": ["entry_source": .choice(["cold_start", "resume"])],
            "session_end": ["duration_sec": integer, "end_reason": .choice(["background", "quit", "timeout"])],
            "tutorial_start": ["tutorial_id": string],
            "tutorial_end": ["tutorial_id": string, "result": .choice(["complete", "quit"]), "duration_sec": integer],
            "level_start": ["attempt_no": integer, "grid_size": string, "is_tutorial": boolean, "direct_find_visible": boolean, "direct_find_inventory": integer, "hint_inventory": integer, "level_start_free_available": boolean],
            "level_end": ["result": .choice(["win", "lose", "quit"]), "duration_sec": integer, "attempt_no": integer, "fail_reason": .choice(["", "life_zero", "quit", "unknown"]), "life_remaining": integer],
            "level_restart": ["restart_reason": .choice(["after_fail", "manual"]), "previous_fail_reason": .choice(["", "life_zero", "quit", "unknown"]), "next_attempt_no": integer],
            "ad_offer_shown": ["offer_id": string, "placement_id": string, "reward_type": string, "buff_type": .choice(tool.union([""])), "reward_amount": integer, "ad_type": .choice(["rewarded", "interstitial"]), "network": string, "ad_unit_id": string],
            "ad_result": ["offer_id": string, "placement_id": string, "status": .choice(["started", "completed", "skipped", "failed"]), "reward_granted": boolean, "error_code": string, "ad_type": .choice(["rewarded", "interstitial"]), "network": string, "ad_unit_id": string],
            "buff_use": ["buff_type": .choice(tool), "source": .choice(["initial_free", "level_config_free", "rewarded_ad"]), "applied": boolean, "inventory_before": integer, "inventory_after": integer]
        ]
        guard let schema = schemas[name], Set(parameters.keys) == Set(schema.keys) else { return nil }
        var result: [String: Value] = [:]
        for (key, field) in schema {
            let value = parameters[key]!
            switch field {
            case .string: result[key] = .text(value)
            case .integer:
                guard let number = Int(value), number >= 0 else { return nil }
                result[key] = .integer(number)
            case .boolean:
                guard value == "true" || value == "false" else { return nil }
                result[key] = .flag(value == "true")
            case .choice(let choices):
                guard choices.contains(value) else { return nil }
                result[key] = .text(value)
            }
        }
        if let attempt = parameters["attempt_no"], (Int(attempt) ?? 0) < 1 { return nil }
        if let attempt = parameters["next_attempt_no"], (Int(attempt) ?? 0) < 1 { return nil }
        if let offer = parameters["offer_id"], offer.isEmpty { return nil }
        if let tutorial = parameters["tutorial_id"], tutorial.isEmpty { return nil }
        if let adType = parameters["ad_type"] {
            if adType == "rewarded" {
                guard placement.contains(parameters["placement_id"] ?? "") else { return nil }
            } else {
                // Original [448] requires interstitial events but never names
                // their placement enum. Accept an explicit adapter mapping;
                // never borrow a rewarded placement or invent a game reward.
                let identifier = parameters["placement_id"] ?? ""
                guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      identifier.count <= 128, !placement.contains(identifier) else { return nil }
                if name == "ad_offer_shown" {
                    guard parameters["reward_amount"] == "0", parameters["reward_type"] == "",
                          parameters["buff_type"] == "" else { return nil }
                } else if parameters["reward_granted"] != "false" { return nil }
            }
        }
        if name == "ad_result", parameters["reward_granted"] == "true", parameters["status"] != "completed" { return nil }
        if name == "level_end", parameters["result"] == "win", parameters["fail_reason"] != "" { return nil }
        if name == "buff_use", parameters["buff_type"] == "direct_find", parameters["applied"] != "true" { return nil }
        return result
    }
}
