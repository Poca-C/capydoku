import Foundation

public struct PuzzleHint: Codable, Equatable, Sendable {
    /// Cells to mark X. Never a placement or a mutation of the board.
    public let cells: [Int]
    public let explanation: String
    public let rule: String
    public init(cells: [Int], explanation: String, rule: String) {
        self.cells = cells; self.explanation = explanation; self.rule = rule
    }
}

public struct TutorialStep: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let instruction: String
    public let targetCells: [Int]
    /// read, tap, swipe or doubleTap.
    public let action: String
}

public enum PuzzleHints {
    private struct Deduction {
        var forced: Int?
        var excluded: Set<Int>
        var explanation: String
        var rule: String
    }

    private static func units(_ p: Puzzle) -> [(String, [Int])] {
        let n = p.size
        return (0..<n).map { r in ("Row \(r + 1)", (0..<n).map { r * n + $0 }) }
            + (0..<n).map { c in ("Column \(c + 1)", (0..<n).map { $0 * n + c }) }
            + (0..<n).map { region in ("Region \(region + 1)", p.regions.indices.filter { p.regions[$0] == region }) }
    }

    private static func deduction(_ p: Puzzle, candidates: Set<Int>, confirmed: Set<Int>) -> Deduction? {
        for (name, cells) in units(p) where confirmed.isDisjoint(with: cells) {
            let remaining = cells.filter { candidates.contains($0) }
            if remaining.count == 1 {
                let cell = remaining[0]
                return Deduction(forced: cell,
                                 excluded: Set(candidates.filter { $0 != cell && p.conflicts(cell, $0) }),
                                 explanation: "\(name) has only one candidate: row \(cell / p.size + 1), column \(cell % p.size + 1). Exclude other cells in its row, column, region and all touching cells.",
                                 rule: "Single candidate")
            }
        }
        // Region/line locks are deductive and do not inspect the stored answer.
        for region in 0..<p.size where !confirmed.contains(where: { p.regions[$0] == region }) {
            let cells = candidates.filter { p.regions[$0] == region }
            guard !cells.isEmpty else { continue }
            let rows = Set(cells.map { $0 / p.size }), cols = Set(cells.map { $0 % p.size })
            if rows.count == 1, let row = rows.first {
                let excluded = Set(candidates.filter { $0 / p.size == row && p.regions[$0] != region })
                if !excluded.isEmpty {
                    return Deduction(excluded: excluded,
                                     explanation: "All candidates in region \(region + 1) lie in row \(row + 1). Exclude cells in that row outside this region.", rule: "Region-row lock")
                }
            }
            if cols.count == 1, let col = cols.first {
                let excluded = Set(candidates.filter { $0 % p.size == col && p.regions[$0] != region })
                if !excluded.isEmpty {
                    return Deduction(excluded: excluded,
                                     explanation: "All candidates in region \(region + 1) lie in column \(col + 1). Exclude cells in that column outside this region.", rule: "Region-column lock")
                }
            }
        }
        return nil
    }

    public static func next(puzzle p: Puzzle, found: Set<Int>, marks: Set<Int>) -> PuzzleHint? {
        guard (1...16).contains(p.size), p.regions.count == p.size * p.size else { return nil }
        // Marks are deliberately NOT constraints: a player's incorrect X cannot poison a hint.
        var confirmed = found.intersection(Set(p.solution))
        let all = Set(p.regions.indices)
        let blocked = Set(all.filter { cell in !confirmed.contains(cell) && confirmed.contains(where: { p.conflicts(cell, $0) }) })
        let freshBlocked = blocked.subtracting(marks)
        if !freshBlocked.isEmpty {
            return PuzzleHint(cells: freshBlocked.sorted(), explanation: "A found capybara excludes other cells in its row, column and colored region, plus every touching cell, including diagonals.", rule: "Known capybara")
        }
        var candidates = all.subtracting(confirmed).subtracting(blocked)
        for _ in 0..<(p.size * p.size * 2) {
            guard let step = deduction(p, candidates: candidates, confirmed: confirmed) else { break }
            let fresh = step.excluded.subtracting(marks)
            if !fresh.isEmpty {
                return PuzzleHint(cells: fresh.sorted(), explanation: step.explanation, rule: step.rule)
            }
            candidates.subtract(step.excluded)
            if let forced = step.forced { confirmed.insert(forced); candidates.remove(forced) }
        }
        // On harder temporary boards we honestly label an exhaustive contradiction check.
        // We never call a hidden answer lookup a human deduction.
        for cell in candidates.sorted() where !marks.contains(cell) && !p.isSolutionCell(cell) {
            if PuzzleSolver.solutions(size: p.size, regions: p.regions, limit: 1, required: Array(found.intersection(Set(p.solution))) + [cell]).isEmpty {
                return PuzzleHint(cells: [cell],
                                  explanation: "Contradiction check: placing a capybara in row \(cell / p.size + 1), column \(cell % p.size + 1) leaves no complete arrangement satisfying all four rules. This cell can be excluded.", rule: "Contradiction check")
            }
        }
        return nil
    }

