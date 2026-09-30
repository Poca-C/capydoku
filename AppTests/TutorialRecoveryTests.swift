import XCTest
import CapydokuCore
@testable import Capydoku

/// Exercises the saved onboarding as actual player actions, including a fresh model
/// before every step and halfway through each swipe. No launch flags inject progress.
final class TutorialRecoveryTests: XCTestCase {
    @MainActor private func model(at directory: URL) -> AppModel {
        AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tutorial-\(UUID().uuidString)")
    }

    @MainActor private func restore(_ previous: AppModel, at directory: URL) throws -> AppModel {
        let session = try XCTUnwrap(previous.session)
        let step = previous.progress.tutorialStep
        let completed = previous.progress.tutorialCompleted
        let restored = model(at: directory)
        XCTAssertNil(restored.errorMessage)
        XCTAssertNil(restored.notice, "A normal teaching checkpoint must load without backup recovery.")
        restored.startOrContinue()
        XCTAssertEqual(restored.progress.tutorialStep, step)
        XCTAssertEqual(restored.progress.tutorialCompleted, completed)
        XCTAssertEqual(restored.session, session, "Restoration must preserve the board, marks, found cells, score, lives and attempt.")
        XCTAssertEqual(restored.screen, .game)
        return restored
    }

    private func validateTargets(_ step: TutorialStep, puzzle: Puzzle, animal: Int) throws {
        let targets = Set(step.targetCells)
        XCTAssertFalse(targets.isEmpty, "Every teaching action needs targets on this board.")
        XCTAssertEqual(targets.count, step.targetCells.count)
        XCTAssertTrue(targets.isSubset(of: Set(puzzle.regions.indices)))
        switch step.id {
        case "row":
            XCTAssertEqual(targets.count, puzzle.size)
            XCTAssertTrue(targets.allSatisfy { $0 / puzzle.size == animal / puzzle.size })
        case "column":
            XCTAssertEqual(targets.count, puzzle.size)
            XCTAssertTrue(targets.allSatisfy { $0 % puzzle.size == animal % puzzle.size })
        case "region":
            XCTAssertEqual(targets, Set(puzzle.regions.indices.filter { puzzle.regions[$0] == puzzle.regions[animal] }))
        case "neighbors":
            XCTAssertFalse(targets.contains(animal))
            XCTAssertTrue(targets.allSatisfy {
                abs($0 / puzzle.size - animal / puzzle.size) <= 1 && abs($0 % puzzle.size - animal % puzzle.size) <= 1
            })
        case "mark", "undo":
            XCTAssertEqual(targets.count, 1)
            XCTAssertTrue(targets.isDisjoint(with: puzzle.solution), "Teaching must never mark an actual answer as empty.")
        case "swipe", "swipeVertical":
            XCTAssertEqual(targets.count, 2)
            XCTAssertTrue(targets.isDisjoint(with: puzzle.solution))
            let ordered = step.targetCells.sorted()
            let first = try XCTUnwrap(ordered.first), last = try XCTUnwrap(ordered.last)
            if step.id == "swipe" {
                XCTAssertEqual(first / puzzle.size, last / puzzle.size)
                XCTAssertEqual(last - first, 1)
            } else {
                XCTAssertEqual(first % puzzle.size, last % puzzle.size)
                XCTAssertEqual(last - first, puzzle.size)
            }
        case "find":
            XCTAssertEqual(targets, [animal])
            XCTAssertTrue(puzzle.solution.contains(animal))
            XCTAssertEqual(puzzle.regions.filter { $0 == puzzle.regions[animal] }.count, 1,
                           "The final instruction's single-cell-region explanation must be true.")
        default:
            XCTFail("Unexpected tutorial step \(step.id)")
        }
    }

