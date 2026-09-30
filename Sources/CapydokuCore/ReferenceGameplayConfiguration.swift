import Foundation
import CryptoKit

/// Imported frozen reference values only. This type deliberately has no gameplay defaults.
/// A template with null configurations is valid evidence of missing input, never a playable baseline.
public struct ReferenceGameplayConfiguration: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case awaitingBaseline = "awaiting_baseline", frozen }
    public var schemaVersion: Int
    public var status: Status
    public var configVersion: String?
    public var baseline: ReferenceGameplayBaseline?
    public var importedSourceSHA256: String?
    public var levels: [ReferenceGameplayLevel]

    public var isReadyForUse: Bool { (try? validate(requireFrozen: true)) != nil }
    public func level(_ number: Int) -> ReferenceLevelGameplay? {
        guard isReadyForUse else { return nil }
        return levels.first { $0.level == number }?.configuration
    }

    public static func load(data: Data, expectedSHA256: String? = nil) throws -> Self {
        if let expectedSHA256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expectedSHA256.lowercased() else {
                throw ReferenceGameplayValidationError("Configuration SHA256 does not match its frozen manifest.")
            }
        }
        let json = try JSONSerialization.jsonObject(with: data)
        try ReferenceGameplayJSONShape.validate(json)
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    public func validate(requireFrozen: Bool = false) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ReferenceGameplayValidationError(message) }
        }
        try require(schemaVersion == 1, "Unsupported gameplay schema version.")
        try require(levels.count == 150 && Set(levels.map(\.level)) == Set(1...150),
                    "Exactly one entry for every level 1–150 is required.")
        if status == .awaitingBaseline {
            try require(!requireFrozen, "Frozen Pawdoku baseline is not supplied; template cannot control gameplay.")
            try require(configVersion == nil && baseline == nil && importedSourceSHA256 == nil,
                        "Awaiting-baseline template must not claim a frozen version or checksum.")
            try require(levels.allSatisfy { $0.configuration == nil }, "Awaiting-baseline template must not contain guessed configuration values.")
            return
        }
        try require(!(configVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), "Frozen configVersion is required.")
        guard let baseline else { throw ReferenceGameplayValidationError("Frozen capture metadata is required.") }
        try baseline.validate()
        try require(Self.isSHA256(importedSourceSHA256), "Imported source SHA256 is required; run the import script.")
        for entry in levels {
            guard let value = entry.configuration else { throw ReferenceGameplayValidationError("Level \(entry.level) has no frozen configuration.") }
            try value.validate(level: entry.level)
        }
    }

    fileprivate static func isSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }
}

public struct ReferenceGameplayValidationError: Error, Equatable, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ReferenceGameplayBaseline: Codable, Equatable, Sendable {
    public var product: String
    public var storeVersion: String
    public var capturedAt: String
    public var device: String
    public var osVersion: String
    /// SHA256 of the archived capture/configuration source supplied by the project owner.
    public var sourceArchiveSHA256: String
    public var evidenceFiles: [String]
    fileprivate func validate() throws {
        let formatter = ISO8601DateFormatter()
        guard product == "Pawdoku", !storeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              formatter.date(from: capturedAt) != nil, (capturedAt.hasSuffix("Z") || capturedAt.hasSuffix("+00:00")),
              ReferenceGameplayConfiguration.isSHA256(sourceArchiveSHA256),
              !evidenceFiles.isEmpty, evidenceFiles.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ReferenceGameplayValidationError("Pawdoku store version, UTC capture time, device/OS, source checksum and evidence files are required.")
        }
    }
}

public struct ReferenceGameplayLevel: Codable, Equatable, Sendable {
    public var level: Int
    public var configuration: ReferenceLevelGameplay?
}

public enum ReferenceInventoryCarry: String, Codable, Sendable { case retain, reset }
public enum ReferenceGrantPolicy: String, Codable, Sendable {
    case oncePerLevel = "once_per_level", everyAttempt = "every_attempt", never
}
public enum ReferenceButtonState: String, Codable, Sendable { case hidden, locked, enabled, disabled }
public enum ReferenceToolKind: String, Codable, Sendable { case directFind = "direct_find", hint }

