import Foundation

/// Counts answer permutations independently of region shapes. This is only an
/// upper bound on usable puzzles: solver, difficulty and similarity checks still
/// decide whether a generated candidate is acceptable.
enum PuzzleAnswerCapacity {
    static func total(size: Int) -> Int {
        guard [4, 6, 8, 10].contains(size) else { return 0 }
        var memo: [Int: Int] = [:]
        let all = (1 << size) - 1
        func count(mask: Int, previous: Int) -> Int {
            if mask == all { return 1 }
            let key = mask * (size + 1) + previous + 1
            if let value = memo[key] { return value }
            var result = 0
            for column in 0..<size where mask & (1 << column) == 0 {
                if previous >= 0 && abs(column - previous) <= 1 { continue }
                result += count(mask: mask | (1 << column), previous: column)
            }
            memo[key] = result
            return result
        }
        return count(mask: 0, previous: -1)
    }

    static func used(size: Int, corpus: [SimilarityCorpusEntry]) -> Int {
        // Ignore malformed or duplicate corpus fingerprints. They cannot prove
        // that additional legal answer permutations have already been used.
        var answers = Set<[Int]>()
        for entry in corpus where entry.fingerprint.gridSize == size {
            let cells = entry.fingerprint.answerPattern.sorted()
            guard cells.count == size,
                  cells.allSatisfy({ $0 >= 0 && $0 < size * size }),
                  cells.enumerated().allSatisfy({ $0.element / size == $0.offset }),
                  Set(cells.map { $0 % size }).count == size,
                  zip(cells, cells.dropFirst()).allSatisfy({ abs($0 % size - $1 % size) > 1 }) else { continue }
            answers.insert(cells)
        }
        return answers.count
    }
}
