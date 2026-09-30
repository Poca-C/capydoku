import Foundation

public enum RewardKind: String, Codable, CaseIterable, Sendable {
    case direct, hint, revive, levelStartFree
}

public enum RewardState: String, Codable, Sendable {
    case offered, rewarded, executed, compensated, cancelled
}

public struct RewardRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: RewardKind
    public var state: RewardState
    public var sessionID: UUID?
    public var createdAt: Date
    /// Frozen at offer creation so interrupted rewards do not read a later configuration.
    public var inventoryTool: ReferenceToolKind?
    public var inventoryCount: Int?
    public var inventoryCarry: ReferenceInventoryCarry?
    public var quotaKey: String?
    public var levelID: Int?

    public init(id: String, kind: RewardKind, state: RewardState = .offered,
                sessionID: UUID?, createdAt: Date = Date(), inventoryTool: ReferenceToolKind? = nil,
                inventoryCount: Int? = nil, inventoryCarry: ReferenceInventoryCarry? = nil, quotaKey: String? = nil, levelID: Int? = nil) {
        self.id = id
        self.kind = kind
        self.state = state
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.inventoryTool = inventoryTool
        self.inventoryCount = inventoryCount
        self.inventoryCarry = inventoryCarry
        self.quotaKey = quotaKey
        self.levelID = levelID
    }
}

public enum RewardOutcome: Equatable, Sendable {
    case directRevealed(Int), hintReady, revived, inventoryGranted, duplicate, compensated, ignored
}

public struct ToolBalance: Codable, Equatable, Sendable {
    public var hints: Int
    public var direct: Int
    public init(hints: Int, direct: Int) { self.hints = hints; self.direct = direct }
}

public struct CheckInState: Codable, Equatable, Sendable {
    /// UTC day ordinal, not a locale-dependent string. A claimed future date prevents rollback rewards.
    public var lastClaimedDay: Int?
    public var streak: Int
    public var cycleDay: Int
    public var completedCycles: Int
    public init(lastClaimedDay: Int? = nil, streak: Int = 0,
                cycleDay: Int = 0, completedCycles: Int = 0) {
        self.lastClaimedDay = lastClaimedDay
        self.streak = streak
        self.cycleDay = cycleDay
        self.completedCycles = completedCycles
    }
    public static func utcDay(for date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / 86_400))
    }
    public func canClaim(on date: Date = Date()) -> Bool {
        guard let lastClaimedDay else { return true }
        return Self.utcDay(for: date) > lastClaimedDay
    }
}

public enum CheckInOutcome: Equatable, Sendable {
    case claimed(streak: Int, cycleDay: Int, hints: Int, direct: Int)
    case alreadyClaimed, clockRollback
}

public struct PlayerProgress: Codable, Equatable, Sendable {
    public var unlockedLevel: Int
    public var currentLevel: Int
    public var completedLevels: Set<Int>
    public var attemptCounts: [String: Int]
    public var session: GameSession?
    public var settings: GameSettings
    public var tutorialStep: Int
    public var tutorialCompleted: Bool
    public var checkIn: CheckInState
    public var bonusHints: Int
    public var bonusDirect: Int
    public var rewardLedger: [String: RewardRecord]
    public var freeToolGrantedLevels: Set<Int>
    public var levelToolBalances: [String: ToolBalance]
    public var referenceToolGrantKeys: Set<String>
    public var carriedToolBalance: ToolBalance
    public var levelStartLocalBalances: [String: ToolBalance]
    public var freeReviveUsage: [String: Int]
    private var bonusToolSources: ToolInventorySources
    private var levelToolSources: [String: ToolInventorySources]
    private var carriedToolSources: ToolInventorySources

    public init() {
        unlockedLevel = 1
        currentLevel = 1
        completedLevels = []
        attemptCounts = [:]
        session = nil
        settings = GameSettings()
        tutorialStep = 0
        tutorialCompleted = false
        checkIn = CheckInState()
        bonusHints = 0
        bonusDirect = 0
        rewardLedger = [:]
        freeToolGrantedLevels = []
        levelToolBalances = [:]
        referenceToolGrantKeys = []
        carriedToolBalance = ToolBalance(hints: 0, direct: 0)
        levelStartLocalBalances = [:]
        freeReviveUsage = [:]
        bonusToolSources = ToolInventorySources()
        levelToolSources = [:]
        carriedToolSources = ToolInventorySources()
    }