public struct ReferenceToolConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var visible: Bool
    public var unlockLevel: Int
    public var initialFreeCount: Int
    public var firstUnlockBonusCount: Int
    public var inventoryAcrossLevels: ReferenceInventoryCarry
    public var regrantPolicy: ReferenceGrantPolicy
    public var rewardedAdEnabled: Bool
    public var buttonState: ReferenceButtonState
    public var evidenceID: String
    fileprivate func validate(level: Int, kind: ReferenceToolKind) throws {
        guard unlockLevel >= 1, unlockLevel <= 1_000_000,
              (0...10_000).contains(initialFreeCount), (0...10_000).contains(firstUnlockBonusCount),
              !evidenceID.isEmpty, visible == (buttonState != .hidden),
              !(buttonState == .enabled && (!enabled || level < unlockLevel)),
              !(level < unlockLevel && initialFreeCount > 0) else {
            throw ReferenceGameplayValidationError("Level \(level) \(kind.rawValue): inconsistent unlock/visibility/inventory configuration.")
        }
        if kind == .hint && (!enabled || !visible || unlockLevel != 1) {
            throw ReferenceGameplayValidationError("Hint must be available from level 1 per original requirement 2.2.")
        }
    }
}

public struct ReferenceLevelStartFreeAd: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var visible: Bool
    public var freeCount: Int
    public var reward: ReferenceToolKind
    public var rewardCount: Int
    public var resetPolicy: ReferenceGrantPolicy
    public var inventoryAcrossLevels: ReferenceInventoryCarry
    public var triggerOrder: Int
    public var buttonState: ReferenceButtonState
    public var evidenceID: String
}

public struct ReferenceReviveConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var rewardedAdEnabled: Bool
    public var restoredLives: Int
    public var unlimitedRevives: Bool
    public var freeCount: Int
    public var resetPolicy: ReferenceGrantPolicy
    public var evidenceID: String
}

public struct ReferenceFailureConfiguration: Codable, Equatable, Sendable {
    public var flowID: String
    public var title: String
    public var reviveButtonTitle: String
    public var restartButtonTitle: String
    public var canDismiss: Bool
    public var restartCreatesNewBoard: Bool
    public var evidenceID: String
}

public struct ReferenceInterstitialConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var startLevel: Int
    public var frequency: Int
    public var cooldownSeconds: Int
    public var adTimeoutSeconds: Int
    public var onNextLevel: Bool
    public var onReturnHome: Bool
    public var evidenceID: String
}

public struct ReferenceLevelGameplay: Codable, Equatable, Sendable {
    public var startingLives: Int
    public var directFind: ReferenceToolConfiguration
    public var hint: ReferenceToolConfiguration
    public var levelStartFreeAd: ReferenceLevelStartFreeAd
    public var revive: ReferenceReviveConfiguration
    public var failure: ReferenceFailureConfiguration
    public var interstitial: ReferenceInterstitialConfiguration
    public var adsEnabled: Bool
    public var rewardedAdTimeoutSeconds: Int
    /// Banner stays off until separately reviewed under original requirement 8.1.
    public var bannerEnabled: Bool
    public var bannerReviewEvidenceID: String?

