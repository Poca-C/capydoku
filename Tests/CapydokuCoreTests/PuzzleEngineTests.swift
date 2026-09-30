import XCTest
@testable import CapydokuCore

final class PuzzleEngineTests: XCTestCase {
    func testRowStripesHaveTwoSolutionsAndRejectDiagonalTouching() {
        let n = 4, regions = (0..<16).map { $0 / 4 }
        let solutions = PuzzleSolver.solutions(size: n, regions: regions, limit: 10)
        XCTAssertEqual(solutions, [[1, 7, 8, 14], [2, 4, 11, 13]])
        let puzzle = Puzzle(id: 1, size: n, regions: regions, solution: [0, 5, 10, 15], seed: 0, generatorVersion: "test", difficulty: "test")
        let report = PuzzleSolver.validate(puzzle)
        XCTAssertFalse(report.valid)
        XCTAssertEqual(report.solutionCount, 2)
        XCTAssertTrue(report.errors.contains("存储答案不满足所有规则"))
    }

    func testNoSolutionAndMalformedRegionsReturnSafely() {
        XCTAssertEqual(PuzzleSolver.solutions(size: 2, regions: [0, 0, 1, 1]), [])
        XCTAssertEqual(PuzzleSolver.solutions(size: 4, regions: [0]), [])
        XCTAssertEqual(PuzzleSolver.solutions(size: 4, regions: Array(repeating: -1, count: 16)), [])
        XCTAssertEqual(PuzzleSolver.solutions(size: 99, regions: []), [])
        let invalid = Puzzle(id: 1, size: 0, regions: [], solution: [], seed: 0, generatorVersion: "test", difficulty: "test")
        XCTAssertFalse(PuzzleSolver.validate(invalid).valid)
    }

    func testDisconnectedRegionIsRejected() {
        let labels = [0, 1, 1, 1,
                      2, 0, 1, 1,
                      2, 2, 2, 3,
                      2, 2, 3, 3]
        XCTAssertFalse(PuzzleSolver.regionsAreConnected(size: 4, regions: labels))
    }

    func testSeedReproductionAndAllSupportedBoardSizes() throws {
        for level in [1, 11, 51, 101] {
            let a = try PuzzleGenerator.generate(level: level, seed: UInt64(level))
            let b = try PuzzleGenerator.generate(level: level, seed: UInt64(level))
            XCTAssertEqual(a, b)
            XCTAssertTrue(PuzzleSolver.validate(a).valid, "Level \(level)")
            XCTAssertEqual(a.solution.count, a.size)
            XCTAssertEqual(Set(a.solution.map { $0 / a.size }).count, a.size)
            XCTAssertEqual(Set(a.solution.map { $0 % a.size }).count, a.size)
            XCTAssertEqual(Set(a.solution.map { a.regions[$0] }).count, a.size)
            for x in a.solution { for y in a.solution where x != y { XCTAssertFalse(a.conflicts(x, y)) } }
        }
    }

    func testGeneratorBudgetsAndEndlessSizeCap() {
        XCTAssertThrowsError(try PuzzleGenerator.generate(level: 0))
        XCTAssertThrowsError(try PuzzleGenerator.generate(level: 1, maxAttempts: 0))
        XCTAssertThrowsError(try PuzzleGenerator.generate(level: 1, timeBudgetMilliseconds: 0))
        for level in 151...1000 { XCTAssertLessThanOrEqual(PuzzleGenerator.size(for: level), 10) }
        XCTAssertEqual(PuzzleGenerator.difficulty(for: 160), "Hard")
        XCTAssertEqual(PuzzleGenerator.difficulty(for: 161), "Flow")
        XCTAssertEqual(PuzzleGenerator.difficulty(for: 166), "Recovery")
        for start in [151, 161, 171] {
            let roles = (start..<(start + 10)).map { PuzzleGenerator.difficulty(for: $0) }
            XCTAssertEqual(roles.filter { $0 == "Flow" }.count, 2)
            XCTAssertEqual(roles.filter { $0 == "Recovery" }.count, 1)
            XCTAssertEqual(roles.last, "Hard")
        }
    }