    public var availableHints: Int {
        (session?.hintsRemaining ?? 0) + bonusHints + currentLevelStartBalance.hints + (session?.pendingRewardHint == true ? 1 : 0)
    }
    public var availableDirect: Int { (session?.directRemaining ?? 0) + bonusDirect + currentLevelStartBalance.direct }
    private var currentLevelStartBalance: ToolBalance {
        levelStartLocalBalances[String(currentLevel)] ?? ToolBalance(hints: 0, direct: 0)
    }

    /// Read immediately before a successful use. Nil means no usable stock or
    /// unknown attribution (for example, a migrated mixed bonus inventory).
    public var nextDirectSource: ToolInventorySource? {
        guard let session, session.status == .playing, session.directToolEnabled, session.remainingCount > 0 else { return nil }
        if currentLevelStartBalance.direct > 0 { return .rewardedAd }
        if session.directRemaining > 0 {
            return levelToolSources[String(session.puzzle.id)]?.direct.matching(session.directRemaining).nextSource
        }
        return bonusToolSources.direct.matching(bonusDirect).nextSource
    }

    public var nextHintSource: ToolInventorySource? {
        guard let session, session.status == .playing, session.hintToolEnabled, session.hasUnmarkedExclusions else { return nil }
        if session.pendingRewardHint || currentLevelStartBalance.hints > 0 { return .rewardedAd }
        if session.hintsRemaining > 0 {
            return levelToolSources[String(session.puzzle.id)]?.hints.matching(session.hintsRemaining).nextSource
        }
        return bonusToolSources.hints.matching(bonusHints).nextSource
    }

    public mutating func begin(puzzle: Puzzle, config: DemoConfig = .default) {
        _ = recoverInterruptedRewards()
        captureSessionBalance()
        let key = String(puzzle.id)
        if currentLevel != puzzle.id { levelStartLocalBalances.removeValue(forKey: String(currentLevel)) }
        let attempt = (attemptCounts[key] ?? 0) + 1
        let firstGrant = !freeToolGrantedLevels.contains(puzzle.id)
        var next = GameSession(puzzle: puzzle, config: config, attempt: attempt, grantFreeTools: firstGrant)
        var nextSources = ToolInventorySources()
        if let reference = config.referenceGameplay {
            let sameLevel = currentLevel == puzzle.id && (session != nil || levelToolBalances[key] != nil)
            let existing = levelToolBalances[key] ?? ToolBalance(hints: 0, direct: 0)
            let hintsBase = sameLevel ? existing.hints : (reference.hint.inventoryAcrossLevels == .retain ? carriedToolBalance.hints : 0)
            let directBase = sameLevel ? existing.direct : (reference.directFind.inventoryAcrossLevels == .retain ? carriedToolBalance.direct : 0)
            let existingSources = (levelToolSources[key] ?? ToolInventorySources()).matching(existing)
            let carriedSources = carriedToolSources.matching(carriedToolBalance)
            nextSources.hints = (sameLevel ? existingSources.hints : carriedSources.hints).matching(hintsBase)
            nextSources.direct = (sameLevel ? existingSources.direct : carriedSources.direct).matching(directBase)
            let hintGrant = referenceGrant(reference.hint, kind: .hint, level: puzzle.id)
            let directGrant = referenceGrant(reference.directFind, kind: .directFind, level: puzzle.id)
            let hints = hintsBase + (hintGrant.count ?? 0)
            let direct = directBase + (directGrant.count ?? 0)
            nextSources.hints.append(hintGrant)
            nextSources.direct.append(directGrant)
            next.restoreToolBalance(ToolBalance(hints: hints, direct: direct))
        } else if !firstGrant, let balance = levelToolBalances[key] {
            next.restoreToolBalance(balance)
            nextSources = (levelToolSources[key] ?? ToolInventorySources()).matching(balance)
        } else {
            nextSources.hints = ToolSourceQueue(count: next.hintsRemaining, source: .levelConfigFree)
            nextSources.direct = ToolSourceQueue(count: next.directRemaining, source: .levelConfigFree)
        }
        session = next
        levelToolSources[key] = nextSources
        // A new board attempt must replay its teaching actions from the beginning.
        // Continuing or restoring a saved session does not call begin, so its
        // instruction and the marks needed by that instruction stay together.
        if puzzle.id == 1 && !tutorialCompleted { tutorialStep = 0 }
        currentLevel = puzzle.id
        attemptCounts[key] = attempt
        freeToolGrantedLevels.insert(puzzle.id)
        captureSessionBalance()
    }

