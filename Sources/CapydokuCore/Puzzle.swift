import Foundation

/// A complete, reproducible one-capybara-per-row/column/region board.
public struct Puzzle: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var size: Int
    public var regions: [Int]
    public var solution: [Int]
    public var seed: UInt64
    public var generatorVersion: String
    public var difficulty: String
    public var generationMetadata: PuzzleGenerationMetadata?

    public init(id: Int, size: Int, regions: [Int], solution: [Int], seed: UInt64,
                generatorVersion: String, difficulty: String, generationMetadata: PuzzleGenerationMetadata? = nil) {
        self.id = id; self.size = size; self.regions = regions
        self.solution = solution.sorted(); self.seed = seed
        self.generatorVersion = generatorVersion; self.difficulty = difficulty
        self.generationMetadata = generationMetadata
    }

    public func isSolutionCell(_ cell: Int) -> Bool { solution.contains(cell) }

    /// Stable FNV-1a of geometry with region names canonicalized. Not Swift's random Hasher.
    public var fingerprint: String {
        var labels: [Int: Int] = [:]
        var next = 0
        let canonical = regions.map { region -> Int in
            if let value = labels[region] { return value }
            defer { next += 1 }; labels[region] = next; return next
        }
        let text = "\(size):" + canonical.map(String.init).joined(separator: ",")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }

    public func orthogonalNeighbors(of cell: Int) -> [Int] {
        guard (1...16).contains(size), (0..<(size * size)).contains(cell) else { return [] }
        let r = cell / size, c = cell % size
        return [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)]
            .filter { $0.0 >= 0 && $0.0 < size && $0.1 >= 0 && $0.1 < size }
            .map { $0.0 * size + $0.1 }
    }

    public func conflicts(_ a: Int, _ b: Int) -> Bool {
        guard (1...16).contains(size), regions.count == size * size,
              (0..<regions.count).contains(a), (0..<regions.count).contains(b) else { return false }
        return a / size == b / size || a % size == b % size || regions[a] == regions[b]
            || (abs(a / size - b / size) <= 1 && abs(a % size - b % size) <= 1)
    }
}

public struct PuzzleLogicalMetrics: Codable, Equatable, Sendable {
    public let initialForcedCells: Int
    public let deductionSteps: Int
    public let remainingUnresolved: Int
    public let requiresSearch: Bool
}

public struct PuzzleValidationReport: Codable, Equatable, Sendable {
    public let valid: Bool
    public let solutionCount: Int
    public let regionConnected: Bool
    public let errors: [String]
    public let logicalMetrics: PuzzleLogicalMetrics
}

/// Rules that can be explained using only the currently visible capybaras.
public enum VisibleConflictKind: String, CaseIterable, Codable, Sendable {
    case region, row, column, adjacent
}

public struct VisiblePuzzleConflict: Equatable, Sendable {
    public let otherCell: Int
    public let kinds: [VisibleConflictKind]

    public init(otherCell: Int, kinds: [VisibleConflictKind]) {
        self.otherCell = otherCell
        self.kinds = kinds
    }
}

public enum VisibleConflictAnalysis {
    /// Explains a candidate against visible found/given cells without consulting the answer.
    /// Results are ordered by cell index, with kinds in region/row/column/adjacent order.
    /// An empty result means no *visible* conflict, not that the candidate is an answer.
    public static func conflicts(size: Int, regions: [Int], candidate: Int,
                                 found: Set<Int>) -> [VisiblePuzzleConflict] {
        // Match the core board shape contract; bound size before multiplying to avoid overflow.
        guard (1...16).contains(size), regions.count == size * size,
              regions.allSatisfy({ (0..<size).contains($0) }), Set(regions).count == size,
              regions.indices.contains(candidate),
              found.allSatisfy({ regions.indices.contains($0) }),
              !found.contains(candidate) else { return [] }

        let row = candidate / size, column = candidate % size
        return found.sorted().compactMap { otherCell in
            let otherRow = otherCell / size, otherColumn = otherCell % size
            var kinds: [VisibleConflictKind] = []
            if regions[candidate] == regions[otherCell] { kinds.append(.region) }
            if row == otherRow { kinds.append(.row) }
            if column == otherColumn { kinds.append(.column) }
            if abs(row - otherRow) <= 1 && abs(column - otherColumn) <= 1 {
                kinds.append(.adjacent)
            }
            return kinds.isEmpty ? nil : VisiblePuzzleConflict(otherCell: otherCell, kinds: kinds)
        }
    }
}
