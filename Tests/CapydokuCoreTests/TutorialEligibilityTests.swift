import XCTest
@testable import CapydokuCore

final class TutorialEligibilityTests: XCTestCase {
    private var packagedFirstPuzzle: Puzzle {
        Puzzle(id: 1, size: 4,
               regions: [2, 0, 1, 1, 2, 1, 1, 1, 2, 3, 3, 1, 2, 3, 3, 3],
               solution: [1, 7, 8, 14], seed: 11400714819535654101,
               generatorVersion: "demo-connected-v2", difficulty: "Tutorial")
    }

    func testPackagedFirstPuzzleRemainsReproducibleAndTeachablyPlayable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent("Resources/levels.json")))
        let puzzle = try XCTUnwrap(catalog.first { $0.id == 1 })
        XCTAssertTrue(PuzzleHints.canTeach(puzzle: puzzle))
        XCTAssertEqual(try PuzzleGenerator.rebuild(puzzle), puzzle,
                       "The published candidate must rebuild exactly from its recorded metadata.")
        for version in [TutorialPlanVersion.legacy, .boardDriven] {
            var game = GameSession(puzzle: puzzle)
            let steps = PuzzleHints.tutorial(puzzle: puzzle, version: version)
            for step in steps {
                switch step.action {
                case "read": break
                case "tap": XCTAssertTrue(game.toggleMark(at: try XCTUnwrap(step.targetCells.first)))
                case "swipe":
                    XCTAssertEqual(game.markMany(step.targetCells), 2)
                    XCTAssertTrue(Set(step.targetCells).isSubset(of: game.marks))
                case "doubleTap":
                    let target = try XCTUnwrap(step.targetCells.first)
                    XCTAssertEqual(game.submit(cell: target), .correct(cell: target, points: game.config.baseScore, won: false))
                default: XCTFail("Unknown teaching action")
                }
                XCTAssertEqual(game.lives, game.config.initialLives)
                XCTAssertTrue(game.errors.isEmpty)
                XCTAssertTrue(game.marks.isDisjoint(with: puzzle.solution))
            }
            XCTAssertEqual(game.found, Set(try XCTUnwrap(steps.last).targetCells))
            XCTAssertEqual(game.score, game.config.baseScore)
        }
    }

    func testGeneratedFirstLevelsPassEligibilityAcrossSeeds() throws {
        var fingerprints = Set<String>()
        for seed in UInt64(0)..<64 {
            let puzzle = try PuzzleGenerator.generate(level: 1, seed: seed, timeBudgetMilliseconds: 8_000)
            XCTAssertTrue(PuzzleHints.canTeach(puzzle: puzzle), "Seed \(seed)")
            let steps = PuzzleHints.tutorial(puzzle: puzzle)
            XCTAssertTrue(PlayAlongTutorial.isValid(puzzle: puzzle, steps: steps))
            XCTAssertEqual(steps.first?.action, "doubleTap")
            XCTAssertEqual(steps.last?.action, "finish")
            XCTAssertEqual(steps.filter { $0.action == "swipe" }.map { $0.targetCells.count }, [2, 2])
            let animal = try XCTUnwrap(steps.first?.targetCells.first)
            XCTAssertEqual(puzzle.regions.filter { $0 == puzzle.regions[animal] }.count, 1)
            fingerprints.insert(puzzle.fingerprint)
        }
        XCTAssertGreaterThan(fingerprints.count, 1)
    }

    func testValidUniquePuzzleWithoutSingletonIsRejectedForTeaching() {
        // This connected geometry is the packaged Level 2, relabeled as Level 1.
        // It is a valid unique puzzle but cannot support the singleton explanation.
        let puzzle = Puzzle(id: 1, size: 4,
                            regions: [0, 0, 0, 0, 2, 2, 1, 1, 2, 2, 2, 3, 2, 2, 3, 3],
                            solution: [1, 7, 8, 14], seed: 4354685565149300970,
                            generatorVersion: "demo-connected-v2", difficulty: "Tutorial")
        let validation = PuzzleSolver.validate(puzzle)
        XCTAssertTrue(validation.valid)
        XCTAssertEqual(validation.solutionCount, 1)
        XCTAssertTrue((0..<4).allSatisfy { region in puzzle.regions.filter { $0 == region }.count > 1 })
        XCTAssertFalse(PuzzleHints.canTeach(puzzle: puzzle), "Rule validity must not bypass teaching eligibility.")
    }

    func testWrongLevelSizeAndMalformedBoardsAreNotTeachingEligible() throws {
        var wrongLevel = packagedFirstPuzzle
        wrongLevel.id = 2
        XCTAssertFalse(PuzzleHints.canTeach(puzzle: wrongLevel))
        wrongLevel.id = 0
        XCTAssertFalse(PuzzleHints.canTeach(puzzle: wrongLevel))
        var larger = try PuzzleGenerator.generate(level: 11, seed: 11)
        larger.id = 1
        XCTAssertTrue(PuzzleSolver.validate(larger).valid)
        XCTAssertFalse(PuzzleHints.canTeach(puzzle: larger))
        var malformed = packagedFirstPuzzle
        malformed.regions.removeLast()
        XCTAssertFalse(PuzzleHints.canTeach(puzzle: malformed))
        malformed = packagedFirstPuzzle
        malformed.solution = [1, 7, 8, 99]
        XCTAssertFalse(PuzzleHints.canTeach(puzzle: malformed))
        malformed = packagedFirstPuzzle
        malformed.regions[0] = -1
        XCTAssertFalse(PuzzleHints.canTeach(puzzle: malformed))
        malformed.size = Int.max
        XCTAssertFalse(PuzzleHints.canTeach(puzzle: malformed), "Reject invalid dimensions before indexing or multiplying them.")
    }
}