    func validate(level: Int) throws {
        try directFind.validate(level: level, kind: .directFind)
        try hint.validate(level: level, kind: .hint)
        let free = levelStartFreeAd
        guard (1...99).contains(startingLives), (1...120).contains(rewardedAdTimeoutSeconds),
              (!bannerEnabled || !(bannerReviewEvidenceID?.isEmpty ?? true)),
              (0...10_000).contains(free.freeCount), (0...10_000).contains(free.rewardCount),
              free.triggerOrder >= 0, free.triggerOrder <= 100, !free.evidenceID.isEmpty,
              free.visible == (free.buttonState != .hidden),
              !(free.buttonState == .enabled && !free.enabled),
              !(free.enabled && (free.freeCount == 0 || free.rewardCount == 0)),
              (1...99).contains(revive.restoredLives), revive.restoredLives == startingLives,
              revive.unlimitedRevives, (0...10_000).contains(revive.freeCount), !revive.evidenceID.isEmpty,
              !failure.flowID.isEmpty, !failure.title.isEmpty, !failure.reviveButtonTitle.isEmpty,
              !failure.restartButtonTitle.isEmpty, !failure.evidenceID.isEmpty,
              (1...1_000_000).contains(interstitial.startLevel), (1...10_000).contains(interstitial.frequency),
              (0...86_400).contains(interstitial.cooldownSeconds), (1...120).contains(interstitial.adTimeoutSeconds),
              !interstitial.evidenceID.isEmpty else {
            throw ReferenceGameplayValidationError("Level \(level): invalid life, reward, failure or advertising configuration.")
        }
    }
}

/// Reject unknown keys, including competitor maps/answers, instead of JSONDecoder silently dropping them.
private enum ReferenceGameplayJSONShape {
    static let keys: [String: Set<String>] = [
        "root": ["schemaVersion", "status", "configVersion", "baseline", "importedSourceSHA256", "levels"],
        "baseline": ["product", "storeVersion", "capturedAt", "device", "osVersion", "sourceArchiveSHA256", "evidenceFiles"],
        "level": ["level", "configuration"],
        "configuration": ["startingLives", "directFind", "hint", "levelStartFreeAd", "revive", "failure", "interstitial", "adsEnabled", "rewardedAdTimeoutSeconds", "bannerEnabled", "bannerReviewEvidenceID"],
        "tool": ["enabled", "visible", "unlockLevel", "initialFreeCount", "firstUnlockBonusCount", "inventoryAcrossLevels", "regrantPolicy", "rewardedAdEnabled", "buttonState", "evidenceID"],
        "levelStartFreeAd": ["enabled", "visible", "freeCount", "reward", "rewardCount", "resetPolicy", "inventoryAcrossLevels", "triggerOrder", "buttonState", "evidenceID"],
        "revive": ["enabled", "rewardedAdEnabled", "restoredLives", "unlimitedRevives", "freeCount", "resetPolicy", "evidenceID"],
        "failure": ["flowID", "title", "reviveButtonTitle", "restartButtonTitle", "canDismiss", "restartCreatesNewBoard", "evidenceID"],
        "interstitial": ["enabled", "startLevel", "frequency", "cooldownSeconds", "adTimeoutSeconds", "onNextLevel", "onReturnHome", "evidenceID"]
    ]
    static func validate(_ value: Any, type: String = "root", path: String = "$") throws {
        if value is NSNull { return }
        guard let object = value as? [String: Any], let allowed = keys[type] else {
            throw ReferenceGameplayValidationError("\(path): expected configuration object.")
        }
        let extra = Set(object.keys).subtracting(allowed)
        guard extra.isEmpty else {
            throw ReferenceGameplayValidationError("\(path): prohibited or unknown fields \(extra.sorted().joined(separator: ", ")). Competitor maps/answers must never be imported.")
        }
        let missing = allowed.subtracting(object.keys)
        guard missing.isEmpty else {
            throw ReferenceGameplayValidationError("\(path): required fields missing: \(missing.sorted().joined(separator: ", ")). Use explicit null only for pending fields.")
        }
        for (key, child) in object {
            if key == "levels" {
                guard let entries = child as? [Any] else { throw ReferenceGameplayValidationError("levels must be an array.") }
                for (index, entry) in entries.enumerated() { try validate(entry, type: "level", path: "$.levels[\(index)]") }
            } else if ["baseline", "configuration", "levelStartFreeAd", "revive", "failure", "interstitial"].contains(key) {
                try validate(child, type: key, path: "\(path).\(key)")
            } else if key == "directFind" || key == "hint" {
                try validate(child, type: "tool", path: "\(path).\(key)")
            }
        }
    }
}
