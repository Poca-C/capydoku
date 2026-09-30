import Foundation
import CryptoKit

public enum SaveSource: String, Sendable {
    case fresh, primary, backup, resetAfterCorruption
}

public struct SaveLoadResult: Sendable {
    public var progress: PlayerProgress
    public var source: SaveSource
    public var warnings: [String]
    public var didMigrate: Bool
    public var recoveredRewardCount: Int
    public var warning: String? { warnings.isEmpty ? nil : warnings.joined(separator: "\n") }
}

public enum SaveStoreError: LocalizedError {
    case checksumMismatch
    case unsupportedSchema(Int)
    case invalidState(String)
    case missingOffer

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch: return "Save integrity check failed."
        case .unsupportedSchema(let version): return "Save version \(version) is not supported. The original file has been preserved."
        case .invalidState(let reason): return "Invalid save state: \(reason)"
        case .missingOffer: return "The reward receipt could not be found."
        }
    }
}

/// Serial, atomic local persistence. File work is deliberately tiny; callers can use one serial queue.
/// Reward methods persist the receipt before applying its effect and roll back memory if saving fails.
public final class SaveStore: @unchecked Sendable {
    public static let currentSchemaVersion = 2
    public let directory: URL
    public var primaryURL: URL { directory.appendingPathComponent("progress.json") }
    public var backupURL: URL { directory.appendingPathComponent("progress.backup.json") }
    private let lock = NSRecursiveLock()
    private let fileManager: FileManager

