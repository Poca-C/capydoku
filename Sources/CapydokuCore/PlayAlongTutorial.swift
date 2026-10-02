import Foundation

/// A complete, visible-board lesson. Planning never reads the stored answer or seed,
/// and placing an animal does not silently mark its conflicts on the player's behalf.
enum PlayAlongTutorial {
    private struct ForcedCell {
        var cell: Int
        var family: String
        var unit: [Int]
    }

    static func steps(puzzle p: Puzzle) -> [TutorialStep] {
        guard validShape(p) else { return [] }
        let all = Set(p.regions.indices)
        guard let first = forcedCell(p, marks: [], found: []), first.family == "region",
              first.unit.count == 1 else { return [] }
        var result = [TutorialStep](), marks = Set<Int>(), found = Set<Int>()
        var foundOrder = [Int](), taughtNeighbors = false

        func append(_ id: String, _ title: String, _ instruction: String, _ targets: [Int],
                    _ action: String, focus: [Int]) {
            result.append(TutorialStep(id: id, title: title, instruction: instruction,
                targetCells: targets, action: action, focusCells: Array(Set(focus)).sorted()))
        }
        func place(_ proof: ForcedCell) {
            let last = found.count == p.size - 1
            let ordinal = found.count + 1
            if last {
                append("finish_\(ordinal)", "Find the last capybara", "One capybara left. Find it yourself, or tap Hint if you need a hand.",
                       [proof.cell], "finish", focus: all.sorted())
            } else if found.isEmpty {
                append("find_1", "Find the first capybara", "Each color region has one capybara. Double-tap the only cell in this region.",
                       [proof.cell], "doubleTap", focus: proof.unit)
            } else {
                append("find_\(ordinal)", "One space left in this \(proof.family)",
                       "The X marks leave only one space in this \(proof.family). Double-tap to find its capybara.",
                       [proof.cell], "doubleTap", focus: proof.unit)
            }
            found.insert(proof.cell); foundOrder.append(proof.cell)
        }
        func exclude(_ cells: [Int], family: String, focus: [Int]) {
            let instructions: [String: String] = [
                "neighbors": "Capybaras cannot touch, even diagonally. Mark these neighboring cells with X.",
                "region": "This color region already has its capybara. Mark the remaining spaces with X.",
                "row": "This row already has its capybara. Mark its remaining spaces with X.",
                "column": "This column already has its capybara. Mark its remaining spaces with X.",
                "lines": "One capybara per row and column. Mark the remaining highlighted spaces with X."
            ]
            append("exclude_\(family)_\(result.count + 1)", family == "neighbors" ? "Give them space" : "Cross out the remaining spaces",
                   instructions[family] ?? "Use the visible rule to mark these spaces with X.", cells.sorted(), "exclude", focus: focus)
            marks.formUnion(cells)
            if family == "neighbors" { taughtNeighbors = true }
        }
        place(first)
        let row = p.regions.indices.filter { $0 / p.size == first.cell / p.size }
        let column = p.regions.indices.filter { $0 % p.size == first.cell % p.size }
        let rowEmpty = row.filter { $0 != first.cell }, columnEmpty = column.filter { $0 != first.cell }
        guard let tap = rowEmpty.first,
              let horizontal = consecutivePair(rowEmpty, stride: 1),
              let vertical = consecutivePair(columnEmpty, stride: p.size) else { return [] }
        append("mark", "Tap to mark X", "This row already has its capybara. Tap the highlighted space to mark X.", [tap], "tap", focus: row)
        marks.insert(tap)
        append("undo", "Tap again to undo", "Tap the same X again to remove it.", [tap], "tap", focus: row)
        marks.remove(tap)
        append("swipe", "Swipe across a row", "One capybara per row. Swipe across these spaces to mark X.", horizontal, "swipe", focus: row)
        marks.formUnion(horizontal)
        append("swipeVertical", "Swipe down a column", "One capybara per column. Swipe down these spaces to mark X.", vertical, "swipe", focus: column)
        marks.formUnion(vertical)
        let remainingLines = Set(rowEmpty + columnEmpty).subtracting(marks)
        if !remainingLines.isEmpty { exclude(remainingLines.sorted(), family: "lines", focus: row + column) }

        for _ in 0..<(p.size * p.size * 2) {
            if found.count == p.size { return taughtNeighbors ? result : [] }
            // After the second placement, show the touching rule through a real
            // exclusion, even when another singleton could otherwise be found.
            if !taughtNeighbors && found.count >= 2,
               let exclusion = knownExclusion(p, foundOrder: foundOrder, found: found, marks: marks, families: ["neighbors"]) {
                exclude(exclusion.cells, family: exclusion.family, focus: exclusion.focus); continue
            }
            if let proof = forcedCell(p, marks: marks, found: found) {
                place(proof); continue
            }
            if let exclusion = knownExclusion(p, foundOrder: foundOrder, found: found, marks: marks,
                                               families: ["neighbors", "region", "row", "column"]) {
                exclude(exclusion.cells, family: exclusion.family, focus: exclusion.focus); continue
            }
            let candidates = all.subtracting(marks).subtracting(found)
            if let proof = PuzzleHints.deduction(p, candidates: candidates, confirmed: found), !proof.excluded.isEmpty {
                let cells = proof.excluded.subtracting(marks).subtracting(found).sorted()
                guard !cells.isEmpty else { return [] }
                append("exclude_deduction_\(result.count + 1)", "Follow the visible clues", proof.explanation,
                       cells, "exclude", focus: all.sorted())
                marks.formUnion(cells); continue
            }
            return []
        }
        return []
    }

