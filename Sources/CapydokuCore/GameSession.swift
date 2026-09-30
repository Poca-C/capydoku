import Foundation

public enum GameStatus: String, Codable, Equatable, Sendable {
    case playing, won, lost
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
        self.hintsRemaining = grantFreeTools ? config.hintsPerLevel : 0
        self.directRemaining = grantFreeTools ? config.directPerLevel : 0
        self.attempt = max(1, attempt)
        self.elapsedSeconds = 0
        self.hasRevived = false
        self.pendingRewardHint = false
    }

    private func isCell(_ cell: Int) -> Bool { (0..<(puzzle.size * puzzle.size)).contains(cell) }

    @discardableResult
    public mutating func toggleMark(at cell: Int) -> Bool {
        guard status == .playing, isCell(cell), !found.contains(cell), !errors.contains(cell) else { return false }
        // Red Xs are confirmed mistakes, not editable player guesses.
        if marks.contains(cell) { marks.remove(cell) } else { marks.insert(cell) }
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
        guard status == .playing, isCell(cell), !found.contains(cell), !errors.contains(cell) else {
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
        guard status == .playing, directRemaining > 0 else { return nil }
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
        guard status == .playing, hasUnmarkedExclusions else { return false }
        if pendingRewardHint { pendingRewardHint = false; return true }
        guard hintsRemaining > 0 else { return false }
        hintsRemaining -= 1
        return true
    }

    public mutating func advanceTime(by seconds: Double) {
        guard status == .playing, seconds.isFinite, seconds > 0 else { return }
        elapsedSeconds += seconds
    }

    /// Restart preserves the tool balance; restarting cannot farm per-level free tools.
    public mutating func restart() {
        let hints = hintsRemaining
        let direct = directRemaining
        self = GameSession(puzzle: puzzle, config: config, attempt: attempt + 1, grantFreeTools: false)
        hintsRemaining = hints
        directRemaining = direct
    }

    mutating func restoreToolBalance(_ balance: ToolBalance) {
        hintsRemaining = max(0, balance.hints)
        directRemaining = max(0, balance.direct)
    }

    @discardableResult
    public mutating func revive() -> Bool {
        guard status == .lost else { return false }
        lives = config.initialLives
        status = .playing
        hasRevived = true
        // Found animals, manual Xs and red mistake Xs all survive revival.
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, puzzle, found, marks, errors, lives, score, combo, status
        case hintsRemaining, directRemaining, attempt, elapsedSeconds, hasRevived, pendingRewardHint, config
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
        hintsRemaining = try values.decodeIfPresent(Int.self, forKey: .hintsRemaining) ?? config.hintsPerLevel
        directRemaining = try values.decodeIfPresent(Int.self, forKey: .directRemaining) ?? config.directPerLevel
        elapsedSeconds = try values.decodeIfPresent(Double.self, forKey: .elapsedSeconds) ?? 0
        hasRevived = try values.decodeIfPresent(Bool.self, forKey: .hasRevived) ?? false
        pendingRewardHint = try values.decodeIfPresent(Bool.self, forKey: .pendingRewardHint) ?? false
    }
}