    @MainActor private func completeTutorial(_ initial: AppModel, at directory: URL) throws {
        var app = initial
        let original = try XCTUnwrap(app.session)
        let puzzle = original.puzzle
        let allSteps = PuzzleHints.tutorial(puzzle: puzzle)
        XCTAssertEqual(allSteps.count, 9)
        let animal = try XCTUnwrap(allSteps.last?.targetCells.first)
        for index in 0..<9 {
            // Recreate from disk before EVERY step, rather than just inspect saved fields.
            app = try restore(app, at: directory)
            XCTAssertEqual(app.progress.tutorialStep, index)
            let step = try XCTUnwrap(app.tutorial)
            try validateTargets(step, puzzle: puzzle, animal: animal)
            let before = try XCTUnwrap(app.session)

            // Guesses outside this instruction's highlighted targets must be ignored.
            let outside = try XCTUnwrap(puzzle.regions.indices.first { !step.targetCells.contains($0) })
            app.submit(outside)
            XCTAssertEqual(app.session, before)
            XCTAssertEqual(app.progress.tutorialStep, index)

            switch step.action {
            case "read":
                app.advanceTutorial()
                XCTAssertEqual(app.session, before)
            case "tap":
                let cell = try XCTUnwrap(step.targetCells.first)
                app.toggle(cell)
                XCTAssertEqual(app.session?.marks, before.marks.symmetricDifference([cell]))
                XCTAssertEqual(app.session?.score, before.score)
            case "swipe":
                let first = try XCTUnwrap(step.targetCells.first)
                app.mark([first])
                XCTAssertEqual(app.progress.tutorialStep, index, "A partial swipe must not finish the two-cell instruction.")
                XCTAssertTrue(app.session?.marks.contains(first) == true)
                app = try restore(app, at: directory)
                XCTAssertEqual(app.tutorial?.id, step.id)
                app.mark(Array(step.targetCells.dropFirst()))
                XCTAssertEqual(app.session?.marks, before.marks.union(step.targetCells))
                XCTAssertEqual(app.session?.score, before.score)
            case "doubleTap":
                let target = try XCTUnwrap(step.targetCells.first)
                app.submit(target)
                XCTAssertEqual(app.session?.found, before.found.union([target]))
                XCTAssertGreaterThan(try XCTUnwrap(app.session?.score), before.score)
            default:
                XCTFail("Unknown tutorial action \(step.action)")
            }

            XCTAssertNil(app.errorMessage)
            XCTAssertEqual(app.progress.tutorialStep, index + 1, "The requested operation should advance exactly one step.")
            XCTAssertEqual(app.session?.lives, original.lives, "Following the generated teaching targets must never cost a life.")
            XCTAssertEqual(app.session?.errors, [])
            XCTAssertTrue(try XCTUnwrap(app.session?.marks).isDisjoint(with: puzzle.solution))
        }
        XCTAssertTrue(app.progress.tutorialCompleted)
        XCTAssertNil(app.tutorial)
        XCTAssertEqual(app.session?.found, [animal])
        XCTAssertEqual(app.session?.score, original.config.baseScore)
        app = try restore(app, at: directory)
        XCTAssertTrue(app.progress.tutorialCompleted)
        XCTAssertNil(app.tutorial, "A completed introduction must not start again after relaunch.")
        XCTAssertEqual(app.session?.found, [animal])
        XCTAssertEqual(app.session?.lives, original.lives)
        // The player can keep playing the same puzzle after the restored tutorial.
        let next = try XCTUnwrap(puzzle.solution.first { $0 != animal })
        app.submit(next)
        XCTAssertEqual(app.session?.found, [animal, next])
        XCTAssertNil(app.tutorial)
        XCTAssertEqual(app.session?.lives, original.lives)
    }

    @MainActor func testEveryPackagedTutorialStepRestoresAndCanContinue() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = model(at: dir)
        app.start(level: 1)
        XCTAssertEqual(app.session?.puzzle.id, 1)
        try completeTutorial(app, at: dir)
    }

    @MainActor func testGeneratedTutorialTargetsWorkAcrossEightSeedsAndEverySavedStep() throws {
        let seeds: [UInt64] = [1, 7, 42, 123, 991, 2_026, 9_001, 0xCA9D0C0]
        var fingerprints = Set<String>()
        for seed in seeds {
            let dir = directory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let puzzle = try PuzzleGenerator.generate(level: 1, seed: seed, timeBudgetMilliseconds: 8_000)
            XCTAssertTrue(PuzzleSolver.validate(puzzle).valid)
            fingerprints.insert(puzzle.fingerprint)
            let app = model(at: dir)
            app.progress.begin(puzzle: puzzle, config: app.config)
            app.save()
            app.startOrContinue() // Preserve this generated board instead of loading the bundled Level 1.
            XCTAssertEqual(app.session?.puzzle.seed, seed)
            try completeTutorial(app, at: dir)
        }
        XCTAssertGreaterThan(fingerprints.count, 1, "The generated-board test must exercise more than one region layout.")
    }
}