    @discardableResult
    public mutating func finishWin() -> Bool {
        guard let session, session.status == .won else { return false }
        completedLevels.insert(session.puzzle.id)
        unlockedLevel = max(unlockedLevel, session.puzzle.id + 1)
        captureSessionBalance()
        return true
    }

    public mutating func restart() {
        _ = recoverInterruptedRewards()
        guard let current = session else { return }
        begin(puzzle: current.puzzle, config: current.config)
    }

    @discardableResult
    public mutating func directFind() -> Int? {
        guard session?.status == .playing, session?.directToolEnabled == true else { return nil }
        captureSessionBalance()
        synchronizeBonusSources()
        let result: Int?
        if currentLevelStartBalance.direct > 0 {
            result = session?.revealDirectReward()
            if result != nil { levelStartLocalBalances[String(currentLevel)]?.direct -= 1 }
        } else if (session?.directRemaining ?? 0) > 0 {
            result = session?.directFind()
            if result != nil, let level = session?.puzzle.id { levelToolSources[String(level)]?.direct.consumeOne() }
        } else if bonusDirect > 0 {
            result = session?.revealDirectReward()
            if result != nil { bonusDirect -= 1; bonusToolSources.direct.consumeOne() }
        } else { return nil }
        captureSessionBalance()
        return result
    }

    @discardableResult
    public mutating func consumeHint() -> Bool {
        guard session?.status == .playing, session?.hintToolEnabled == true, session?.hasUnmarkedExclusions == true else { return false }
        captureSessionBalance()
        synchronizeBonusSources()
        if session?.pendingRewardHint != true && currentLevelStartBalance.hints > 0 {
            levelStartLocalBalances[String(currentLevel)]?.hints -= 1
            return true
        }
        let pendingReward = session?.pendingRewardHint == true
        if session?.consumeHint() == true {
            if !pendingReward, let level = session?.puzzle.id { levelToolSources[String(level)]?.hints.consumeOne() }
            captureSessionBalance()
            return true
        }
        guard bonusHints > 0 else { return false }
        bonusHints -= 1
        bonusToolSources.hints.consumeOne()
        return true
    }

    /// Synchronizes per-level grants whenever the app directly mutates the public session value.
    public mutating func captureSessionBalance() {
        guard let session else { return }
        let key = String(session.puzzle.id)
        levelToolBalances[key] = ToolBalance(hints: session.hintsRemaining, direct: session.directRemaining)
        let sources = (levelToolSources[key] ?? ToolInventorySources()).matching(levelToolBalances[key]!)
        levelToolSources[key] = sources
        attemptCounts[key] = max(attemptCounts[key] ?? 0, session.attempt)
        carriedToolBalance.hints = session.config.referenceGameplay?.hint.inventoryAcrossLevels == .retain ? session.hintsRemaining : 0
        carriedToolBalance.direct = session.config.referenceGameplay?.directFind.inventoryAcrossLevels == .retain ? session.directRemaining : 0
        carriedToolSources.hints = sources.hints.matching(carriedToolBalance.hints)
        carriedToolSources.direct = sources.direct.matching(carriedToolBalance.direct)
    }

    private mutating func synchronizeBonusSources() {
        bonusToolSources = bonusToolSources.matching(ToolBalance(hints: bonusHints, direct: bonusDirect))
    }

