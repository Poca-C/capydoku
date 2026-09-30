import XCTest
import CapydokuCore
@testable import Capydoku

private final class RestartIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}

final class RestartNavigationTests: XCTestCase {
    private func directory() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }

    @MainActor private func model(at directory: URL, identity: RestartIdentity = RestartIdentity()) -> AppModel {
        let app = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false,
                           analyticsIdentityStore: identity)
        app.consentAccepted()
        app.progress.tutorialCompleted = true
        return app
    }

    @MainActor private func events(_ name: String, in app: AppModel) -> [AnalyticsRecorder.Event] {
        app.analytics.events.filter { $0.eventName == name }
    }

    @MainActor func testHomeSettingsRestartOpensResetPlayableBoardAndRecordsOneNewAttempt() throws {
        let root = directory(), identity = RestartIdentity()
        let app = model(at: root, identity: identity)
        app.start(level: 2)
        let puzzle = try XCTUnwrap(app.session?.puzzle)
        let wrong = try XCTUnwrap(puzzle.regions.indices.first { !puzzle.solution.contains($0) })
        app.submit(wrong)
        app.submit(try XCTUnwrap(puzzle.solution.first))
        app.home()
        let old = try XCTUnwrap(app.session)
        XCTAssertEqual(app.screen, .home)
        XCTAssertGreaterThan(old.score, 0)
        XCTAssertLessThan(old.lives, old.config.initialLives)
        let inventory = (app.progress.availableHints, app.progress.availableDirect)
        let starts = events("level_start", in: app).count

        // The real Settings button closes its sheet before calling restart.
        app.sheet = .settings
        app.sheet = nil
        app.restart()

        let restarted = try XCTUnwrap(app.session)
        XCTAssertEqual(app.screen, .game, "Home Settings must open the restarted board before its level_start.")
        XCTAssertNil(app.sheet)
        XCTAssertEqual(restarted.puzzle, old.puzzle)
        XCTAssertNotEqual(restarted.id, old.id)
        XCTAssertEqual(restarted.attempt, old.attempt + 1)
        XCTAssertEqual(restarted.status, .playing)
        XCTAssertEqual(restarted.found, [])
        XCTAssertEqual(restarted.marks, [])
        XCTAssertEqual(restarted.errors, [])
        XCTAssertEqual(restarted.lives, old.config.initialLives)
        XCTAssertEqual(restarted.score, 0)
        XCTAssertEqual(app.progress.availableHints, inventory.0)
        XCTAssertEqual(app.progress.availableDirect, inventory.1)
        XCTAssertEqual(events("level_start", in: app).count, starts + 1)
        XCTAssertEqual(events("level_start", in: app).last?.parameters["attempt_no"], .integer(old.attempt + 1))
        XCTAssertEqual(events("level_restart", in: app).map { $0.parameters["restart_reason"] }, [.text("manual")])

        app.restart() // A rapid repeated delivery must not reset or record twice.
        XCTAssertEqual(app.session, restarted)
        XCTAssertEqual(events("level_start", in: app).count, starts + 1)
        XCTAssertEqual(events("level_restart", in: app).count, 1)
        app.toggle(wrong)
        XCTAssertTrue(app.session?.marks.contains(wrong) == true, "Exercise the actual input gate, not just screen state.")
        let cold = model(at: root, identity: identity)
        cold.startOrContinue()
        XCTAssertEqual(cold.session, app.session)
        XCTAssertEqual(events("level_start", in: cold).count, starts + 1)
    }

    @MainActor func testFailureRestartStillResetsCurrentLevelAndAcceptsInput() throws {
        let app = model(at: directory())
        app.start(level: 2)
        let old = try XCTUnwrap(app.session)
        let wrong = old.puzzle.regions.indices.filter { !old.puzzle.solution.contains($0) }
        for cell in wrong.prefix(old.config.initialLives) { app.submit(cell) }
        XCTAssertEqual(app.session?.status, .lost)
        app.restart()
        XCTAssertEqual(app.screen, .game)
        XCTAssertEqual(app.session?.status, .playing)
        XCTAssertEqual(app.session?.puzzle, old.puzzle)
        XCTAssertEqual(app.session?.lives, old.config.initialLives)
        XCTAssertEqual(app.session?.attempt, old.attempt + 1)
        XCTAssertEqual(events("level_restart", in: app).last?.parameters["restart_reason"], .text("after_fail"))
        XCTAssertEqual(events("level_start", in: app).count, 2)
        app.toggle(try XCTUnwrap(wrong.first))
        XCTAssertEqual(app.session?.marks.count, 1)
    }

    @MainActor func testUnsupportedAlternateBoardDoesNotLeaveHomeOrPublishNewAttempt() throws {
        let app = model(at: directory())
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
        var row = try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: fixture))
        row.failure.restartCreatesNewBoard = true
        app.config = DemoConfig(referenceGameplay: row)
        app.start(level: 1)
        app.home()
        let old = app.progress
        let eventCount = app.analytics.events.count
        app.sheet = .settings
        app.sheet = nil
        app.restart()
        XCTAssertEqual(app.screen, .home)
        XCTAssertEqual(app.progress, old)
        XCTAssertEqual(app.analytics.events.count, eventCount)
        XCTAssertNotNil(app.errorMessage)
    }
}
