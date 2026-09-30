import Foundation
import Security
import CryptoKit

struct AnalyticsIdentity: Codable {
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
    func load() -> AnalyticsIdentity? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AnalyticsIdentity.self, from: data)
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
        let parameters: [String: Value]
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", eventName = "event_name", eventTime = "event_time", userID = "user_id", sessionID = "session_id"
            case platform, appVersion = "app_version", country, installDate = "install_date", environment
            case levelID = "level_id", pawdokuConfigVersion = "pawdoku_config_version", parameters
        }
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
    private let identityStore: AnalyticsIdentityStore
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
        let namespace = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        self.identityStore = identityStore ?? KeychainAnalyticsIdentityStore(service: "com.capydoku.demo.analytics.internal." + namespace)
        self.sessionTimeout = sessionTimeout.isFinite ? max(1, sessionTimeout) : 300
        if FileManager.default.fileExists(atPath: url.path) {
            do { cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: url)) }
            catch {
                lastError = "Local event queue could not be read; the original file is preserved."
                let backup = url.appendingPathExtension("backup")
                if let data = try? Data(contentsOf: backup), let loaded = try? JSONDecoder().decode(Cache.self, from: data) { cache = loaded }
                let preserved = url.deletingLastPathComponent().appendingPathComponent("analytics-preserved-\(UUID().uuidString).json")
                try? FileManager.default.copyItem(at: url, to: preserved)
            }
        }
    }
    func acceptConsent(at date: Date = Date()) {
        guard !enabled else { _ = retryPendingWrites(); return }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        identity = identityStore.load() ?? AnalyticsIdentity(userID: UUID().uuidString, installDate: formatter.string(from: date), firstOpenRecorded: false)
        guard let identity, identityStore.save(identity) else { lastError = "Anonymous analytics identity could not be saved."; return }
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
                identity.firstOpenRecorded = true; _ = identityStore.save(identity); self.identity = identity
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
        guard record("session_end", key: current.id,
                     parameters: ["duration_sec": "\(current.duration(at: date))", "end_reason": reason], at: date) else { return false }
        cache.activeSession = nil; hasPendingWrite = true
        return retryPendingWrites()
    }
    @discardableResult
    func record(_ name: String, key: String, level: Int? = nil, config: String? = nil,
                parameters: [String: String], at date: Date = Date()) -> Bool {
        guard enabled, Self.supported.contains(name), !key.isEmpty, let identity, let session = cache.activeSession else { return false }
        let levelEvent = ["level_start", "level_end", "level_restart", "ad_offer_shown", "ad_result", "buff_use"].contains(name)
        guard !levelEvent || ((level ?? 0) > 0 && !(config ?? "").isEmpty),
              let typed = Self.validateParameters(name: name, parameters: parameters) else { lastError = "Event contract rejected \(name)."; return false }
        let eventKey = name + ":" + key
        if cache.keys.contains(eventKey) { return retryPendingWrites() }
        let event = Event(eventID: UUID().uuidString, eventName: name, eventTime: date, userID: identity.userID,
                          sessionID: session.id, platform: "iOS",
                          appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "internal",
                          country: Locale.current.regionCode ?? "ZZ", installDate: identity.installDate,
                          environment: "internal-demo-offline", levelID: level, pawdokuConfigVersion: config, parameters: typed)
        cache.events.append(event); cache.keys.insert(eventKey)
        cache.activeSession?.lastActiveAt = max(date, session.lastActiveAt)
        hasPendingWrite = true
        return retryPendingWrites()
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
            "ad_offer_shown": ["offer_id": string, "placement_id": .choice(placement), "reward_type": string, "buff_type": .choice(tool.union([""])), "reward_amount": integer, "ad_type": .choice(["rewarded", "interstitial"]), "network": string, "ad_unit_id": string],
            "ad_result": ["offer_id": string, "placement_id": .choice(placement), "status": .choice(["started", "completed", "skipped", "failed"]), "reward_granted": boolean, "error_code": string, "ad_type": .choice(["rewarded", "interstitial"]), "network": string, "ad_unit_id": string],
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
        if name == "ad_result", parameters["reward_granted"] == "true", parameters["status"] != "completed" { return nil }
        if name == "level_end", parameters["result"] == "win", parameters["fail_reason"] != "" { return nil }
        if name == "buff_use", parameters["buff_type"] == "direct_find", parameters["applied"] != "true" { return nil }
        return result
    }
}
