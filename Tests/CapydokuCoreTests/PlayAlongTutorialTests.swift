import XCTest
@testable import CapydokuCore

final class PlayAlongTutorialTests: XCTestCase {
    private func puzzle(_ catalog: String) throws -> Puzzle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(JSONDecoder().decode([Puzzle].self,
            from: Data(contentsOf: root.appendingPathComponent("Resources/\(catalog).json"))).first { $0.id == 1 })
    }

    private func play(_ p: Puzzle) throws {
        let steps = PuzzleHints.tutorial(puzzle: p, version: .playAlong)
        XCTAssertTrue(PuzzleHints.canTeach(puzzle: p))
        XCTAssertTrue(PlayAlongTutorial.isValid(puzzle: p, steps: steps))
        XCTAssertEqual(steps.first?.action, "doubleTap")
        XCTAssertEqual(steps.last?.action, "finish")
        XCTAssertFalse(steps.contains { $0.action == "read" }, "New players act before being asked to read rule pages.")
        XCTAssertEqual(steps.prefix(5).map(\.action), ["doubleTap", "tap", "tap", "swipe", "swipe"])
        XCTAssertEqual(steps.filter { $0.action == "doubleTap" || $0.action == "finish" }.count, 4)
        XCTAssertTrue(steps.contains { $0.id.hasPrefix("exclude_neighbors_") })
        let firstAnimal = try XCTUnwrap(steps.first?.targetCells.first)
        XCTAssertEqual(p.regions.filter { $0 == p.regions[firstAnimal] }.count, 1)
        let horizontal = try XCTUnwrap(steps.first { $0.id == "swipe" })
        let vertical = try XCTUnwrap(steps.first { $0.id == "swipeVertical" })
        XCTAssertTrue(horizontal.targetCells.allSatisfy { $0 / p.size == firstAnimal / p.size })
        XCTAssertTrue(vertical.targetCells.allSatisfy { $0 % p.size == firstAnimal % p.size })

        var game = GameSession(puzzle: p)
        for step in steps {
            let beforeMarks = game.marks
            XCTAssertTrue(Set(try XCTUnwrap(step.focusCells)).isSubset(of: Set(p.regions.indices)))
            switch step.action {
            case "tap": XCTAssertTrue(game.toggleMark(at: try XCTUnwrap(step.targetCells.first)))
            case "swipe", "exclude":
                for cell in step.targetCells {
                    XCTAssertEqual(game.markMany([cell]), 1, "Every exclusion is a real accepted player operation.")
                }
            case "doubleTap", "finish":
                let target = try XCTUnwrap(step.targetCells.first)
                guard case .correct(let actual, _, let won) = game.submit(cell: target) else {
                    XCTFail("A proved tutorial placement must be correct."); return
                }
                XCTAssertEqual(actual, target)
                XCTAssertEqual(won, step.action == "finish")
                XCTAssertEqual(game.marks, beforeMarks, "Finding an animal never auto-marks its conflicts.")
                if step.action == "finish" {
                    XCTAssertEqual(step.focusCells, Array(p.regions.indices), "The final question leaves the entire board available for independent discovery.")
                }
            default: XCTFail("Unexpected action \(step.action)")
            }
            XCTAssertEqual(game.lives, game.config.initialLives)
            XCTAssertTrue(game.errors.isEmpty)
            XCTAssertTrue(game.marks.isDisjoint(with: p.solution))
        }
        XCTAssertEqual(game.status, .won)
        XCTAssertEqual(game.found, Set(p.solution))
    }

    func testCurrentAndBothArchivedBoardsTeachEveryOperationThroughACompleteWin() throws {
        for catalog in ["levels", "levels-legacy-v3", "levels-legacy-v2"] { try play(puzzle(catalog)) }
    }

    func testSmallGeneratedSeedSampleHasSafeCompletePlansWithoutReplacingThePack() throws {
        for seed in [UInt64(7), 31, 222, 987] {
            try play(PuzzleGenerator.generate(level: 1, seed: seed))
        }
    }

    func testPlanIgnoresStoredAnswersAndSeedsAndRetainsOlderVersions() throws {
        for catalog in ["levels", "levels-legacy-v3", "levels-legacy-v2"] {
            let original = try puzzle(catalog)
            for version in [TutorialPlanVersion.legacy, .boardDriven, .playAlong] {
                let expected = PuzzleHints.tutorial(puzzle: original, version: version)
                var changed = original
                changed.solution = []; changed.seed = original.seed ^ UInt64.max
                XCTAssertEqual(PuzzleHints.tutorial(puzzle: changed, version: version), expected)
                changed.solution = [0, 5, 10, 15]
                XCTAssertEqual(PuzzleHints.tutorial(puzzle: changed, version: version), expected)
                if version != .playAlong {
                    XCTAssertEqual(expected.count, 9)
                    XCTAssertEqual(expected.prefix(4).map(\.action), ["read", "read", "read", "read"])
                    XCTAssertTrue(expected.allSatisfy { $0.focusCells == nil })
                }
            }
        }
    }

    func testEligibilityRejectsAPlanThatMarksAnAnimalOrSkipsTheTouchingLesson() throws {
        let p = try puzzle("levels")
        let original = PuzzleHints.tutorial(puzzle: p)
        var changed = original
        let index = try XCTUnwrap(changed.firstIndex { $0.id == "mark" })
        let step = changed[index]
        changed[index] = TutorialStep(id: step.id, title: step.title, instruction: step.instruction,
            targetCells: [try XCTUnwrap(original.first?.targetCells.first)], action: "tap", focusCells: step.focusCells)
        XCTAssertFalse(PlayAlongTutorial.isValid(puzzle: p, steps: changed))
        XCTAssertFalse(PlayAlongTutorial.isValid(puzzle: p,
            steps: original.filter { !$0.id.hasPrefix("exclude_neighbors_") }))
    }

    func testFocusContextRoundTripsAndOldStepsDecodeWithoutIt() throws {
        let old = Data(#"{"id":"mark","title":"Tap","instruction":"Mark X","targetCells":[0],"action":"tap"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TutorialStep.self, from: old).focusCells)
        let steps = PuzzleHints.tutorial(puzzle: try puzzle("levels"))
        XCTAssertEqual(try JSONDecoder().decode([TutorialStep].self, from: JSONEncoder().encode(steps)), steps)
    }
}
