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
    struct Deduction {
        var forced: Int?
        var excluded: Set<Int>
        var explanation: String
        var rule: String
    }

    static func units(_ p: Puzzle) -> [(String, [Int])] {
        let n = p.size
        return (0..<n).map { r in ("Row \(r + 1)", (0..<n).map { r * n + $0 }) }
            + (0..<n).map { c in ("Column \(c + 1)", (0..<n).map { $0 * n + c }) }
            + (0..<n).map { region in ("Region \(region + 1)", p.regions.indices.filter { p.regions[$0] == region }) }
    }

    static func deduction(_ p: Puzzle, candidates: Set<Int>, confirmed: Set<Int>) -> Deduction? {
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
        // A row, column or region must contain an animal somewhere among its candidates.
        // A cell outside that unit is impossible if it conflicts with EVERY candidate.
        // This includes the useful "two neighboring candidates block the same neighbor"
        // deduction, and mixed row/region/adjacency conflicts. No answer is consulted.
        for (name, cells) in units(p) where confirmed.isDisjoint(with: cells) {
            let remaining = cells.filter { candidates.contains($0) }
            guard remaining.count > 1 else { continue }
            let inUnit = Set(cells)
            let excluded = Set(candidates.filter { cell in
                !inUnit.contains(cell) && remaining.allSatisfy { p.conflicts(cell, $0) }
            })
            if !excluded.isEmpty {
                return Deduction(excluded: excluded,
                                 explanation: "\(name) must contain one capybara. Every highlighted cell conflicts with all remaining candidates in that unit: whichever candidate is chosen, the highlighted cells would break a row, column, region or touching rule.",
                                 rule: "Common conflict")
            }
        }
        // Two unfinished units from one family need two distinct animals. If all
        // candidates occupy exactly two units from another family, those target
        // units are reserved. This is a Hall pair, not hypothetical search.
        let allUnits = units(p)
        let familyNames = ["rows", "columns", "regions"]
        func unitIndex(_ cell: Int, family: Int) -> Int {
            family == 0 ? cell / p.size : family == 1 ? cell % p.size : p.regions[cell]
        }
        for source in 0..<3 {
            let unfinished = (0..<p.size).filter { confirmed.isDisjoint(with: allUnits[source * p.size + $0].1) }
            guard unfinished.count >= 2 else { continue }
            for i in 0..<(unfinished.count - 1) {
                for j in (i + 1)..<unfinished.count {
                    let first = unfinished[i], second = unfinished[j]
                    let pairCells = candidates.filter {
                        let unit = unitIndex($0, family: source)
                        return unit == first || unit == second
                    }
                    for target in 0..<3 where target != source {
                        let occupied = Set(pairCells.map { unitIndex($0, family: target) })
                        guard occupied.count == 2 else { continue }
                        let excluded = candidates.filter { !pairCells.contains($0) && occupied.contains(unitIndex($0, family: target)) }
                        if !excluded.isEmpty {
                            let names = occupied.sorted().map { String($0 + 1) }.joined(separator: " and ")
                            return Deduction(excluded: excluded,
                                             explanation: "The two \(familyNames[source]) \(first + 1) and \(second + 1) need two capybaras. All their remaining candidates lie in \(familyNames[target]) \(names), so both of those \(familyNames[target]) are reserved for this pair. Exclude their highlighted cells outside the pair.",
                                             rule: "Two-unit lock")
                        }
                    }
                }
            }
        }
        return nil
    }

    public static func next(puzzle p: Puzzle, found: Set<Int>, marks: Set<Int>) -> PuzzleHint? {
        guard (1...16).contains(p.size), p.regions.count == p.size * p.size,
              p.regions.allSatisfy({ (0..<p.size).contains($0) }), Set(p.regions).count == p.size else { return nil }
        // Marks are deliberately NOT constraints: a player's incorrect X cannot poison a hint.
        let all = Set(p.regions.indices)
        guard found.isSubset(of: all) else { return nil }
        // Found animals come from accepted gameplay submissions. Validate those assumptions
        // against the rules, not the stored answer, so this hint engine is answer-independent.
        if !found.isEmpty && PuzzleSolver.solutions(size: p.size, regions: p.regions, limit: 1, required: found.sorted()).isEmpty { return nil }
        var confirmed = found
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
        for cell in candidates.sorted() where !marks.contains(cell) {
            if PuzzleSolver.solutions(size: p.size, regions: p.regions, limit: 1, required: found.sorted() + [cell]).isEmpty {
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

    /// Eligibility gate for the current nine-step Level 1 introduction.
    /// A valid puzzle alone is insufficient: its highlighted operations and the
    /// complete action path must follow a current logical deduction, not the saved answer.
    public static func canTeach(puzzle p: Puzzle) -> Bool {
        guard p.id == 1, p.size == 4, PuzzleSolver.validate(p).valid else { return false }
        let steps = tutorial(puzzle: p)
        guard steps.map(\.id) == ["row", "column", "region", "neighbors", "mark", "undo", "swipe", "swipeVertical", "find"],
              steps.map(\.action) == ["read", "read", "read", "read", "tap", "tap", "swipe", "swipe", "doubleTap"] else { return false }
        let cells = Set(p.regions.indices)
        guard steps.allSatisfy({ !$0.targetCells.isEmpty && Set($0.targetCells).count == $0.targetCells.count && Set($0.targetCells).isSubset(of: cells) }),
              steps[8].targetCells.count == 1, let animal = steps[8].targetCells.first,
              let proof = deduction(p, candidates: cells, confirmed: []), proof.forced == animal else { return false }

        // The four rule demonstrations must describe this board and this animal.
        let row = Set(cells.filter { $0 / p.size == animal / p.size })
        let column = Set(cells.filter { $0 % p.size == animal % p.size })
        let region = Set(cells.filter { p.regions[$0] == p.regions[animal] })
        let neighbors = Set(cells.filter {
            $0 != animal && abs($0 / p.size - animal / p.size) <= 1 && abs($0 % p.size - animal % p.size) <= 1
        })
        guard Set(steps[0].targetCells) == row, Set(steps[1].targetCells) == column,
              Set(steps[2].targetCells) == region, Set(steps[3].targetCells) == neighbors,
              steps[4].targetCells.count == 1, steps[4].targetCells == steps[5].targetCells else { return false }

        var marks = Set<Int>()
        for step in steps[4...7] {
            let targets = Set(step.targetCells)
            guard targets.isSubset(of: proof.excluded) else { return false }
            if step.action == "tap" {
                let cell = step.targetCells[0]
                if marks.contains(cell) { marks.remove(cell) } else { marks.insert(cell) }
            } else {
                // Both cells must still be available so partial swipe callbacks
                // cannot finish the next instruction before its own swipe occurs.
                guard targets.count == 2, targets.isDisjoint(with: marks) else { return false }
                let ordered = step.targetCells.sorted()
                if step.id == "swipe" {
                    guard ordered[0] / p.size == ordered[1] / p.size,
                          ordered[1] - ordered[0] == 1 else { return false }
                } else {
                    guard ordered[0] % p.size == ordered[1] % p.size,
                          ordered[1] - ordered[0] == p.size else { return false }
                }
                marks.formUnion(targets)
            }
        }
        return !marks.contains(animal)
    }

    public static func tutorial(puzzle p: Puzzle) -> [TutorialStep] {
        guard (1...16).contains(p.size), p.regions.count == p.size * p.size,
              p.regions.allSatisfy({ (0..<p.size).contains($0) }),
              let proof = deduction(p, candidates: Set(p.regions.indices), confirmed: []),
              let animal = proof.forced, let safe = proof.excluded.sorted().first else { return [] }
        var swipe = [Int]()
        for row in 0..<p.size {
            for col in 0..<(p.size - 1) {
                let a = row * p.size + col, b = a + 1
                if proof.excluded.contains(a) && proof.excluded.contains(b) { swipe = [a, b]; break }
            }
            if !swipe.isEmpty { break }
        }
        var verticalSwipe = [Int]()
        for col in 0..<p.size {
            for row in 0..<(p.size - 1) {
                let a = row * p.size + col, b = a + p.size
                if proof.excluded.contains(a) && proof.excluded.contains(b) && !swipe.contains(a) && !swipe.contains(b) {
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
            TutorialStep(id: "mark", title: "Tap to mark X", instruction: "The single-cell region already tells us where a capybara must be. The highlighted cell conflicts with it. Tap to mark X.", targetCells: [safe], action: "tap"),
            TutorialStep(id: "undo", title: "Tap again to undo", instruction: "Tap the same cell again to remove the X.", targetCells: [safe], action: "tap"),
            TutorialStep(id: "swipe", title: "Swipe across a row", instruction: "Swipe from the first highlighted cell to the second to mark both cells.", targetCells: swipe, action: "swipe"),
            TutorialStep(id: "swipeVertical", title: "Swipe down a column", instruction: "Now swipe vertically between the two highlighted cells. Straight swipes mark X; diagonal swipes do not.", targetCells: verticalSwipe, action: "swipe"),
            TutorialStep(id: "find", title: "Double-tap to find", instruction: "The highlighted region has only one cell, so its capybara must be here. Double-tap to find it, then use the four rules to find the rest.", targetCells: [animal], action: "doubleTap")
        ]
    }
}
