import Foundation

public enum PuzzleGenerationError: Error, LocalizedError, Equatable {
    case invalidLevel
    case exhausted(attempts: Int)
    case timeBudgetExceeded
    public var errorDescription: String? {
        switch self {
        case .invalidLevel: return "Level and attempt budget must be positive."
        case .exhausted(let attempts): return "No valid unique board within \(attempts) attempts. Please retry."
        case .timeBudgetExceeded: return "Generation reached its time budget. Please retry."
        }
    }
}

public struct PuzzleGenerator: Sendable {
    public static let version = "original-pipeline-v4"
    public static let maximumBoardSize = 10
    public static let generationTimeBudget: TimeInterval = 8
    public init() {}

    /// Executable local profile, never represented as sampled Pawdoku values.
    public static func size(for level: Int) -> Int {
        Int(DifficultyProfile.provisional(level: level).boardSizeCurveTarget.minimum)
    }

    public static func difficulty(for level: Int) -> String {
        DifficultyProfile.role(for: level).0.rawValue
    }

    public static func generate(level: Int, seed: UInt64? = nil, maxAttempts: Int = 500,
                                timeBudgetMilliseconds: Int = 8_000) throws -> Puzzle {
        let result = try generateAudited(level: level, seed: seed, maxAttempts: maxAttempts,
                                        timeBudgetMilliseconds: timeBudgetMilliseconds)
        if let puzzle = result.puzzle { return puzzle }
        if result.report.termination == "time_budget_exceeded" { throw PuzzleGenerationError.timeBudgetExceeded }
        throw PuzzleGenerationError.exhausted(attempts: result.report.generatedCandidates)
    }

    static func generateCandidate(level: Int, seed: UInt64, size: Int, variation: Int,
                                  timeBudgetMilliseconds: Int) throws -> Puzzle {
        let maxAttempts = 1
        guard level > 0, maxAttempts > 0, timeBudgetMilliseconds > 0 else { throw PuzzleGenerationError.invalidLevel }
        var rng = SeededRandom(state: SeededRandom.mixed(seed))
        let n = size
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + min(generationTimeBudget, Double(timeBudgetMilliseconds) / 1_000)
        for _ in 0..<min(maxAttempts, 500) {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw PuzzleGenerationError.timeBudgetExceeded }
            let columns = solutionColumns(size: n, rng: &rng)
            let roots = columns.enumerated().map { $0.offset * n + $0.element }
            // Candidate construction varies anchor count; subsequent difficulty filtering
            // rejects shapes that miss the profile. No candidate is accepted by size alone.
            let frozenCount: Int
            if n == 4 { frozenCount = level == 1 ? 1 : 0 }
            else if n == 10 { frozenCount = 2 + variation % 4 }
            else { frozenCount = variation % max(1, n / 2) }
            var labels = connectedPartition(size: n, roots: roots, frozenCount: frozenCount, rng: &rng)
            guard !labels.contains(-1) else { continue }
            let rootSet = Set(roots)
            // Repair ambiguous boards by moving boundary cells while preserving the intended
            // solution and both regions' connectivity. Every accepted board gets a fresh solve.
            for repair in 0..<(n * n * 3) {
                if repair % 8 == 0 && ProcessInfo.processInfo.systemUptime >= deadline {
                    throw PuzzleGenerationError.timeBudgetExceeded
                }
                let solutions = PuzzleSolver.solutions(size: n, regions: labels, limit: 2)
                if solutions.count == 1 {
                    let puzzle = Puzzle(id: level, size: n, regions: labels, solution: solutions[0],
                                        seed: seed, generatorVersion: version, difficulty: difficulty(for: level))
                    if PuzzleSolver.validate(puzzle).valid,
                       level != 1 || PuzzleHints.canTeach(puzzle: puzzle) { return puzzle }
                    break
                }
                guard let alternative = solutions.first(where: { Set($0) != rootSet }) else { break }
                var moves: [(Int, Int)] = []
                for cell in alternative where !rootSet.contains(cell) {
                    let neighbors = neighbors(of: cell, size: n)
                    let newRegions = Set(neighbors.map { labels[$0] }).subtracting([labels[cell]]).sorted()
                    guard !newRegions.isEmpty, connectedWithout(cell: cell, labels: labels, size: n) else { continue }
                    for region in newRegions { moves.append((cell, region)) }
                }
                guard !moves.isEmpty else { break }
                let move = moves[rng.index(moves.count)]
                labels[move.0] = move.1
            }
        }
        throw PuzzleGenerationError.exhausted(attempts: min(maxAttempts, 500))
    }

    private static func solutionColumns(size n: Int, rng: inout SeededRandom) -> [Int] {
        // Backtracking always finishes for our supported even sizes (4, 6, 8, 10).
        var answer: [Int] = []
        func fill(_ rng: inout SeededRandom) -> Bool {
            if answer.count == n { return true }
            var choices = Array(0..<n).filter { col in !answer.contains(col) && (answer.last == nil || abs(answer.last! - col) > 1) }
            rng.shuffle(&choices)
            for col in choices {
                answer.append(col)
                if fill(&rng) { return true }
                answer.removeLast()
            }
            return false
        }
        _ = fill(&rng)
        return answer
    }

    private static func connectedPartition(size n: Int, roots: [Int], frozenCount: Int, rng: inout SeededRandom) -> [Int] {
        var labels = Array(repeating: -1, count: n * n)
        for (region, cell) in roots.enumerated() { labels[cell] = region }
        var regionIDs = Array(0..<n); rng.shuffle(&regionIDs)
        let frozen = Set(regionIDs.prefix(frozenCount))
        var frontier: [(Int, Int)] = []
        for (region, cell) in roots.enumerated() where !frozen.contains(region) {
            for next in neighbors(of: cell, size: n) where labels[next] == -1 { frontier.append((next, region)) }
        }
        while !frontier.isEmpty {
            let index = rng.index(frontier.count)
            let (cell, region) = frontier[index]
            frontier.swapAt(index, frontier.count - 1); frontier.removeLast()
            guard labels[cell] == -1 else { continue }
            labels[cell] = region
            for next in neighbors(of: cell, size: n) where labels[next] == -1 { frontier.append((next, region)) }
        }
        return labels
    }

    private static func neighbors(of cell: Int, size n: Int) -> [Int] {
        let r = cell / n, c = cell % n
        return [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)]
            .filter { $0.0 >= 0 && $0.0 < n && $0.1 >= 0 && $0.1 < n }.map { $0.0 * n + $0.1 }
    }

    private static func connectedWithout(cell: Int, labels: [Int], size n: Int) -> Bool {
        let group = labels[cell]
        let remaining = labels.indices.filter { $0 != cell && labels[$0] == group }
        guard let first = remaining.first else { return false }
        var seen: Set<Int> = [first], todo = [first]
        while let current = todo.popLast() {
            for next in neighbors(of: current, size: n) where next != cell && labels[next] == group {
                if seen.insert(next).inserted { todo.append(next) }
            }
        }
        return seen.count == remaining.count
    }
}

private struct SeededRandom {
    var state: UInt64
    static func mixed(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func index(_ count: Int) -> Int { Int(next() % UInt64(count)) }
    mutating func shuffle<T>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, through: 1, by: -1) { array.swapAt(i, index(i + 1)) }
    }
}
