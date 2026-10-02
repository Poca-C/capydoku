import XCTest
@testable import CapydokuCore

final class DynamicTutorialPlanTests: XCTestCase {
    private func firstPuzzle(catalog: String) throws -> Puzzle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = "Resources/\(catalog).json"
        let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent(path)))
        return try XCTUnwrap(puzzles.first { $0.id == 1 })
    }

    func testLegacyPathsRetainShippedStepIdentitiesAndCoordinates() throws {
        let expectedIDs = ["row", "column", "region", "neighbors", "mark", "undo", "swipe", "swipeVertical", "find"]
        let expectedActions = ["read", "read", "read", "read", "tap", "tap", "swipe", "swipe", "doubleTap"]
        // These are the actual two shipped L1 geometries, not generated expectations.
        let cases: [(String, [[Int]])] = [
            ("levels-legacy-v3", [[8, 9, 10, 11], [0, 4, 8, 12], [8], [4, 5, 9, 12, 13], [0], [0], [4, 5], [9, 13], [8]]),
            ("levels-legacy-v2", [[0, 1, 2, 3], [1, 5, 9, 13], [1], [0, 2, 4, 5, 6], [0], [0], [2, 3], [0, 4], [1]])
        ]
        for (legacyCatalog, targets) in cases {
            let steps = PuzzleHints.tutorial(puzzle: try firstPuzzle(catalog: legacyCatalog), version: .legacy)
            XCTAssertEqual(steps.map(\.id), expectedIDs)
            XCTAssertEqual(steps.map(\.action), expectedActions)
            XCTAssertEqual(steps.map(\.targetCells), targets,
                           "Every saved v1 numeric index must keep its original target, including partial swipes.")
        }
    }

    func testDifferentRealBoardsChooseInformativeRuleOrdersAndRemainPlayable() throws {
        let cases: [(String, [String])] = [
            ("levels-legacy-v3", ["region", "neighbors", "row", "column"]),
            ("levels-legacy-v2", ["region", "neighbors", "column", "row"]),
            ("levels", ["region", "neighbors", "column", "row"])
        ]
        var orders = Set<[String]>()
        for (catalog, expectedOrder) in cases {
            let puzzle = try firstPuzzle(catalog: catalog)
            XCTAssertTrue(PuzzleSolver.validate(puzzle).valid)
            XCTAssertTrue(PuzzleHints.canTeach(puzzle: puzzle))
            let steps = PuzzleHints.tutorial(puzzle: puzzle, version: .boardDriven)
            let legacySteps = PuzzleHints.tutorial(puzzle: puzzle, version: .legacy)
            XCTAssertEqual(steps.count, 9)
            let rules = Array(steps.prefix(4))
            XCTAssertEqual(rules.map(\.id), expectedOrder)
            orders.insert(rules.map(\.id))
            XCTAssertEqual(Array(steps.dropFirst(4)), Array(legacySteps.dropFirst(4)),
                           "Reordering the rule explanations must not alter the five operation steps.")

            let animal = try XCTUnwrap(steps.last?.targetCells.first)
            XCTAssertEqual(rules.first?.targetCells, [animal])
            let geometry: [String: Set<Int>] = [
                "region": Set(puzzle.regions.indices.filter { puzzle.regions[$0] == puzzle.regions[animal] }),
                "row": Set(puzzle.regions.indices.filter { $0 / puzzle.size == animal / puzzle.size }),
                "column": Set(puzzle.regions.indices.filter { $0 % puzzle.size == animal % puzzle.size }),
                "neighbors": Set(puzzle.regions.indices.filter {
                    $0 != animal && abs($0 / puzzle.size - animal / puzzle.size) <= 1 && abs($0 % puzzle.size - animal % puzzle.size) <= 1
                })
            ]
            for rule in rules {
                XCTAssertEqual(rule.action, "read")
                XCTAssertEqual(Set(rule.targetCells), geometry[rule.id])
            }
            // These boards teach five neighboring exclusions first. Their orientation
            // changes which line adds two NEW cells and which adds only one.
            var explained = Set<Int>()
            let newExclusionCounts = rules.map { step -> Int in
                let exclusions = Set(step.targetCells).subtracting([animal])
                let count = exclusions.subtracting(explained).count
                explained.formUnion(exclusions)
                return count
            }
            XCTAssertEqual(newExclusionCounts, [0, 5, 2, 1])
            for version in [TutorialPlanVersion.legacy, .boardDriven] {
                try followEveryStep(puzzle, version: version)
            }
        }
        XCTAssertEqual(orders.count, 2, "The rule order must respond to board geometry.")
    }

    func testPlanVersionsAreStableAndDoNotReadTheStoredAnswerOrSeed() throws {
        XCTAssertEqual(TutorialPlanVersion.current, .playAlong)
        XCTAssertEqual(try JSONEncoder().encode(TutorialPlanVersion.legacy), Data("1".utf8))
        XCTAssertEqual(try JSONEncoder().encode(TutorialPlanVersion.boardDriven), Data("2".utf8))
        XCTAssertEqual(try JSONEncoder().encode(TutorialPlanVersion.playAlong), Data("3".utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(TutorialPlanVersion.self, from: Data("4".utf8)))
        for catalog in ["levels-legacy-v3", "levels-legacy-v2", "levels"] {
            let puzzle = try firstPuzzle(catalog: catalog)
            XCTAssertEqual(PuzzleHints.tutorial(puzzle: puzzle), PuzzleHints.tutorial(puzzle: puzzle, version: .playAlong))
            for version in [TutorialPlanVersion.legacy, .boardDriven, .playAlong] {
                let expected = PuzzleHints.tutorial(puzzle: puzzle, version: version)
                var changed = puzzle
                changed.solution = []
                changed.seed = puzzle.seed ^ UInt64.max
                XCTAssertEqual(PuzzleHints.tutorial(puzzle: changed, version: version), expected)
                changed.solution = [0, 5, 10, 15] // An invalid stored answer must not influence teaching.
                XCTAssertEqual(PuzzleHints.tutorial(puzzle: changed, version: version), expected)
            }
        }
    }

    private func followEveryStep(_ puzzle: Puzzle, version: TutorialPlanVersion) throws {
        var game = GameSession(puzzle: puzzle)
        for step in PuzzleHints.tutorial(puzzle: puzzle, version: version) {
            switch step.action {
            case "read": break
            case "tap":
                let cell = try XCTUnwrap(step.targetCells.first)
                XCTAssertEqual(game.marks.contains(cell), step.id == "undo")
                XCTAssertTrue(game.toggleMark(at: cell))
            case "swipe":
                XCTAssertTrue(game.marks.isDisjoint(with: step.targetCells))
                for cell in step.targetCells { XCTAssertEqual(game.markMany([cell]), 1) }
                XCTAssertTrue(Set(step.targetCells).isSubset(of: game.marks))
            case "doubleTap":
                let cell = try XCTUnwrap(step.targetCells.first)
                XCTAssertEqual(game.submit(cell: cell), .correct(cell: cell, points: game.config.baseScore, won: false))
            default: XCTFail("Unknown teaching action")
            }
            XCTAssertEqual(game.lives, game.config.initialLives)
            XCTAssertTrue(game.errors.isEmpty)
            XCTAssertTrue(game.marks.isDisjoint(with: puzzle.solution))
        }
        XCTAssertEqual(game.found.count, 1)
        XCTAssertEqual(game.status, .playing)
        XCTAssertEqual(game.score, game.config.baseScore)
    }
}
