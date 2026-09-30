import Foundation

public enum GameStatus: String, Codable, Equatable, Sendable {
    case playing, won, lost
}

public enum LevelEndResult: String, Codable, Sendable {
    case win, lose, quit
}

public enum MoveResult: Equatable, Sendable {
    case correct(cell: Int, points: Int, won: Bool)
    case incorrect(cell: Int, livesRemaining: Int)
    case ignored
}

/// The whole puzzle is retained, including generated boards, so upgrades cannot change an active game.
public struct GameSession: Codable, Equatable, Sendable {
    public var id: UUID
    public var puzzle: Puzzle
    public private(set) var found: Set<Int>
    public private(set) var marks: Set<Int>
    public private(set) var errors: Set<Int>
    public private(set) var lives: Int
    public private(set) var score: Int
    public private(set) var combo: Int
    public private(set) var status: GameStatus
    public private(set) var hintsRemaining: Int
    public private(set) var directRemaining: Int
    public private(set) var attempt: Int
    public var elapsedSeconds: Double
    public private(set) var hasRevived: Bool
    /// One board may end several play phases through loss/revival or quit/continue.
    /// The phase is separate from the board identity and the restart attempt count.
    public private(set) var resultPhase: Int
    public private(set) var resultPhaseEnd: LevelEndResult?
    public var pendingRewardHint: Bool
    public let config: DemoConfig

    public var remainingCount: Int { max(0, puzzle.solution.count - found.count) }
    /// An availability check only; the actual explanation still comes from PuzzleHints.
    public var hasUnmarkedExclusions: Bool {
        let solution = Set(puzzle.solution)
        return puzzle.regions.indices.contains { !solution.contains($0) && !marks.contains($0) }
    }
    public var comboText: String? {
        let reached = config.comboThresholds.indices.last { combo >= config.comboThresholds[$0] }
        guard let reached else { return nil }
        return ["Nice", "Great", "Excellent"][min(reached, 2)]
    }

    public init(puzzle: Puzzle, config: DemoConfig = .default, attempt: Int = 1,
                grantFreeTools: Bool = true) {
        self.id = UUID()
        self.puzzle = puzzle
        self.config = config
        self.found = []
        self.marks = []
        self.errors = []
        self.lives = config.initialLives
        self.score = 0
        self.combo = 0
        self.status = .playing
        self.hintsRemaining = grantFreeTools ? Self.initialGrant(config.referenceGameplay?.hint, level: puzzle.id, fallback: config.hintsPerLevel) : 0
        self.directRemaining = grantFreeTools ? Self.initialGrant(config.referenceGameplay?.directFind, level: puzzle.id, fallback: config.directPerLevel) : 0
        self.attempt = max(1, attempt)
        self.elapsedSeconds = 0
        self.hasRevived = false
        self.resultPhase = 0
        self.resultPhaseEnd = nil
        self.pendingRewardHint = false
    }

    private static func initialGrant(_ tool: ReferenceToolConfiguration?, level: Int, fallback: Int) -> Int {
        guard let tool else { return fallback }
        return tool.enabled && level >= tool.unlockLevel && tool.regrantPolicy != .never ? tool.initialFreeCount : 0
    }

    public var directToolEnabled: Bool {
        guard let tool = config.referenceGameplay?.directFind else { return true }
        return tool.enabled && tool.visible && tool.buttonState == .enabled && puzzle.id >= tool.unlockLevel
    }
    public var hintToolEnabled: Bool {
        guard let tool = config.referenceGameplay?.hint else { return true }
        return tool.enabled && tool.visible && tool.buttonState == .enabled && puzzle.id >= tool.unlockLevel
    }

    private func isCell(_ cell: Int) -> Bool { (0..<(puzzle.size * puzzle.size)).contains(cell) }

    @discardableResult
    public mutating func toggleMark(at cell: Int) -> Bool {
        guard status == .playing, isCell(cell), !found.contains(cell) else { return false }
        // The original specification allows tapping any X to undo it, including a red error X.
        if marks.contains(cell) { marks.remove(cell); errors.remove(cell) } else { marks.insert(cell) }
        return true
    }

    /// Swipe and hint Apply only add marks. They never toggle previously marked cells off.
    @discardableResult
    public mutating func markMany(_ cells: [Int]) -> Int {
        guard status == .playing else { return 0 }
        var count = 0
        for cell in cells where isCell(cell) && !found.contains(cell) {
            if marks.insert(cell).inserted { count += 1 }
        }
        return count
    }

    @discardableResult
    public mutating func submit(cell: Int) -> MoveResult {
        guard status == .playing, isCell(cell), !found.contains(cell) else {
            return .ignored
        }
        if puzzle.solution.contains(cell) { return reveal(cell) }
        errors.insert(cell)
        marks.insert(cell)
        lives = max(0, lives - 1)
        combo = 0
        if lives == 0 { status = .lost }
        return .incorrect(cell: cell, livesRemaining: lives)
    }

    private mutating func reveal(_ cell: Int) -> MoveResult {
        found.insert(cell)
        marks.remove(cell)
        combo += 1
        let points = config.baseScore + (combo - 1) * config.comboBonus
        score += points
        if found.count == puzzle.solution.count { status = .won }
        // Deliberately no automatic exclusions in row, column, region, or neighbours.
        return .correct(cell: cell, points: points, won: status == .won)
    }

    @discardableResult
    public mutating func directFind() -> Int? {
        guard status == .playing, directToolEnabled, directRemaining > 0 else { return nil }
        guard let cell = revealDirectReward() else { return nil }
        directRemaining -= 1
        return cell
    }

