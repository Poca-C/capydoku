import XCTest
import CryptoKit
import CapydokuCore
@testable import Capydoku

/// Schema 3 saves shipped before tutorial plan versioning. These tests remove
/// the new field from a real SaveStore payload and recompute its envelope hash;
/// setting an in-memory .legacy value is not used to simulate migration.
final class TutorialPlanMigrationTests: XCTestCase {
    private let legacyIDs = ["row", "column", "region", "neighbors", "mark", "undo", "swipe", "swipeVertical", "find"]
    private let legacyTargets = [[8, 9, 10, 11], [0, 4, 8, 12], [8], [4, 5, 9, 12, 13], [0], [0], [4, 5], [9, 13], [8]]
    private let legacyActions = ["read", "read", "read", "read", "tap", "tap", "swipe", "swipe", "doubleTap"]

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tutorial-migration-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor private func model(at directory: URL) -> AppModel {
        AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor private func reloadWithoutVersion(_ previous: AppModel, at directory: URL) throws -> AppModel {
        previous.save(force: true)
        XCTAssertNil(previous.errorMessage)
        let path = directory.appendingPathComponent("progress.json")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(envelope["schemaVersion"] as? Int, SaveStore.currentSchemaVersion)
        let savedPayload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        XCTAssertEqual(envelope["checksum"] as? String, digest(savedPayload))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: savedPayload) as? [String: Any])
        XCTAssertNotNil(payload.removeValue(forKey: "tutorialPlanVersion"))
        let historicalPayload = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        envelope["schemaVersion"] = 3
        envelope["payload"] = historicalPayload.base64EncodedString()
        envelope["checksum"] = digest(historicalPayload)
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: path, options: .atomic)

        let restored = model(at: directory)
        XCTAssertNil(restored.notice, "The valid primary schema 3 save must load without falling back to a new backup.")
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.progress.tutorialPlanVersion, .legacy)
        // Only the expected value changes version; the actual loaded object above
        // must have obtained .legacy by decoding the genuinely absent field.
        var expected = previous.progress
        expected.tutorialPlanVersion = .legacy
        XCTAssertEqual(restored.progress, expected, "Version migration cannot change any gameplay or inventory field.")
        restored.startOrContinue()
        XCTAssertEqual(restored.session, previous.session)
        return restored
    }

    @MainActor private func legacyModel(at directory: URL) throws -> AppModel {
        let archiveURL = try XCTUnwrap(Bundle.main.url(forResource: "levels-legacy-v3", withExtension: "json"))
        let historicalPuzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: archiveURL))
        // Create the historical save with its actual shipped board. Cold reloads
        // still use the normal current AppModel, exercising the upgrade boundary.
        let fresh = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false,
                             bundledPuzzles: historicalPuzzles)
        fresh.start(level: 1)
        XCTAssertEqual(fresh.progress.tutorialPlanVersion, .current)
        XCTAssertEqual(fresh.session?.puzzle.size, 4)
        XCTAssertEqual(fresh.session?.puzzle.generatorVersion, "original-pipeline-v3")
        XCTAssertEqual(fresh.session?.puzzle.solution, [1, 7, 8, 14], "Frozen historical coordinates refer to the shipped L1.")
        return try reloadWithoutVersion(fresh, at: directory)
    }

    @MainActor private func performStep(_ app: AppModel) throws {
        let step = try XCTUnwrap(app.tutorial), index = app.progress.tutorialStep
        switch step.action {
        case "read": app.advanceTutorial()
        case "tap": app.toggle(try XCTUnwrap(step.targetCells.first))
        case "swipe": app.mark(step.targetCells)
        case "doubleTap": app.submit(try XCTUnwrap(step.targetCells.first))
        default: XCTFail("Unknown action \(step.action)")
        }
        XCTAssertEqual(app.progress.tutorialStep, index + 1)
        XCTAssertNil(app.errorMessage)
    }

    @MainActor func testEveryHistoricalStepKeepsFrozenIdentityAndCoordinatesIncludingUndoAndPartialSwipes() throws {
        let root = directory()
        var app = try legacyModel(at: root)
        let original = try XCTUnwrap(app.session)
        for index in legacyIDs.indices {
            app = try reloadWithoutVersion(app, at: root)
            XCTAssertEqual(app.progress.tutorialStep, index)
            let step = try XCTUnwrap(app.tutorial)
            XCTAssertEqual(step.id, legacyIDs[index])
            XCTAssertEqual(step.targetCells, legacyTargets[index])
            XCTAssertEqual(step.action, legacyActions[index])
            XCTAssertEqual(app.tutorialCount, 9)
            XCTAssertEqual(app.session?.id, original.id)
            XCTAssertEqual(app.session?.puzzle, original.puzzle)
            let before = try XCTUnwrap(app.session)
            let outside = try XCTUnwrap(original.puzzle.regions.indices.first { !step.targetCells.contains($0) })
            app.submit(outside)
            XCTAssertEqual(app.session, before, "Migration must not admit an old instruction's out-of-target guess.")

            if step.action == "swipe" {
                let first = try XCTUnwrap(step.targetCells.first)
                app.mark([first])
                XCTAssertEqual(app.progress.tutorialStep, index)
                XCTAssertEqual(app.session?.marks, before.marks.union([first]))
                let partial = try XCTUnwrap(app.session)
                app = try reloadWithoutVersion(app, at: root)
                XCTAssertEqual(app.session, partial)
                XCTAssertEqual(app.tutorial, step)
                app.mark(Array(step.targetCells.dropFirst()))
                XCTAssertEqual(app.session?.marks, before.marks.union(step.targetCells))
            } else {
                if step.id == "undo" { XCTAssertTrue(before.marks.contains(0)) }
                try performStep(app)
                if step.id == "mark" { XCTAssertTrue(app.session?.marks.contains(0) == true) }
                if step.id == "undo" { XCTAssertFalse(app.session?.marks.contains(0) == true) }
            }
            XCTAssertEqual(app.progress.tutorialStep, index + 1)
            XCTAssertEqual(app.progress.tutorialPlanVersion, .legacy)
            XCTAssertEqual(app.session?.lives, original.lives)
            XCTAssertEqual(app.session?.errors, [])
        }
        XCTAssertTrue(app.progress.tutorialCompleted)
        XCTAssertEqual(app.session?.found, [8])
        XCTAssertEqual(app.session?.marks, [4, 5, 9, 13])
        XCTAssertEqual(app.session?.score, original.config.baseScore)
        app = try reloadWithoutVersion(app, at: root)
        XCTAssertNil(app.tutorial)
        XCTAssertTrue(app.progress.tutorialCompleted)
        XCTAssertEqual(app.progress.tutorialPlanVersion, .legacy)
        app.submit(1)
        XCTAssertEqual(app.session?.found, [1, 8], "Completing the legacy tutorial continues ordinary play on the same attempt.")
    }

    @MainActor func testLegacyContinuePreservesUndoAndPartialSwipesButRestartSelectsCurrentPlan() throws {
        for checkpointID in ["undo", "swipe", "swipeVertical"] {
            let root = directory()
            var app = try legacyModel(at: root)
            while app.tutorial?.id != checkpointID { try performStep(app) }
            let step = try XCTUnwrap(app.tutorial)
            if step.action == "swipe" { app.mark([try XCTUnwrap(step.targetCells.first)]) }
            app = try reloadWithoutVersion(app, at: root)
            let checkpoint = try XCTUnwrap(app.session), index = app.progress.tutorialStep
            app.home(); app.startOrContinue()
            var continued = checkpoint
            XCTAssertNotNil(continued.claimResult(.quit)); XCTAssertTrue(continued.resumeAfterQuit())
            XCTAssertEqual(app.session, continued)
            XCTAssertEqual(app.tutorial, step)
            XCTAssertEqual(app.progress.tutorialStep, index)
            XCTAssertEqual(app.progress.tutorialPlanVersion, .legacy)
            app = try reloadWithoutVersion(app, at: root)
            let inventory = (app.progress.availableDirect, app.progress.availableHints)
            app.restart()
            XCTAssertEqual(app.progress.tutorialPlanVersion, .current)
            XCTAssertEqual(app.progress.tutorialStep, 0)
            XCTAssertFalse(app.progress.tutorialCompleted)
            XCTAssertEqual(app.tutorial?.id, "region")
            XCTAssertNotEqual(app.session?.id, checkpoint.id)
            XCTAssertEqual(app.session?.attempt, checkpoint.attempt + 1)
            XCTAssertEqual(app.session?.puzzle, checkpoint.puzzle)
            XCTAssertEqual(app.session?.marks, [])
            XCTAssertEqual(app.progress.availableDirect, inventory.0)
            XCTAssertEqual(app.progress.availableHints, inventory.1)
            let current = model(at: root); current.startOrContinue()
            XCTAssertEqual(current.progress.tutorialPlanVersion, .current)
            XCTAssertEqual(current.tutorial, app.tutorial)
        }
    }

    @MainActor func testNewLevelOneAttemptAndExplicitReplayUpgradeAnUnfinishedLegacyPlan() throws {
        for replay in [false, true] {
            let root = directory(), app = try legacyModel(at: root)
            for _ in 0..<5 { try performStep(app) }
            XCTAssertEqual(app.tutorial?.id, "undo")
            let before = try XCTUnwrap(app.session)
            if replay { app.replayTutorial() } else { app.start(level: 1) }
            XCTAssertEqual(app.progress.tutorialPlanVersion, .current)
            XCTAssertEqual(app.progress.tutorialStep, 0)
            XCTAssertFalse(app.progress.tutorialCompleted)
            XCTAssertEqual(app.tutorial?.id, "region")
            XCTAssertNotEqual(app.session?.id, before.id)
            XCTAssertEqual(app.session?.attempt, before.attempt + 1)
            XCTAssertEqual(app.session?.marks, [])
        }
    }

    @MainActor func testCompletedLegacyPlanDoesNotReopenOnColdContinueOrRestartButExplicitReplayDoes() throws {
        let root = directory()
        var app = try legacyModel(at: root)
        for _ in 0..<9 { try performStep(app) }
        app = try reloadWithoutVersion(app, at: root)
        XCTAssertTrue(app.progress.tutorialCompleted); XCTAssertNil(app.tutorial)
        app.home(); app.startOrContinue()
        XCTAssertTrue(app.progress.tutorialCompleted); XCTAssertNil(app.tutorial)
        app.restart()
        XCTAssertTrue(app.progress.tutorialCompleted); XCTAssertNil(app.tutorial)
        app.submit(1)
        XCTAssertEqual(app.session?.found, [1], "Restarting a completed introduction must allow ordinary play.")
        let restored = model(at: root); restored.startOrContinue()
        XCTAssertTrue(restored.progress.tutorialCompleted); XCTAssertNil(restored.tutorial)
        restored.replayTutorial()
        XCTAssertFalse(restored.progress.tutorialCompleted)
        XCTAssertEqual(restored.progress.tutorialPlanVersion, .current)
        XCTAssertEqual(restored.progress.tutorialStep, 0)
        XCTAssertEqual(restored.tutorial?.id, "region")
    }
}
