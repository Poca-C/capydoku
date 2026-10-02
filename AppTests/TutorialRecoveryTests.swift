import XCTest
import CapydokuCore
@testable import Capydoku

/// Exercise real actions and cold restoration, including partial exclusions.
final class TutorialRecoveryTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tutorial-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor private func model(at directory: URL, puzzle: Puzzle? = nil) -> AppModel {
        AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false, bundledPuzzles: puzzle.map { [$0] })
    }
    @MainActor private func restore(_ previous: AppModel, at directory: URL) throws -> AppModel {
        let session = try XCTUnwrap(previous.session)
        let restored = model(at: directory, puzzle: session.puzzle)
        XCTAssertNil(restored.errorMessage); XCTAssertNil(restored.notice)
        restored.startOrContinue()
        XCTAssertEqual(restored.progress, previous.progress)
        XCTAssertEqual(restored.session, session)
        XCTAssertEqual(restored.tutorial, previous.tutorial)
        XCTAssertEqual(restored.tutorialHintRevealed, previous.tutorialHintRevealed)
        XCTAssertEqual(restored.showsTutorialCompletion, previous.showsTutorialCompletion)
        return restored
    }
    @MainActor private func act(_ app: AppModel, step: TutorialStep) throws {
        switch step.action {
        case "tap": app.toggle(try XCTUnwrap(step.targetCells.first))
        case "swipe", "exclude": app.mark(step.targetCells)
        case "doubleTap", "finish": app.submit(try XCTUnwrap(step.targetCells.first))
        default: XCTFail("The new lesson must use actual board actions, not reading pages: \(step.action)")
        }
    }
    @MainActor private func completeTutorial(_ initial: AppModel, at directory: URL) throws {
        var app = initial
        let original = try XCTUnwrap(app.session)
        let steps = PuzzleHints.tutorial(puzzle: original.puzzle, version: .playAlong)
        XCTAssertEqual(steps.first?.action, "doubleTap")
        XCTAssertEqual(steps.last?.action, "finish")
        XCTAssertFalse(steps.contains { $0.action == "read" })
        for index in steps.indices {
            app = try restore(app, at: directory)
            let step = try XCTUnwrap(app.tutorial), before = try XCTUnwrap(app.session)
            XCTAssertEqual(step, steps[index]); XCTAssertEqual(app.progress.tutorialStep, index)
            app.advanceTutorial()
            XCTAssertEqual(app.progress.tutorialStep, index, "A read-button callback cannot skip an action.")
            if step.action != "finish" {
                let outside = try XCTUnwrap(original.puzzle.regions.indices.first { !step.targetCells.contains($0) })
                app.submit(outside)
                XCTAssertEqual(app.session, before)
            }
            if ["swipe", "exclude"].contains(step.action), step.targetCells.count > 1 {
                app.mark([step.targetCells[0]])
                XCTAssertEqual(app.progress.tutorialStep, index)
                app = try restore(app, at: directory)
                app.mark(Array(step.targetCells.dropFirst()))
            } else {
                try act(app, step: step)
            }
            XCTAssertEqual(app.progress.tutorialStep, index + 1)
            XCTAssertEqual(app.session?.lives, original.lives)
            XCTAssertEqual(app.session?.errors, [])
            if ["doubleTap", "finish"].contains(step.action) {
                XCTAssertEqual(app.session?.marks, before.marks, "Finding an animal must never auto-exclude cells.")
                XCTAssertEqual(app.session?.found, before.found.union(step.targetCells))
            }
            XCTAssertNil(app.errorMessage)
        }
        XCTAssertTrue(app.progress.tutorialCompleted)
        XCTAssertTrue(app.showsTutorialCompletion)
        XCTAssertEqual(app.session?.status, .won)
        XCTAssertEqual(app.session?.found, Set(original.puzzle.solution))
        XCTAssertTrue(app.progress.completedLevels.contains(1))
        XCTAssertEqual(app.progress.unlockedLevel, 2)
        app = try restore(app, at: directory)
        XCTAssertNil(app.tutorial)
        XCTAssertTrue(app.showsTutorialCompletion, "The final action and teaching completion must be saved together.")
        let completed = app.progress
        app.submit(original.puzzle.solution.last!)
        XCTAssertEqual(app.progress, completed, "Duplicate final callbacks cannot award again.")
    }

    @MainActor func testEveryPackagedTutorialStepRestoresAndCanContinue() throws {
        let dir = directory(), app = model(at: dir)
        app.start(level: 1)
        XCTAssertEqual(app.progress.tutorialPlanVersion, .playAlong)
        try completeTutorial(app, at: dir)
    }

    @MainActor func testRestartDuringUndoOrPartialSwipeReplaysTheCompleteTutorial() throws {
        for checkpoint in ["undo", "swipeVertical"] {
            let dir = directory()
            var app = model(at: dir)
            app.start(level: 1)
            for _ in 0..<app.tutorialCount {
                guard let step = app.tutorial, step.id != checkpoint else { break }
                try act(app, step: step)
            }
            XCTAssertEqual(app.tutorial?.id, checkpoint)
            if checkpoint == "swipeVertical" { app.mark([try XCTUnwrap(app.tutorial?.targetCells.first)]) }
            let previous = try XCTUnwrap(app.session)
            app.home(); app.startOrContinue()
            XCTAssertEqual(app.session?.marks, previous.marks)
            XCTAssertEqual(app.session?.found, previous.found)
            app = try restore(app, at: dir)
            app.restart()
            XCTAssertNotEqual(app.session?.id, previous.id)
            XCTAssertEqual(app.session?.attempt, previous.attempt + 1)
            XCTAssertEqual(app.tutorial?.id, "find_1")
            XCTAssertEqual(app.session?.marks, []); XCTAssertEqual(app.session?.found, [])
            try completeTutorial(app, at: dir)
            let completed = model(at: dir); completed.startOrContinue(); completed.restart()
            XCTAssertNil(completed.tutorial)
            XCTAssertFalse(completed.showsTutorialCompletion)
        }
    }

    @MainActor func testGeneratedTutorialTargetsWorkAcrossEightSeedsAndEverySavedStep() throws {
        var fingerprints = Set<String>()
        for seed: UInt64 in [1, 7, 42, 123, 991, 2_026, 9_001, 0xCA9D0C0] {
            let dir = directory()
            let puzzle = try PuzzleGenerator.generate(level: 1, seed: seed, timeBudgetMilliseconds: 8_000)
            XCTAssertTrue(PuzzleSolver.validate(puzzle).valid)
            fingerprints.insert(puzzle.fingerprint)
            let app = model(at: dir, puzzle: puzzle)
            app.start(level: 1)
            try completeTutorial(app, at: dir)
        }
        XCTAssertGreaterThan(fingerprints.count, 1)
    }

    @MainActor func testFinalFreePlayAndOptionalHintPersistWithoutSpendingInventory() throws {
        let dir = directory()
        var app = model(at: dir); app.start(level: 1)
        for _ in 0..<app.tutorialCount {
            guard let step = app.tutorial, step.action != "finish" else { break }
            try act(app, step: step)
        }
        let step = try XCTUnwrap(app.tutorial), before = try XCTUnwrap(app.session)
        XCTAssertEqual(step.action, "finish"); XCTAssertFalse(app.tutorialHintRevealed)
        let other = try XCTUnwrap(before.puzzle.regions.indices.first { !before.found.contains($0) && !step.targetCells.contains($0) })
        app.toggle(other)
        XCTAssertNotEqual(app.session?.marks, before.marks, "Final free play must allow other cells.")
        app.toggle(other)
        app.submit(other)
        XCTAssertEqual(app.session?.lives, before.lives - 1, "An ordinary wrong guess is not silently target-gated.")
        XCTAssertEqual(app.tutorial, step)
        let inventory = app.progress.availableHints
        let unchangedBoard = app.session
        app.revealTutorialHint(); app.revealTutorialHint()
        XCTAssertTrue(app.tutorialHintRevealed)
        XCTAssertEqual(app.progress.availableHints, inventory)
        XCTAssertEqual(app.session, unchangedBoard)
        app = try restore(app, at: dir)
        XCTAssertTrue(app.tutorialHintRevealed)
        app.submit(try XCTUnwrap(step.targetCells.first))
        XCTAssertTrue(app.showsTutorialCompletion)
    }

    @MainActor func testOneHeldSwipeCannotApplyToTheFollowingTeachingStep() throws {
        let dir = directory(), app = model(at: dir); app.start(level: 1)
        for _ in 0..<app.tutorialCount {
            guard let step = app.tutorial, step.id != "swipe" else { break }
            try act(app, step: step)
        }
        let horizontal = try XCTUnwrap(app.tutorial)
        app.beginSwipeFeedback(); app.mark(horizontal.targetCells)
        XCTAssertEqual(app.tutorial?.id, "swipeVertical")
        let vertical = try XCTUnwrap(app.tutorial), marks = app.session?.marks
        app.mark(vertical.targetCells)
        XCTAssertEqual(app.session?.marks, marks)
        XCTAssertEqual(app.tutorial, vertical)
        app.endSwipeFeedback(cancelled: false)
        app.beginSwipeFeedback(); app.mark(vertical.targetCells); app.endSwipeFeedback(cancelled: false)
        XCTAssertNotEqual(app.tutorial, vertical)
    }
}
