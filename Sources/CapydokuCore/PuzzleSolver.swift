import Foundation

public enum PuzzleSolver {
    public static func solutions(size: Int, regions: [Int], limit: Int = 2) -> [[Int]] {
        solutions(size: size, regions: regions, limit: limit, required: [])
    }

    /// MRV search, with at most `limit` results. All row, column, region and 8-neighbor rules apply.
    static func solutions(size n: Int, regions: [Int], limit: Int, required: [Int]) -> [[Int]] {
        guard (1...16).contains(n), regions.count == n * n, limit > 0,
              regions.allSatisfy({ (0..<n).contains($0) }), Set(regions).count == n else { return [] }
        var forced = [Int: Int]()
        for cell in required {
            guard (0..<(n * n)).contains(cell) else { return [] }
            let row = cell / n, col = cell % n
            if let existing = forced[row], existing != col { return [] }
            forced[row] = col
        }
        var columns = Array(repeating: -1, count: n)
        var results = [[Int]]()
        let allColumns: UInt32 = (1 << n) - 1
        let forcedMasks: [UInt32] = (0..<n).map { row in forced[row].map { UInt32(1) << $0 } ?? allColumns }
        let regionMasks: [UInt32] = regions.map { UInt32(1) << $0 }
        func visit(_ depth: Int, _ usedColumns: UInt32, _ usedRegions: UInt32) {
            guard results.count < limit else { return }
            if depth == n {
                results.append(columns.enumerated().map { $0.offset * n + $0.element }); return
            }
            var selected = -1, choices: UInt32 = 0, bestCount = n + 1
            for row in 0..<n where columns[row] < 0 {
                var options = forcedMasks[row] & ~usedColumns
                if row > 0 && columns[row - 1] >= 0 {
                    let bit = UInt32(1) << columns[row - 1]
                    options &= ~(bit | (bit << 1) | (bit >> 1))
                }
                if row + 1 < n && columns[row + 1] >= 0 {
                    let bit = UInt32(1) << columns[row + 1]
                    options &= ~(bit | (bit << 1) | (bit >> 1))
                }
                var inspect = options
                while inspect != 0 {
                    let col = inspect.trailingZeroBitCount
                    inspect &= inspect - 1
                    if usedRegions & regionMasks[row * n + col] != 0 { options &= ~(UInt32(1) << col) }
                }
                let count = options.nonzeroBitCount
                if count == 0 { return }
                if count < bestCount { selected = row; choices = options; bestCount = count }
                if count == 1 { break }
            }
            while choices != 0 {
                let col = choices.trailingZeroBitCount
                choices &= choices - 1
                columns[selected] = col
                visit(depth + 1, usedColumns | (1 << col), usedRegions | regionMasks[selected * n + col])
                columns[selected] = -1
                if results.count >= limit { return }
            }
        }
        visit(0, 0, 0)
        return results
    }

    public static func validate(_ puzzle: Puzzle) -> PuzzleValidationReport {
        let n = puzzle.size
        var errors: [String] = []
        let shapeValid = (1...16).contains(n) && puzzle.regions.count == n * n
            && puzzle.regions.allSatisfy { (0..<n).contains($0) } && Set(puzzle.regions).count == n
        if !shapeValid { errors.append("棋盘尺寸、区域数量或区域标签不合法") }
        let connected = shapeValid && regionsAreConnected(size: n, regions: puzzle.regions)
        if !connected { errors.append("区域必须通过上下左右连通") }
        let all = shapeValid ? solutions(size: n, regions: puzzle.regions, limit: 2) : []
        if all.isEmpty { errors.append("棋盘无解") }
        if all.count > 1 { errors.append("棋盘不具有唯一解") }
        let storedValid = shapeValid && puzzle.solution.count == n && Set(puzzle.solution).count == n
            && puzzle.solution.allSatisfy { (0..<(n * n)).contains($0) }
            && solutions(size: n, regions: puzzle.regions, limit: 1, required: puzzle.solution).first == puzzle.solution.sorted()
        if !storedValid { errors.append("存储答案不满足所有规则") }
        if all.count == 1 && Set(all[0]) != Set(puzzle.solution) { errors.append("存储答案与唯一解不一致") }
        let metrics = shapeValid && storedValid ? PuzzleHints.metrics(puzzle: puzzle)
            : PuzzleLogicalMetrics(initialForcedCells: 0, deductionSteps: 0, remainingUnresolved: max(0, n), requiresSearch: true)
        return PuzzleValidationReport(valid: errors.isEmpty, solutionCount: all.count,
                                      regionConnected: connected, errors: errors, logicalMetrics: metrics)
    }

    public static func regionsAreConnected(size n: Int, regions: [Int]) -> Bool {
        guard (1...16).contains(n), regions.count == n * n, Set(regions) == Set(0..<n) else { return false }
        for region in 0..<n {
            let cells = Set(regions.indices.filter { regions[$0] == region })
            guard let start = cells.first else { return false }
            var seen: Set<Int> = [start], todo = [start]
            while let cell = todo.popLast() {
                let row = cell / n, col = cell % n
                for (r, c) in [(row - 1, col), (row + 1, col), (row, col - 1), (row, col + 1)]
                    where r >= 0 && r < n && c >= 0 && c < n {
                    let next = r * n + c
                    if cells.contains(next) && seen.insert(next).inserted { todo.append(next) }
                }
            }
            if seen != cells { return false }
        }
        return true
    }
}