    static func isValid(puzzle p: Puzzle, steps: [TutorialStep]) -> Bool {
        guard validShape(p), !steps.isEmpty, steps.first?.id == "find_1", steps.first?.action == "doubleTap",
              steps.last?.action == "finish", Set(steps.map(\.id)).count == steps.count else { return false }
        let all = Set(p.regions.indices)
        var found = Set<Int>(), marks = Set<Int>(), tapCell: Int?
        var taughtTap = false, taughtUndo = false, taughtHorizontal = false, taughtVertical = false, taughtNeighbors = false
        for (index, step) in steps.enumerated() {
            let targets = Set(step.targetCells)
            guard !targets.isEmpty, targets.count == step.targetCells.count, targets.isSubset(of: all),
                  Set(step.focusCells ?? step.targetCells).isSubset(of: all) else { return false }
            let candidates = all.subtracting(marks).subtracting(found)
            let conflicts = Set(candidates.filter { cell in found.contains { p.conflicts(cell, $0) } })
            let deductions = PuzzleHints.deduction(p, candidates: candidates, confirmed: found)?.excluded ?? []
            let safe = conflicts.union(deductions)
            switch step.action {
            case "doubleTap", "finish":
                guard targets.count == 1, let cell = targets.first,
                      let proof = forcedCell(p, marks: marks, found: found), proof.cell == cell else { return false }
                if index == 0 && (proof.family != "region" || proof.unit.count != 1) { return false }
                if step.action == "finish" && (found.count != p.size - 1 || index != steps.count - 1) { return false }
                found.insert(cell) // Deliberately do not apply the proof's exclusions.
            case "tap":
                guard targets.count == 1, let cell = targets.first else { return false }
                if step.id == "undo" {
                    guard taughtTap, tapCell == cell, marks.contains(cell) else { return false }
                    marks.remove(cell); taughtUndo = true
                } else {
                    guard step.id == "mark", safe.contains(cell), !marks.contains(cell) else { return false }
                    marks.insert(cell); tapCell = cell; taughtTap = true
                }
            case "swipe":
                guard targets.count >= 2, targets.isSubset(of: safe), targets.isDisjoint(with: marks) else { return false }
                let ordered = step.targetCells.sorted()
                let horizontal = ordered.allSatisfy { $0 / p.size == ordered[0] / p.size }
                    && zip(ordered, ordered.dropFirst()).allSatisfy { $0.1 - $0.0 == 1 }
                let vertical = ordered.allSatisfy { $0 % p.size == ordered[0] % p.size }
                    && zip(ordered, ordered.dropFirst()).allSatisfy { $0.1 - $0.0 == p.size }
                guard horizontal || vertical else { return false }
                taughtHorizontal = taughtHorizontal || horizontal; taughtVertical = taughtVertical || vertical
                marks.formUnion(targets)
            case "exclude":
                guard targets.isSubset(of: safe), targets.isDisjoint(with: marks) else { return false }
                if step.id.hasPrefix("exclude_neighbors_") {
                    guard targets.allSatisfy({ cell in found.contains { animal in
                        cell != animal && abs(cell / p.size - animal / p.size) <= 1 && abs(cell % p.size - animal % p.size) <= 1
                    } }) else { return false }
                    taughtNeighbors = true
                }
                marks.formUnion(targets)
            default: return false
            }
            guard marks.isDisjoint(with: found) else { return false }
        }
        return found.count == p.size && taughtTap && taughtUndo && taughtHorizontal && taughtVertical && taughtNeighbors
    }

    private static func validShape(_ p: Puzzle) -> Bool {
        p.id == 1 && p.size == 4 && p.regions.count == 16
            && p.regions.allSatisfy { (0..<4).contains($0) } && Set(p.regions).count == 4
    }

    private static func consecutivePair(_ cells: [Int], stride: Int) -> [Int]? {
        for cell in cells.sorted() where cells.contains(cell + stride) { return [cell, cell + stride] }
        return nil
    }

    private static func forcedCell(_ p: Puzzle, marks: Set<Int>, found: Set<Int>) -> ForcedCell? {
        let families = ["region", "row", "column"]
        for family in families {
            for unit in 0..<p.size {
                let cells = p.regions.indices.filter { cell in
                    family == "region" ? p.regions[cell] == unit : family == "row" ? cell / p.size == unit : cell % p.size == unit
                }
                guard found.isDisjoint(with: cells) else { continue }
                let candidates = cells.filter { !marks.contains($0) && !found.contains($0) }
                if candidates.count == 1 { return ForcedCell(cell: candidates[0], family: family, unit: cells) }
            }
        }
        return nil
    }

    private static func knownExclusion(_ p: Puzzle, foundOrder: [Int], found: Set<Int>, marks: Set<Int>, families: [String])
        -> (cells: [Int], family: String, focus: [Int])? {
        for family in families {
            for animal in foundOrder.reversed() {
                let context = p.regions.indices.filter { cell in
                    switch family {
                    case "neighbors": return abs(cell / p.size - animal / p.size) <= 1 && abs(cell % p.size - animal % p.size) <= 1
                    case "region": return p.regions[cell] == p.regions[animal]
                    case "row": return cell / p.size == animal / p.size
                    default: return cell % p.size == animal % p.size
                    }
                }
                let fresh = context.filter { !marks.contains($0) && !found.contains($0) }
                if !fresh.isEmpty { return (fresh, family, context) }
            }
        }
        return nil
    }
}
