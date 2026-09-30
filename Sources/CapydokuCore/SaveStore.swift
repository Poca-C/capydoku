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
    public static let currentSchemaVersion = 3
    public let directory: URL
    public var primaryURL: URL { directory.appendingPathComponent("progress.json") }
    public var backupURL: URL { directory.appendingPathComponent("progress.backup.json") }
    private let lock = NSRecursiveLock()
    private let fileManager: FileManager
    private let packagedPuzzle: ((Int) -> Puzzle?)?
    private let archivedPuzzles: ((Int) -> [Puzzle])?
    // Each board is immutable during play. Keep a small exact-value cache so saving a tap
    // does not repeatedly solve the same board (or the previous board kept as backup).
    private var validatedPuzzles: [Puzzle] = []

    private struct Envelope: Codable {
        var schemaVersion: Int
        var payload: Data
        var checksum: String
    }

    public init(directory: URL? = nil, fileManager: FileManager = .default, packagedPuzzle: ((Int) -> Puzzle?)? = nil, archivedPuzzles: ((Int) -> [Puzzle])? = nil) {
        self.fileManager = fileManager
        self.packagedPuzzle = packagedPuzzle
        self.archivedPuzzles = archivedPuzzles
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
        let payload = try statePayload(progress, encoder: encoder)
        let envelope = Envelope(schemaVersion: Self.currentSchemaVersion, payload: payload,
                                checksum: Self.checksum(payload))
        let data = try encoder.encode(envelope)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: primaryURL.path) {
            let previous = try Data(contentsOf: primaryURL)
            if (try? decode(previous)) != nil {
                // A damaged primary must never overwrite the last known-good backup.
                // Preserve an unusable backup too, before a later good save replaces it.
                if fileManager.fileExists(atPath: backupURL.path) {
                    let oldBackup = try Data(contentsOf: backupURL)
                    if (try? decode(oldBackup)) == nil { try preserveRejected(oldBackup) }
                }
                try previous.write(to: backupURL, options: .atomic)
            } else {
                try preserveRejected(previous)
            }
        }
        try data.write(to: primaryURL, options: .atomic)
    }

    private func preserveRejected(_ data: Data) throws {
        let rejectedURL = directory.appendingPathComponent("progress.preserved-\(Self.checksum(data).prefix(16)).json")
        if !fileManager.fileExists(atPath: rejectedURL.path) {
            try data.write(to: rejectedURL, options: .atomic)
        }
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
            let free = kind == .levelStartFree ? candidate.session?.config.referenceGameplay?.levelStartFreeAd : nil
            candidate.rewardLedger[offerID] = RewardRecord(id: offerID, kind: kind,
                sessionID: candidate.session?.id, inventoryTool: free?.reward, inventoryCount: free?.rewardCount,
                inventoryCarry: free?.inventoryAcrossLevels, quotaKey: kind == .levelStartFree ? candidate.levelStartFreeQuotaKey : nil,
                levelID: kind == .levelStartFree ? candidate.session?.puzzle.id : nil)
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
    public func grantReward(offerID: String, progress: inout PlayerProgress,
                            finalize: ((inout PlayerProgress, RewardOutcome) -> Void)? = nil) throws -> RewardOutcome {
        lock.lock(); defer { lock.unlock() }
        guard let record = progress.rewardLedger[offerID] else { throw SaveStoreError.missingOffer }
        if record.state == .executed || record.state == .compensated { return .duplicate }
        guard record.state == .offered || record.state == .rewarded else { return .ignored }
        if record.state == .offered { _ = try markRewardReceived(offerID: offerID, progress: &progress) }
        return try transaction(progress: &progress) { candidate in
            let outcome = candidate.executeReward(offerID: offerID)
            // A reward can finish a level. Its completion and pending business
            // event must commit with the effect, not in a second vulnerable save.
            finalize?(&candidate, outcome)
            return outcome
        }
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
        let progress = try JSONDecoder().decode(PlayerProgress.self, from: resolvedPayload(envelope.payload))
        try validate(progress)
        return (progress, envelope.schemaVersion < Self.currentSchemaVersion)
    }

    /// The shipped app stores only a reference for packaged boards (§7.4).
    /// Experimental 151+ boards live in an immutable board cache, separate from player state.
    /// A nil resolver keeps the legacy standalone-core encoding available for migration tools.
    private func statePayload(_ progress: PlayerProgress, encoder: JSONEncoder) throws -> Data {
        let data = try encoder.encode(progress)
        guard let packagedPuzzle, let puzzle = progress.session?.puzzle,
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var session = root["session"] as? [String: Any] else { return data }
        let boardData = try encoder.encode(puzzle)
        let digest = Self.checksum(boardData)
        let source: String
        if puzzle.id <= 150 {
            guard packagedPuzzle(puzzle.id) == puzzle || archivedPuzzles?(puzzle.id).contains(puzzle) == true else {
                throw SaveStoreError.invalidState("packaged board does not match this build")
            }
            source = "bundle"
        } else {
            source = "experimental-cache"
            let cache = directory.appendingPathComponent("BoardCache", isDirectory: true)
            try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
            let url = cache.appendingPathComponent(digest + ".json")
            if !fileManager.fileExists(atPath: url.path) { try boardData.write(to: url, options: .atomic) }
        }
        session.removeValue(forKey: "puzzle")
        session["puzzleReference"] = ["levelID": puzzle.id, "source": source, "checksum": digest]
        root["session"] = session
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func resolvedPayload(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var session = root["session"] as? [String: Any],
              let reference = session["puzzleReference"] as? [String: Any] else { return data }
        guard let level = reference["levelID"] as? Int, let source = reference["source"] as? String,
              let digest = reference["checksum"] as? String, digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit }) else { throw SaveStoreError.invalidState("invalid puzzle reference") }
        let boardData: Data
        if source == "bundle", level <= 150 {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let candidates = [packagedPuzzle?(level)].compactMap { $0 } + (archivedPuzzles?(level) ?? [])
            let encoded = try candidates.map { try encoder.encode($0) }
            guard let matching = encoded.first(where: { Self.checksum($0) == digest }) else {
                throw SaveStoreError.invalidState("matching packaged board version is unavailable")
            }
            boardData = matching
        } else if source == "experimental-cache", level >= 151 {
            boardData = try Data(contentsOf: directory.appendingPathComponent("BoardCache/" + digest + ".json"))
        } else { throw SaveStoreError.invalidState("referenced board is unavailable") }
        guard Self.checksum(boardData) == digest else { throw SaveStoreError.checksumMismatch }
        let board = try JSONSerialization.jsonObject(with: boardData)
        guard let dictionary = board as? [String: Any], dictionary["id"] as? Int == level else {
            throw SaveStoreError.invalidState("board reference level mismatch")
        }
        session["puzzle"] = board; session.removeValue(forKey: "puzzleReference")
        root["session"] = session
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func validate(_ progress: PlayerProgress) throws {
        // Leave arithmetic headroom for the next reward, retry, day and level. These are
        // storage safety bounds, not tuning limits imposed on ordinary player progress.
        func counter(_ value: Int) -> Bool { (0...(Int.max / 4)).contains(value) }
        func positive(_ value: Int) -> Bool { value > 0 && counter(value) }
        guard positive(progress.unlockedLevel), positive(progress.currentLevel),
              counter(progress.bonusHints), counter(progress.bonusDirect), counter(progress.tutorialStep),
              counter(progress.carriedToolBalance.hints), counter(progress.carriedToolBalance.direct),
              progress.referenceToolGrantKeys.allSatisfy({ !$0.isEmpty }),
              progress.freeReviveUsage.allSatisfy({ !$0.key.isEmpty && counter($0.value) }),
              progress.pendingLevelResultEvents.allSatisfy({ UUID(uuidString: $0.key) != nil && !$0.value.isEmpty && $0.value.count <= 32_768 }),
              progress.levelStartLocalBalances.allSatisfy({ Int($0.key).map(positive) == true && counter($0.value.hints) && counter($0.value.direct) }),
              counter(progress.checkIn.streak), counter(progress.checkIn.cycleDay),
              counter(progress.checkIn.completedCycles),
              progress.completedLevels.allSatisfy(positive),
              progress.freeToolGrantedLevels.allSatisfy(positive),
              progress.attemptCounts.allSatisfy({ Int($0.key).map(positive) == true && positive($0.value) }),
              progress.levelToolBalances.allSatisfy({ Int($0.key).map(positive) == true && counter($0.value.hints) && counter($0.value.direct) }),
              progress.rewardLedger.allSatisfy({ !$0.key.isEmpty && $0.key == $0.value.id }) else {
            throw SaveStoreError.invalidState("progress, inventory or reward records are out of range")
        }
        for record in progress.rewardLedger.values where record.kind == .levelStartFree {
            guard record.inventoryTool != nil, record.inventoryCarry != nil,
                  record.inventoryCount.map({ (1...10_000).contains($0) }) == true,
                  !(record.quotaKey?.isEmpty ?? true), record.levelID.map(positive) == true else {
                throw SaveStoreError.invalidState("level-start reward is missing its frozen offer snapshot")
            }
        }
        guard let session = progress.session else { return }
        let config = session.config
        if let reference = config.referenceGameplay { try reference.validate(level: session.puzzle.id) }
        let normalized = DemoConfig(version: config.version, initialLives: config.initialLives,
                                    hintsPerLevel: config.hintsPerLevel, directPerLevel: config.directPerLevel,
                                    baseScore: config.baseScore, comboBonus: config.comboBonus,
                                    comboThresholds: config.comboThresholds, dailyHintReward: config.dailyHintReward,
                                    cycleDirectReward: config.cycleDirectReward, checkInCycleDays: config.checkInCycleDays,
                                    generatorBudgetMilliseconds: config.generatorBudgetMilliseconds,
                                    generatorCandidateLimit: config.generatorCandidateLimit, referenceGameplay: config.referenceGameplay)
        guard config == normalized, !config.version.isEmpty,
              counter(config.hintsPerLevel), counter(config.directPerLevel),
              counter(config.dailyHintReward), counter(config.cycleDirectReward),
              positive(config.checkInCycleDays),
              config.baseScore <= Int.max / 4096, config.comboBonus <= Int.max / 4096 else {
            throw SaveStoreError.invalidState("session configuration is outside supported bounds")
        }
        let size = session.puzzle.size
        guard positive(session.puzzle.id), progress.currentLevel == session.puzzle.id,
              (4...PuzzleGenerator.maximumBoardSize).contains(size), session.puzzle.regions.count == size * size,
              session.puzzle.solution.count == size,
              Set(session.puzzle.solution).count == size else {
            throw SaveStoreError.invalidState("invalid board structure")
        }
        let cells = Set(0..<(size * size))
        guard Set(session.puzzle.solution).isSubset(of: cells),
              session.found.isSubset(of: Set(session.puzzle.solution)),
              session.marks.isSubset(of: cells), session.errors.isSubset(of: cells),
              session.errors.isDisjoint(with: Set(session.puzzle.solution)),
              session.errors.isSubset(of: session.marks),
              session.found.isDisjoint(with: session.marks),
              session.lives >= 0, session.lives <= session.config.initialLives,
              counter(session.hintsRemaining), counter(session.directRemaining),
              counter(session.score), (0...session.found.count).contains(session.combo), positive(session.attempt),
              counter(session.resultPhase),
              session.elapsedSeconds.isFinite, session.elapsedSeconds >= 0,
              session.elapsedSeconds < Double(Int.max / 4),
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
        if !validatedPuzzles.contains(session.puzzle) {
            let puzzle = session.puzzle
            guard PuzzleSolver.regionsAreConnected(size: size, regions: puzzle.regions),
                  PuzzleSolver.solutions(size: size, regions: puzzle.regions, limit: 2) == [puzzle.solution.sorted()] else {
                throw SaveStoreError.invalidState("saved board must have connected regions and the recorded unique solution")
            }
            validatedPuzzles.append(puzzle)
            if validatedPuzzles.count > 4 { validatedPuzzles.removeFirst() }
        }
    }
}