    func testExperimentalThreeTenLevelGroupsWithRuntimeBudget() throws {
        let configuration = DemoConfig.default
        let catalogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/levels.json")
        let fixed = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: catalogURL))
        var corpus = fixed.map { SimilarityCorpusEntry(game: "CapyDoku", puzzle: $0) }
        var fingerprints = Set<String>()
        for level in 151...180 {
            let started = ProcessInfo.processInfo.systemUptime
            let puzzle: Puzzle
            do {
                let result = try PuzzleGenerator.generateAudited(level: level, corpus: corpus,
                    maxAttempts: configuration.generatorCandidateLimit,
                    timeBudgetMilliseconds: configuration.generatorBudgetMilliseconds)
                puzzle = try XCTUnwrap(result.puzzle, "Strict batch failed at \(level): \(result.report.rejectionReasons)")
                XCTAssertEqual(result.report.selectedSimilarityReport?.comparedBoards, level - 1)
                XCTAssertEqual(result.report.selectedSimilarityReport?.exceptions, [])
                corpus.append(SimilarityCorpusEntry(game: "CapyDoku", puzzle: puzzle))
            } catch {
                let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                XCTFail("Level \(level) failed after \(milliseconds) ms with \(configuration.generatorBudgetMilliseconds) ms budget: \(error)")
                return
            }
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            print("GENERATION_BUDGET level=\(level) elapsed_ms=\(milliseconds) budget_ms=\(configuration.generatorBudgetMilliseconds)")
            XCTAssertTrue(PuzzleSolver.validate(puzzle).valid, "Level \(level)")
            XCTAssertTrue(fingerprints.insert(puzzle.fingerprint).inserted)
            let restored = try JSONDecoder().decode(Puzzle.self, from: JSONEncoder().encode(puzzle))
            XCTAssertEqual(restored, puzzle)
        }
        XCTAssertEqual(fingerprints.count, 30)
    }

    func testHintsNeverTrustWrongPlayerMarksAndOnlyEliminateSafeCells() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent("Resources/levels.json")))
        for level in [1, 13, 54, 105] {
            let puzzle = try XCTUnwrap(catalog.first { $0.id == level })
            var marks = Set(puzzle.solution) // every answer incorrectly crossed out by the user
            let found = Set(puzzle.solution.prefix(1))
            var seenHint = false
            for _ in 0..<puzzle.size * puzzle.size {
                guard let hint = PuzzleHints.next(puzzle: puzzle, found: found, marks: marks) else { break }
                seenHint = true
                XCTAssertFalse(hint.cells.isEmpty)
                XCTAssertTrue(Set(hint.cells).isDisjoint(with: Set(puzzle.solution)))
                XCTAssertTrue(Set(hint.cells).isDisjoint(with: marks))
                XCTAssertFalse(hint.explanation.isEmpty)
                marks.formUnion(hint.cells)
            }
            XCTAssertTrue(seenHint)
            XCTAssertEqual(marks.count, puzzle.size * puzzle.size)
        }
    }

    func testFingerprintIgnoresRegionNamesAndTutorialTargetsMatchBoard() throws {
        let puzzle = try PuzzleGenerator.generate(level: 1)
        var renamed = puzzle
        renamed.regions = puzzle.regions.map { puzzle.size - 1 - $0 }
        XCTAssertEqual(puzzle.fingerprint, renamed.fingerprint)
        let steps = PuzzleHints.tutorial(puzzle: puzzle)
        XCTAssertEqual(steps.count, 9)
        XCTAssertEqual(steps.filter { $0.action == "swipe" }.count, 2)
        XCTAssertEqual(Set(steps.prefix(4).map(\.id)), Set(["row", "column", "region", "neighbors"]))
        for step in steps where step.action == "tap" || step.action == "swipe" {
            XCTAssertFalse(step.targetCells.isEmpty)
            XCTAssertTrue(Set(step.targetCells).isDisjoint(with: Set(puzzle.solution)))
        }
        let teachingCell = try XCTUnwrap(steps.last?.targetCells.first)
        XCTAssertTrue(puzzle.solution.contains(teachingCell))
        XCTAssertEqual(puzzle.regions.filter { $0 == puzzle.regions[teachingCell] }.count, 1)
    }
}
