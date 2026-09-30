import XCTest
@testable import CapydokuCore

final class HintQualityTests: XCTestCase {
    private func catalog(legacy: Bool = false) throws -> [Puzzle] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent(legacy ? "Resources/levels-legacy-v2.json" : "Resources/levels.json")))
    }

    private func exhaustHints(_ puzzle: Puzzle, initialMarks: Set<Int> = []) -> (Set<Int>, [String: Int]) {
        var marks = initialMarks, rules = [String: Int]()
        var answerless = puzzle
        answerless.solution = []
        for _ in 0..<(puzzle.size * puzzle.size + 1) {
            guard let hint = PuzzleHints.next(puzzle: puzzle, found: [], marks: marks) else { break }
            XCTAssertEqual(PuzzleHints.next(puzzle: answerless, found: [], marks: marks), hint,
                           "Level \(puzzle.id) must not inspect the stored answer")
            XCTAssertFalse(hint.cells.isEmpty)
            XCTAssertTrue(Set(hint.cells).isDisjoint(with: Set(puzzle.solution)))
            XCTAssertTrue(Set(hint.cells).isDisjoint(with: marks))
            XCTAssertFalse(hint.explanation.isEmpty)
            rules[hint.rule, default: 0] += 1
            marks.formUnion(hint.cells)
        }
        return (marks, rules)
    }

    // Keep these known boundary-rule boards as legacy fixtures; production levels may change.
    func testCommonConflictProvidesSafeAnswerIndependentDeductions() throws {
        let p = try XCTUnwrap(catalog(legacy: true).first { $0.id == 2 })
        let (marks, rules) = exhaustHints(p)
        XCTAssertGreaterThan(rules["Common conflict", default: 0], 0)
        XCTAssertEqual(rules["Contradiction check", default: 0], 0)
        XCTAssertEqual(Set(p.regions.indices).subtracting(marks), Set(p.solution))
    }

    func testTwoUnitLockCompletesPreviouslySearchDependentBoard() throws {
        let p = try XCTUnwrap(catalog(legacy: true).first { $0.id == 24 })
        let (marks, rules) = exhaustHints(p)
        XCTAssertGreaterThan(rules["Two-unit lock", default: 0], 0)
        XCTAssertEqual(rules["Contradiction check", default: 0], 0)
        XCTAssertFalse(PuzzleSolver.validate(p).logicalMetrics.requiresSearch)
        XCTAssertEqual(Set(p.regions.indices).subtracting(marks), Set(p.solution))
    }

    func testSearchFallbackIsExplicitAndAlsoAnswerIndependent() throws {
        let p = try XCTUnwrap(catalog(legacy: true).first { $0.id == 18 })
        let (marks, rules) = exhaustHints(p)
        XCTAssertGreaterThan(rules["Contradiction check", default: 0], 0)
        XCTAssertTrue(PuzzleSolver.validate(p).logicalMetrics.requiresSearch)
        XCTAssertEqual(Set(p.regions.indices).subtracting(marks), Set(p.solution))
    }

    func testWrongPlayerMarksCannotPoisonNewRules() throws {
        let p = try XCTUnwrap(catalog(legacy: true).first { $0.id == 24 })
        let (marks, rules) = exhaustHints(p, initialMarks: Set(p.solution))
        XCTAssertGreaterThan(rules["Two-unit lock", default: 0], 0)
        XCTAssertEqual(marks, Set(p.regions.indices))
    }

    func testImpossibleFoundStateReturnsNoHintWithoutUsingStoredAnswer() throws {
        var p = try XCTUnwrap(catalog().first)
        let correct = try XCTUnwrap(p.solution.first)
        let wrong = try XCTUnwrap(p.regions.indices.first { !p.solution.contains($0) })
        p.solution = []
        XCTAssertNotNil(PuzzleHints.next(puzzle: p, found: [correct], marks: []))
        XCTAssertNil(PuzzleHints.next(puzzle: p, found: [wrong], marks: []))
        XCTAssertNil(PuzzleHints.next(puzzle: p, found: [p.size * p.size], marks: []))
    }

    func testHintsPreserveEverySolutionOfAnAmbiguousBoard() {
        let p = Puzzle(id: 0, size: 4, regions: (0..<16).map { $0 / 4 }, solution: [],
                       seed: 0, generatorVersion: "test", difficulty: "test")
        let solutions = PuzzleSolver.solutions(size: p.size, regions: p.regions, limit: 20)
        XCTAssertEqual(solutions.count, 2)
        let possibleAnimals = Set(solutions.flatMap { $0 })
        var marks = Set<Int>()
        for _ in 0..<16 {
            guard let hint = PuzzleHints.next(puzzle: p, found: [], marks: marks) else { break }
            XCTAssertTrue(Set(hint.cells).isDisjoint(with: possibleAnimals))
            marks.formUnion(hint.cells)
        }
        XCTAssertEqual(marks, Set(p.regions.indices).subtracting(possibleAnimals))
    }

    func testFixedCatalogKeepsValidityAndImprovedLogicCoverage() throws {
        let puzzles = try catalog()
        XCTAssertEqual(puzzles.count, 150)
        var solved = 0
        for p in puzzles {
            let report = PuzzleSolver.validate(p)
            XCTAssertTrue(report.valid, "Level \(p.id): \(report.errors)")
            if !report.logicalMetrics.requiresSearch { solved += 1 }
        }
        XCTAssertEqual(solved, 150, "Current strict production targets reject boards requiring search")
    }
}