    private mutating func grantBonus(_ kind: ReferenceToolKind, count: Int, source: ToolInventorySource) {
        guard count > 0 else { return }
        synchronizeBonusSources()
        let grant = ToolSourceQueue(count: count, source: source)
        if kind == .hint { bonusHints += count; bonusToolSources.hints.append(grant) }
        else { bonusDirect += count; bonusToolSources.direct.append(grant) }
    }

    @discardableResult
    public mutating func claimCheckIn(on date: Date = Date(), config: DemoConfig = .default) -> CheckInOutcome {
        let day = CheckInState.utcDay(for: date)
        if let last = checkIn.lastClaimedDay {
            if day == last { return .alreadyClaimed }
            if day < last { return .clockRollback }
            checkIn.streak = day == last + 1 ? checkIn.streak + 1 : 1
        } else { checkIn.streak = 1 }
        checkIn.lastClaimedDay = day
        let cycleLength = max(1, config.checkInCycleDays)
        checkIn.cycleDay = (checkIn.streak - 1) % cycleLength + 1
        let direct = checkIn.cycleDay == cycleLength ? config.cycleDirectReward : 0
        if checkIn.cycleDay == cycleLength { checkIn.completedCycles += 1 }
        grantBonus(.hint, count: config.dailyHintReward, source: .initialFree)
        grantBonus(.directFind, count: direct, source: .initialFree)
        return .claimed(streak: checkIn.streak, cycleDay: checkIn.cycleDay,
                        hints: config.dailyHintReward, direct: direct)
    }

    private mutating func referenceGrant(_ tool: ReferenceToolConfiguration, kind: ReferenceToolKind, level: Int) -> ToolSourceQueue {
        guard tool.enabled, level >= tool.unlockLevel else { return ToolSourceQueue() }
        let levelKey = "\(kind.rawValue):level:\(level)"
        let unlockKey = "\(kind.rawValue):firstUnlock"
        let initial: Int
        switch tool.regrantPolicy {
        case .everyAttempt: initial = tool.initialFreeCount
        case .oncePerLevel: initial = referenceToolGrantKeys.contains(levelKey) ? 0 : tool.initialFreeCount
        case .never: initial = 0
        }
        let unlock = referenceToolGrantKeys.contains(unlockKey) ? 0 : tool.firstUnlockBonusCount
        referenceToolGrantKeys.insert(levelKey)
        referenceToolGrantKeys.insert(unlockKey)
        var sources = ToolSourceQueue(count: initial, source: .levelConfigFree)
        sources.append(ToolSourceQueue(count: unlock, source: .initialFree))
        return sources
    }

    public var levelStartFreeQuotaKey: String? {
        guard let session, let free = session.config.referenceGameplay?.levelStartFreeAd else { return nil }
        switch free.resetPolicy {
        case .oncePerLevel: return "levelStartFree:level:\(session.puzzle.id)"
        case .everyAttempt: return "levelStartFree:level:\(session.puzzle.id):attempt:\(session.attempt)"
        case .never: return "levelStartFree:lifetime"
        }
    }

    public var levelStartFreeRewardsRemaining: Int {
        guard let session, let reference = session.config.referenceGameplay,
              reference.adsEnabled, reference.levelStartFreeAd.enabled, reference.levelStartFreeAd.visible,
              reference.levelStartFreeAd.buttonState == .enabled, let key = levelStartFreeQuotaKey else { return 0 }
        let used = rewardLedger.values.filter { record in
            record.kind == .levelStartFree && record.quotaKey == key && [.rewarded, .executed, .compensated].contains(record.state)
        }.count
        return max(0, reference.levelStartFreeAd.freeCount - used)
    }

    private var freeReviveQuotaKey: String? {
        guard let session, let revive = session.config.referenceGameplay?.revive else { return nil }
        switch revive.resetPolicy {
        case .oncePerLevel: return "freeRevive:level:\(session.puzzle.id)"
        case .everyAttempt: return "freeRevive:level:\(session.puzzle.id):attempt:\(session.attempt)"
        case .never: return "freeRevive:lifetime"
        }
    }

    public var freeRevivesRemaining: Int {
        guard let revive = session?.config.referenceGameplay?.revive, revive.enabled,
              let key = freeReviveQuotaKey else { return 0 }
        return max(0, revive.freeCount - (freeReviveUsage[key] ?? 0))
    }

