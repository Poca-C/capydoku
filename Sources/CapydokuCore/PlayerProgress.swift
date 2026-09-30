import Foundation

public enum RewardKind: String, Codable, CaseIterable, Sendable {
    case direct, hint, revive
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

    public init(id: String, kind: RewardKind, state: RewardState = .offered,
                sessionID: UUID?, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.state = state
        self.sessionID = sessionID
        self.createdAt = createdAt
    }
}

public enum RewardOutcome: Equatable, Sendable {
    case directRevealed(Int), hintReady, revived, duplicate, compensated, ignored
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
    }

    public var availableHints: Int {
        (session?.hintsRemaining ?? 0) + bonusHints + (session?.pendingRewardHint == true ? 1 : 0)
    }
    public var availableDirect: Int { (session?.directRemaining ?? 0) + bonusDirect }

    public mutating func begin(puzzle: Puzzle, config: DemoConfig = .default) {
        _ = recoverInterruptedRewards()
        captureSessionBalance()
        let key = String(puzzle.id)
        let attempt = (attemptCounts[key] ?? 0) + 1
        let firstGrant = !freeToolGrantedLevels.contains(puzzle.id)
        var next = GameSession(puzzle: puzzle, config: config, attempt: attempt, grantFreeTools: firstGrant)
        if !firstGrant, let balance = levelToolBalances[key] {
            next.restoreToolBalance(balance)
        }
        session = next
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
        guard session != nil else { return }
        session?.restart()
        if let session { attemptCounts[String(session.puzzle.id)] = session.attempt }
        captureSessionBalance()
    }

    @discardableResult
    public mutating func directFind() -> Int? {
        guard session?.status == .playing else { return nil }
        let result: Int?
        if (session?.directRemaining ?? 0) > 0 {
            result = session?.directFind()
        } else if bonusDirect > 0 {
            result = session?.revealDirectReward()
            if result != nil { bonusDirect -= 1 }
        } else { return nil }
        captureSessionBalance()
        return result
    }

    @discardableResult
    public mutating func consumeHint() -> Bool {
        guard session?.status == .playing, session?.hasUnmarkedExclusions == true else { return false }
        if session?.consumeHint() == true {
            captureSessionBalance()
            return true
        }
        guard bonusHints > 0 else { return false }
        bonusHints -= 1
        return true
    }

    /// Synchronizes per-level grants whenever the app directly mutates the public session value.
    public mutating func captureSessionBalance() {
        guard let session else { return }
        let key = String(session.puzzle.id)
        levelToolBalances[key] = ToolBalance(hints: session.hintsRemaining, direct: session.directRemaining)
        attemptCounts[key] = max(attemptCounts[key] ?? 0, session.attempt)
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
        bonusHints += config.dailyHintReward
        bonusDirect += direct
        return .claimed(streak: checkIn.streak, cycleDay: checkIn.cycleDay,
                        hints: config.dailyHintReward, direct: direct)
    }

    public func canReceiveReward(_ kind: RewardKind) -> Bool {
        guard let session else { return false }
        if rewardLedger.values.contains(where: { $0.state == .offered || $0.state == .rewarded }) { return false }
        switch kind {
        case .direct: return session.status == .playing && session.remainingCount > 0 && availableDirect == 0
        case .hint: return session.status == .playing && session.hasUnmarkedExclusions && availableHints == 0
        case .revive: return session.status == .lost
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
        case .direct: bonusDirect += 1
        case .hint: bonusHints += 1
        case .revive:
            record.state = .cancelled
            rewardLedger[offerID] = record
            return .ignored
        }
        record.state = .compensated
        rewardLedger[offerID] = record
        return .compensated
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
            bonusHints += 1
            session?.pendingRewardHint = false
            recovered += 1
        }
        return recovered
    }

    private enum CodingKeys: String, CodingKey {
        case unlockedLevel, currentLevel, completedLevels, attemptCounts, session, settings
        case tutorialStep, tutorialCompleted, checkIn, bonusHints, bonusDirect, rewardLedger
        case freeToolGrantedLevels, levelToolBalances
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
        if let session {
            freeToolGrantedLevels.insert(session.puzzle.id)
            captureSessionBalance()
        }
    }
}