    static func metrics(puzzle p: Puzzle) -> PuzzleLogicalMetrics {
        var candidates = Set(p.regions.indices), confirmed = Set<Int>()
        let initial = Set(units(p).filter { $0.1.count == 1 }.compactMap { $0.1.first }).count
        var steps = 0
        for _ in 0..<(p.size * p.size * 2) {
            guard let step = deduction(p, candidates: candidates, confirmed: confirmed) else { break }
            candidates.subtract(step.excluded)
            if let forced = step.forced { confirmed.insert(forced); candidates.remove(forced) }
            steps += 1
        }
        return PuzzleLogicalMetrics(initialForcedCells: initial, deductionSteps: steps,
                                    remainingUnresolved: p.size - confirmed.count, requiresSearch: confirmed.count != p.size)
    }

    public static func tutorial(puzzle p: Puzzle) -> [TutorialStep] {
        guard (1...16).contains(p.size), p.regions.count == p.size * p.size,
              !p.solution.isEmpty, p.solution.allSatisfy({ p.regions.indices.contains($0) }) else { return [] }
        let animal = p.solution.first(where: { cell in p.regions.filter { $0 == p.regions[cell] }.count == 1 }) ?? p.solution[0]
        let safe = p.regions.indices.first(where: { !p.isSolutionCell($0) }) ?? 0
        var swipe = [Int]()
        for row in 0..<p.size {
            for col in 0..<(p.size - 1) {
                let a = row * p.size + col, b = a + 1
                if !p.isSolutionCell(a) && !p.isSolutionCell(b) { swipe = [a, b]; break }
            }
            if !swipe.isEmpty { break }
        }
        var verticalSwipe = [Int]()
        for col in 0..<p.size {
            for row in 0..<(p.size - 1) {
                let a = row * p.size + col, b = a + p.size
                if !p.isSolutionCell(a) && !p.isSolutionCell(b) && !swipe.contains(a) && !swipe.contains(b) {
                    verticalSwipe = [a, b]; break
                }
            }
            if !verticalSwipe.isEmpty { break }
        }
        let adjacent = p.regions.indices.filter {
            $0 != animal && abs($0 / p.size - animal / p.size) <= 1 && abs($0 % p.size - animal % p.size) <= 1
        }
        return [
            TutorialStep(id: "row", title: "One per row", instruction: "Each row hides exactly one capybara.", targetCells: (0..<p.size).map { animal / p.size * p.size + $0 }, action: "read"),
            TutorialStep(id: "column", title: "One per column", instruction: "Each column also contains exactly one capybara.", targetCells: (0..<p.size).map { $0 * p.size + animal % p.size }, action: "read"),
            TutorialStep(id: "region", title: "One per region", instruction: "Each connected color region contains exactly one capybara.", targetCells: p.regions.indices.filter { p.regions[$0] == p.regions[animal] }, action: "read"),
            TutorialStep(id: "neighbors", title: "Give them space", instruction: "Capybaras cannot touch, even diagonally.", targetCells: adjacent, action: "read"),
            TutorialStep(id: "mark", title: "Tap to mark X", instruction: "Tap the highlighted cell to mark it as empty.", targetCells: [safe], action: "tap"),
            TutorialStep(id: "undo", title: "Tap again to undo", instruction: "Tap the same cell again to remove the X.", targetCells: [safe], action: "tap"),
            TutorialStep(id: "swipe", title: "Swipe across a row", instruction: "Swipe from the first highlighted cell to the second to mark both cells.", targetCells: swipe, action: "swipe"),
            TutorialStep(id: "swipeVertical", title: "Swipe down a column", instruction: "Now swipe vertically between the two highlighted cells. Straight swipes mark X; diagonal swipes do not.", targetCells: verticalSwipe, action: "swipe"),
            TutorialStep(id: "find", title: "Double-tap to find", instruction: "The highlighted region has only one cell, so its capybara must be here. Double-tap to find it, then use the four rules to find the rest.", targetCells: [animal], action: "doubleTap")
        ]
    }
}