    /// Call inside SaveStore.transaction so a free revive and its quota are durable together.
    @discardableResult
    public mutating func useFreeRevive() -> Bool {
        guard session?.status == .lost, freeRevivesRemaining > 0, let key = freeReviveQuotaKey,
              session?.revive() == true else { return false }
        freeReviveUsage[key, default: 0] += 1
        captureSessionBalance()
        return true
    }

    public func canReceiveReward(_ kind: RewardKind) -> Bool {
        guard let session else { return false }
        if rewardLedger.values.contains(where: { $0.state == .offered || $0.state == .rewarded }) { return false }
        switch kind {
        case .direct:
            return session.status == .playing && session.directToolEnabled && session.remainingCount > 0 && availableDirect == 0
                && session.config.referenceGameplay?.adsEnabled != false && session.config.referenceGameplay?.directFind.rewardedAdEnabled != false
        case .hint:
            return session.status == .playing && session.hintToolEnabled && session.hasUnmarkedExclusions && availableHints == 0
                && session.config.referenceGameplay?.adsEnabled != false && session.config.referenceGameplay?.hint.rewardedAdEnabled != false
        case .revive:
            return session.status == .lost && freeRevivesRemaining == 0 && session.config.referenceGameplay?.adsEnabled != false
                && session.config.referenceGameplay?.revive.enabled != false && session.config.referenceGameplay?.revive.rewardedAdEnabled != false
        case .levelStartFree: return session.status == .playing && levelStartFreeRewardsRemaining > 0
        }
    }

    /// Only SaveStore should call this during production, after the rewarded record is durable.
    @discardableResult
    public mutating func executeReward(offerID: String) -> RewardOutcome {
        guard var record = rewardLedger[offerID] else { return .ignored }
        guard record.state == .rewarded else {
            return record.state == .executed || record.state == .compensated ? .duplicate : .ignored
        }
        guard record.sessionID == session?.id else { return compensate(offerID: offerID) }
        let result: RewardOutcome
        switch record.kind {
        case .direct:
            guard let cell = session?.revealDirectReward() else { return compensate(offerID: offerID) }
            result = .directRevealed(cell)
        case .hint:
            guard session?.status == .playing, session?.hasUnmarkedExclusions == true else {
                return compensate(offerID: offerID)
            }
            session?.pendingRewardHint = true
            result = .hintReady
        case .revive:
            guard session?.revive() == true else {
                record.state = .cancelled
                rewardLedger[offerID] = record
                return .ignored
            }
            result = .revived
        case .levelStartFree:
            guard grantRecordedInventory(record) else { return .ignored }
            result = .inventoryGranted
        }
        record.state = .executed
        rewardLedger[offerID] = record
        captureSessionBalance()
        return result
    }

    @discardableResult
    private mutating func compensate(offerID: String) -> RewardOutcome {
        guard var record = rewardLedger[offerID], record.state == .rewarded else { return .ignored }
        switch record.kind {
        case .direct: grantBonus(.directFind, count: 1, source: .rewardedAd)
        case .hint: grantBonus(.hint, count: 1, source: .rewardedAd)
        case .levelStartFree:
            guard grantRecordedInventory(record) else {
                record.state = .cancelled
                rewardLedger[offerID] = record
                return .ignored
            }
        case .revive:
            record.state = .cancelled
            rewardLedger[offerID] = record
            return .ignored
        }
        record.state = .compensated
        rewardLedger[offerID] = record
        return .compensated
    }

    /// The receipt snapshot is authoritative. Reset rewards stay in a separate level
    /// pool even if normal tool inventory is retained; retained rewards use the bonus
    /// pool. Compensation keeps the recorded kind, quantity and scope.
    private mutating func grantRecordedInventory(_ record: RewardRecord) -> Bool {
        guard let tool = record.inventoryTool, let count = record.inventoryCount,
              count > 0, count <= 10_000, record.quotaKey != nil else { return false }
        if record.inventoryCarry == .reset {
            guard let level = record.levelID, level > 0 else { return false }
            let key = String(level)
            var balance = levelStartLocalBalances[key] ?? ToolBalance(hints: 0, direct: 0)
            if tool == .hint { balance.hints += count } else { balance.direct += count }
            levelStartLocalBalances[key] = balance
        } else { grantBonus(tool, count: count, source: .rewardedAd) }
        return true
    }