    /// Used after a transaction has granted a single rewarded or bonus action.
    @discardableResult
    public mutating func revealDirectReward() -> Int? {
        guard status == .playing else { return nil }
        guard let cell = puzzle.solution.filter({ !found.contains($0) }).randomElement() else { return nil }
        _ = reveal(cell)
        return cell
    }

    @discardableResult
    public mutating func consumeHint() -> Bool {
        guard status == .playing, hintToolEnabled, hasUnmarkedExclusions else { return false }
        if pendingRewardHint { pendingRewardHint = false; return true }
        guard hintsRemaining > 0 else { return false }
        hintsRemaining -= 1
        return true
    }

    public mutating func advanceTime(by seconds: Double) {
        guard status == .playing, seconds.isFinite, seconds > 0 else { return }
        elapsedSeconds += seconds
    }

    /// Claims a real result once. The caller persists this mutation together with
    /// the frozen event payload before attempting to deliver the event.
    public mutating func claimResult(_ result: LevelEndResult) -> String? {
        guard resultPhaseEnd == nil else { return nil }
        switch (result, status) {
        case (.win, .won), (.lose, .lost), (.quit, .playing): break
        default: return nil
        }
        resultPhaseEnd = result
        return id.uuidString + ":result:" + String(resultPhase)
    }

    /// A genuine Home-to-continue transition reopens play without a new attempt.
    @discardableResult
    public mutating func resumeAfterQuit() -> Bool {
        guard status == .playing, resultPhaseEnd == .quit, resultPhase < Int.max - 1 else { return false }
        resultPhase += 1
        resultPhaseEnd = nil
        return true
    }

    /// Restart preserves the tool balance; restarting cannot farm per-level free tools.
    public mutating func restart() {
        let hints = hintsRemaining
        let direct = directRemaining
        self = GameSession(puzzle: puzzle, config: config, attempt: attempt + 1, grantFreeTools: false)
        hintsRemaining = hints
        directRemaining = direct
        if let reference = config.referenceGameplay {
            if reference.hint.regrantPolicy == .everyAttempt && hintToolEnabled { hintsRemaining += reference.hint.initialFreeCount }
            if reference.directFind.regrantPolicy == .everyAttempt && directToolEnabled { directRemaining += reference.directFind.initialFreeCount }
        }
    }

    mutating func addInventory(_ kind: ReferenceToolKind, count: Int) {
        guard count > 0 else { return }
        if kind == .hint { hintsRemaining += count } else { directRemaining += count }
    }

    mutating func restoreToolBalance(_ balance: ToolBalance) {
        hintsRemaining = max(0, balance.hints)
        directRemaining = max(0, balance.direct)
    }

    @discardableResult
    public mutating func revive() -> Bool {
        guard status == .lost else { return false }
        guard config.referenceGameplay?.revive.enabled != false else { return false }
        guard resultPhaseEnd == nil || resultPhase < Int.max - 1 else { return false }
        lives = config.referenceGameplay?.revive.restoredLives ?? config.initialLives
        status = .playing
        hasRevived = true
        if resultPhaseEnd != nil {
            resultPhase += 1
            resultPhaseEnd = nil
        }
        // Found animals, manual Xs and red mistake Xs all survive revival.
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, puzzle, found, marks, errors, lives, score, combo, status
        case hintsRemaining, directRemaining, attempt, elapsedSeconds, hasRevived, pendingRewardHint, config
        case resultPhase, resultPhaseEnd
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let puzzle = try values.decode(Puzzle.self, forKey: .puzzle)
        let config = try values.decodeIfPresent(DemoConfig.self, forKey: .config) ?? .default
        let attempt = try values.decodeIfPresent(Int.self, forKey: .attempt) ?? 1
        self.init(puzzle: puzzle, config: config, attempt: attempt)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        found = try values.decodeIfPresent(Set<Int>.self, forKey: .found) ?? []
        marks = try values.decodeIfPresent(Set<Int>.self, forKey: .marks) ?? []
        errors = try values.decodeIfPresent(Set<Int>.self, forKey: .errors) ?? []
        lives = try values.decodeIfPresent(Int.self, forKey: .lives) ?? config.initialLives
        score = try values.decodeIfPresent(Int.self, forKey: .score) ?? 0
        combo = try values.decodeIfPresent(Int.self, forKey: .combo) ?? 0
        status = try values.decodeIfPresent(GameStatus.self, forKey: .status) ?? .playing
        if let savedPhase = try values.decodeIfPresent(Int.self, forKey: .resultPhase) {
            guard savedPhase >= 0, savedPhase < Int.max else {
                throw DecodingError.dataCorruptedError(forKey: .resultPhase, in: values,
                                                      debugDescription: "Invalid result phase counter")
            }
            resultPhase = savedPhase
            resultPhaseEnd = try values.decodeIfPresent(LevelEndResult.self, forKey: .resultPhaseEnd)
        } else {
            // Legacy terminal boards have no durable event fact to replay. Mark
            // their existing result closed instead of fabricating a new event.
            resultPhase = 0
            switch status {
            case .playing: resultPhaseEnd = nil
            case .lost: resultPhaseEnd = .lose
            case .won: resultPhaseEnd = .win
            }
        }
        hintsRemaining = try values.decodeIfPresent(Int.self, forKey: .hintsRemaining) ?? config.hintsPerLevel
        directRemaining = try values.decodeIfPresent(Int.self, forKey: .directRemaining) ?? config.directPerLevel
        elapsedSeconds = try values.decodeIfPresent(Double.self, forKey: .elapsedSeconds) ?? 0
        hasRevived = try values.decodeIfPresent(Bool.self, forKey: .hasRevived) ?? false
        pendingRewardHint = try values.decodeIfPresent(Bool.self, forKey: .pendingRewardHint) ?? false
    }
}