    private struct Envelope: Codable {
        var schemaVersion: Int
        var payload: Data
        var checksum: String
    }

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask)[0]
            .appendingPathComponent("Capydoku", isDirectory: true)
    }

    public func load() -> SaveLoadResult {
        lock.lock(); defer { lock.unlock() }
        var warnings: [String] = []
        let primaryExists = fileManager.fileExists(atPath: primaryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)
        guard primaryExists || backupExists else {
            return SaveLoadResult(progress: PlayerProgress(), source: .fresh, warnings: [],
                                  didMigrate: false, recoveredRewardCount: 0)
        }
        for (url, source) in [(primaryURL, SaveSource.primary), (backupURL, SaveSource.backup)] {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                let (decoded, migrated) = try decode(Data(contentsOf: url))
                var progress = decoded
                let beforeRecovery = progress
                let recovered = progress.recoverInterruptedRewards()
                if source == .backup { warnings.append("The primary save was unavailable. Your previous valid backup has been restored.") }
                if recovered > 0 { warnings.append("Recovered \(recovered) interrupted tool reward(s) to your inventory. No board actions were replayed.") }
                if migrated || source == .backup || progress != beforeRecovery {
                    do { try save(progress) }
                    catch { warnings.append("The recovered state could not be saved: \(error.localizedDescription)") }
                }
                return SaveLoadResult(progress: progress, source: source, warnings: warnings,
                                      didMigrate: migrated, recoveredRewardCount: recovered)
            } catch {
                warnings.append("\(source == .primary ? "Primary save" : "Backup") could not be read: \(error.localizedDescription)")
            }
        }
        warnings.append("No valid save could be recovered. Starting with initial progress; damaged or incompatible files have been retained.")
        return SaveLoadResult(progress: PlayerProgress(), source: .resetAfterCorruption,
                              warnings: warnings, didMigrate: false, recoveredRewardCount: 0)
    }

    public func save(_ progress: PlayerProgress) throws {
        lock.lock(); defer { lock.unlock() }
        try validate(progress)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(progress)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, payload: payload,
                                checksum: Self.checksum(payload))
        let data = try encoder.encode(envelope)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: primaryURL.path) {
            let previous = try Data(contentsOf: primaryURL)
            if (try? decode(previous)) != nil {
                // A damaged primary must never overwrite the last known-good backup.
                try previous.write(to: backupURL, options: .atomic)
            } else {
                let rejectedURL = directory.appendingPathComponent("progress.preserved-\(Self.checksum(previous).prefix(16)).json")
                if !fileManager.fileExists(atPath: rejectedURL.path) {
                    try previous.write(to: rejectedURL, options: .atomic)
                }
            }
        }
        try data.write(to: primaryURL, options: .atomic)
    }

    /// General mutation with commit-on-success semantics, useful for check-in and settings.
    @discardableResult
    public func transaction<T>(progress: inout PlayerProgress,
                               mutation: (inout PlayerProgress) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var candidate = progress
        let result = try mutation(&candidate)
        candidate.captureSessionBalance()
        try save(candidate)
        progress = candidate
        return result
    }

    @discardableResult
    public func prepareReward(offerID: String, kind: RewardKind,
                              progress: inout PlayerProgress) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !offerID.isEmpty, progress.rewardLedger[offerID] == nil,
              progress.canReceiveReward(kind) else { return false }
        return try transaction(progress: &progress) { candidate in
            candidate.rewardLedger[offerID] = RewardRecord(id: offerID, kind: kind,
                                                          sessionID: candidate.session?.id)
            return true
        }
    }

    /// Separate receipt phase enables testing a kill between callback and effect execution.
    @discardableResult
    public func markRewardReceived(offerID: String, progress: inout PlayerProgress) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let record = progress.rewardLedger[offerID] else { throw SaveStoreError.missingOffer }
        guard record.state == .offered else { return false }
        return try transaction(progress: &progress) { candidate in
            candidate.rewardLedger[offerID]?.state = .rewarded
            return true
        }
    }

    @discardableResult
    public func grantReward(offerID: String, progress: inout PlayerProgress) throws -> RewardOutcome {
        lock.lock(); defer { lock.unlock() }
        guard let record = progress.rewardLedger[offerID] else { throw SaveStoreError.missingOffer }
        if record.state == .executed || record.state == .compensated { return .duplicate }
        guard record.state == .offered || record.state == .rewarded else { return .ignored }
        if record.state == .offered { _ = try markRewardReceived(offerID: offerID, progress: &progress) }
        return try transaction(progress: &progress) { candidate in candidate.executeReward(offerID: offerID) }
    }

    @discardableResult
    public func cancelReward(offerID: String, progress: inout PlayerProgress) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard progress.rewardLedger[offerID]?.state == .offered else { return false }
        return try transaction(progress: &progress) { candidate in
            candidate.rewardLedger[offerID]?.state = .cancelled
            return true
        }
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ data: Data) throws -> (PlayerProgress, Bool) {
        guard data.count < 8_000_000 else { throw SaveStoreError.invalidState("file is too large") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard (1...Self.currentSchemaVersion).contains(envelope.schemaVersion) else {
            throw SaveStoreError.unsupportedSchema(envelope.schemaVersion)
        }
        guard Self.checksum(envelope.payload) == envelope.checksum else { throw SaveStoreError.checksumMismatch }
        // Schema 1 used the same JSON payload without optional tracking fields. Their decoding defaults
        // preserve inventory, check-in and completion; version 2 adds grant and reward recovery records.
        let progress = try JSONDecoder().decode(PlayerProgress.self, from: envelope.payload)
        try validate(progress)
        return (progress, envelope.schemaVersion < Self.currentSchemaVersion)
    }

    private func validate(_ progress: PlayerProgress) throws {
        guard progress.unlockedLevel > 0, progress.currentLevel > 0,
              progress.bonusHints >= 0, progress.bonusDirect >= 0,
              progress.checkIn.streak >= 0, progress.checkIn.cycleDay >= 0,
              progress.attemptCounts.values.allSatisfy({ $0 > 0 }),
              progress.levelToolBalances.values.allSatisfy({ $0.hints >= 0 && $0.direct >= 0 }),
              progress.rewardLedger.allSatisfy({ $0.key == $0.value.id }) else {
            throw SaveStoreError.invalidState("progress, inventory or reward records are out of range")
        }
        guard let session = progress.session else { return }
        let size = session.puzzle.size
        guard (2...16).contains(size), session.puzzle.regions.count == size * size,
              session.puzzle.solution.count == size,
              Set(session.puzzle.solution).count == size else {
            throw SaveStoreError.invalidState("invalid board structure")
        }
        let cells = Set(0..<(size * size))
        guard Set(session.puzzle.solution).isSubset(of: cells),
              session.found.isSubset(of: Set(session.puzzle.solution)),
              session.marks.isSubset(of: cells), session.errors.isSubset(of: cells),
              session.errors.isDisjoint(with: Set(session.puzzle.solution)),
              session.found.isDisjoint(with: session.marks),
              session.lives >= 0, session.lives <= session.config.initialLives,
              session.hintsRemaining >= 0, session.directRemaining >= 0,
              session.score >= 0, session.combo >= 0, session.attempt > 0,
              session.elapsedSeconds.isFinite, session.elapsedSeconds >= 0,
              session.config.initialLives > 0, session.config.checkInCycleDays > 0 else {
            throw SaveStoreError.invalidState("session values are out of range")
        }
        if session.status == .lost && session.lives != 0 {
            throw SaveStoreError.invalidState("lost status does not match remaining lives")
        }
        if session.status == .won && (session.remainingCount != 0 || session.lives == 0) {
            throw SaveStoreError.invalidState("won status does not match board state")
        }
        if session.status == .playing && (session.lives == 0 || session.remainingCount == 0) {
            throw SaveStoreError.invalidState("playing status does not match board state")
        }
    }
}