    /// Called on process restart or when abandoning a session. No board action is replayed.
    @discardableResult
    public mutating func recoverInterruptedRewards() -> Int {
        var recovered = 0
        for id in rewardLedger.keys.sorted() {
            switch rewardLedger[id]?.state {
            case .rewarded:
                if compensate(offerID: id) == .compensated { recovered += 1 }
            case .offered:
                rewardLedger[id]?.state = .cancelled
            default: break
            }
        }
        if session?.pendingRewardHint == true {
            grantBonus(.hint, count: 1, source: .rewardedAd)
            session?.pendingRewardHint = false
            recovered += 1
        }
        return recovered
    }

    private enum CodingKeys: String, CodingKey {
        case unlockedLevel, currentLevel, completedLevels, attemptCounts, session, settings
        case tutorialStep, tutorialCompleted, checkIn, bonusHints, bonusDirect, rewardLedger
        case freeToolGrantedLevels, levelToolBalances, referenceToolGrantKeys, carriedToolBalance, levelStartLocalBalances, freeReviveUsage
        case bonusToolSources, levelToolSources, carriedToolSources
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        unlockedLevel = try values.decodeIfPresent(Int.self, forKey: .unlockedLevel) ?? 1
        currentLevel = try values.decodeIfPresent(Int.self, forKey: .currentLevel) ?? 1
        completedLevels = try values.decodeIfPresent(Set<Int>.self, forKey: .completedLevels) ?? []
        attemptCounts = try values.decodeIfPresent([String: Int].self, forKey: .attemptCounts) ?? [:]
        session = try values.decodeIfPresent(GameSession.self, forKey: .session)
        settings = try values.decodeIfPresent(GameSettings.self, forKey: .settings) ?? GameSettings()
        tutorialStep = try values.decodeIfPresent(Int.self, forKey: .tutorialStep) ?? 0
        tutorialCompleted = try values.decodeIfPresent(Bool.self, forKey: .tutorialCompleted) ?? false
        checkIn = try values.decodeIfPresent(CheckInState.self, forKey: .checkIn) ?? CheckInState()
        bonusHints = try values.decodeIfPresent(Int.self, forKey: .bonusHints) ?? 0
        bonusDirect = try values.decodeIfPresent(Int.self, forKey: .bonusDirect) ?? 0
        rewardLedger = try values.decodeIfPresent([String: RewardRecord].self, forKey: .rewardLedger) ?? [:]
        freeToolGrantedLevels = try values.decodeIfPresent(Set<Int>.self, forKey: .freeToolGrantedLevels) ?? []
        levelToolBalances = try values.decodeIfPresent([String: ToolBalance].self, forKey: .levelToolBalances) ?? [:]
        referenceToolGrantKeys = try values.decodeIfPresent(Set<String>.self, forKey: .referenceToolGrantKeys) ?? []
        carriedToolBalance = try values.decodeIfPresent(ToolBalance.self, forKey: .carriedToolBalance) ?? ToolBalance(hints: 0, direct: 0)
        levelStartLocalBalances = try values.decodeIfPresent([String: ToolBalance].self, forKey: .levelStartLocalBalances) ?? [:]
        freeReviveUsage = try values.decodeIfPresent([String: Int].self, forKey: .freeReviveUsage) ?? [:]
        // Provenance is optional metadata. Invalid or absent metadata must never
        // invalidate a user's otherwise valid saved inventory.
        bonusToolSources = (try? values.decode(ToolInventorySources.self, forKey: .bonusToolSources)) ?? ToolInventorySources()
        levelToolSources = (try? values.decode([String: ToolInventorySources].self, forKey: .levelToolSources)) ?? [:]
        carriedToolSources = (try? values.decode(ToolInventorySources.self, forKey: .carriedToolSources)) ?? ToolInventorySources()
        if let session {
            freeToolGrantedLevels.insert(session.puzzle.id)
            captureSessionBalance()
        }
    }
}
