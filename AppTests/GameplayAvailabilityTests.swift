import XCTest
import CapydokuCore
@testable import Capydoku

private final class AvailabilityIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}

/// Model integration with real saves, queue and runtime generation. Timer ticks
/// use the production callback entry point; no simulator clock or save injection.
final class GameplayAvailabilityTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gameplay-availability-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor private func model(at directory: URL, identity: AvailabilityIdentity = AvailabilityIdentity(),
                                  ready: Bool = true, tutorialCompleted: Bool = true) -> AppModel {
        let app = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false,
                           startupBypassForTesting: false, analyticsIdentityStore: identity)
        app.consentAccepted()
        if app.session == nil { app.progress.tutorialCompleted = tutorialCompleted }
        if ready { app.startupReady() }
        return app
    }

    @MainActor private func starts(_ app: AppModel, level: Int? = nil) -> [AnalyticsRecorder.Event] {
        app.analytics.events.filter { $0.eventName == "level_start" && (level == nil || $0.levelID == level) }
    }

    private func eventData(_ events: [AnalyticsRecorder.Event]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(events)
    }

    private func drainPresentationChanges() async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    @MainActor private func assertPersistedStartsMatch(_ app: AppModel, file: StaticString = #filePath, line: UInt = #line) throws {
        struct Queue: Decodable { let events: [AnalyticsRecorder.Event] }
        let data = try Data(contentsOf: app.saveDirectory.appendingPathComponent("analytics-demo-queue.json"))
        let saved = try JSONDecoder().decode(Queue.self, from: data).events.filter { $0.eventName == "level_start" }
        XCTAssertEqual(try eventData(saved), try eventData(starts(app)), file: file, line: line)
    }

    @MainActor func testClockPausesForUnavailableGameplayWithoutChangingTutorialReadingTime() throws {
        let app = model(at: directory(), ready: false, tutorialCompleted: false)
        app.start(level: 1)
        XCTAssertEqual(app.tutorial?.action, "read")
        app.tickGameplayClock()
        XCTAssertEqual(app.session?.elapsedSeconds, 0, "Startup has not exposed the game yet.")
        app.startupReady(); app.tickGameplayClock()
        XCTAssertEqual(app.session?.elapsedSeconds, 1, "Reading the tutorial retains the previous timing semantics.")
        app.skipTutorial()

        let blockers: [(String, (AppModel) -> Void, (AppModel) -> Void)] = [
            ("loading", { $0.loading = true }, { $0.loading = false }),
            ("challenge", { $0.challengePending = true }, { $0.challengePending = false }),
            ("interstitial", { $0.interstitialBusy = true }, { $0.interstitialBusy = false }),
            ("reward", { $0.rewardBusy = true }, { $0.rewardBusy = false }),
            ("settings", { $0.sheet = .settings }, { $0.sheet = nil }),
            ("reward sheet", { $0.sheet = .reward }, { $0.sheet = nil }),
            ("notice", { $0.notice = "test notice" }, { $0.notice = nil }),
            ("error", { $0.errorMessage = "test error" }, { $0.errorMessage = nil }),
            ("background", { $0.setActive(false) }, { $0.setActive(true) })
        ]
        for (name, block, unblock) in blockers {
            let before = app.session?.elapsedSeconds
            block(app)
            for _ in 0..<3 { app.tickGameplayClock() }
            XCTAssertEqual(app.session?.elapsedSeconds, before, name)
            unblock(app); app.tickGameplayClock()
            XCTAssertEqual(app.session?.elapsedSeconds, (before ?? 0) + 1, name)
        }
        app.showHint(); XCTAssertNotNil(app.hint)
        let beforeHint = app.session?.elapsedSeconds
        app.tickGameplayClock(); XCTAssertEqual(app.session?.elapsedSeconds, beforeHint)
        XCTAssertTrue(app.closeHint()); app.tickGameplayClock()
        XCTAssertEqual(app.session?.elapsedSeconds, (beforeHint ?? 0) + 1)
        app.home()
        let onHome = app.session?.elapsedSeconds
        app.tickGameplayClock(); XCTAssertEqual(app.session?.elapsedSeconds, onHome)
    }

    @MainActor func testNoticeAndErrorRejectLateBoardAndToolActionsWithoutChangingPlayerState() throws {
        let app = model(at: directory()); app.start(level: 1)
        let puzzle = try XCTUnwrap(app.session?.puzzle)
        let right = try XCTUnwrap(puzzle.solution.first)
        let wrong = try XCTUnwrap(puzzle.regions.indices.first { !puzzle.solution.contains($0) })
        for isError in [false, true] {
            if isError { app.errorMessage = "storage is unavailable" } else { app.notice = "recovered backup" }
            let before = app.progress, events = try eventData(app.analytics.events)
            app.toggle(wrong); app.mark([wrong]); app.submit(right); app.submit(wrong)
            app.direct(); app.showHint(); app.levelStartFree()
            XCTAssertEqual(app.progress, before, "A stale board callback must not bypass the visible alert.")
            XCTAssertEqual(try eventData(app.analytics.events), events)
            XCTAssertNil(app.hint); XCTAssertNil(app.sheet)
            app.errorMessage = nil; app.notice = nil
            app.toggle(wrong)
            XCTAssertNotEqual(app.session?.marks, before.session?.marks, "Dismissing the alert restores fresh input.")
        }
    }

    @MainActor func testRuntimeGenerationFinishingInBackgroundWaitsForForegroundAndAllModalsBeforeOneStart() async throws {
        let app = model(at: directory()); app.start(level: 150)
        for cell in try XCTUnwrap(app.session?.puzzle.solution) { app.submit(cell) }
        XCTAssertEqual(app.session?.status, .won)
        app.next(); XCTAssertTrue(app.loading)
        app.setActive(false)
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while app.loading && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(app.loading); XCTAssertNil(app.errorMessage, app.errorMessage ?? "")
        let generated = try XCTUnwrap(app.session)
        XCTAssertEqual(generated.puzzle.id, 151)
        XCTAssertEqual(generated.elapsedSeconds, 0)
        XCTAssertEqual(SaveStore(directory: app.saveDirectory).load().progress.session, generated)
        XCTAssertTrue(starts(app, level: 151).isEmpty, "A background-prepared board has not been played.")
        try assertPersistedStartsMatch(app)

        app.notice = "generation completed while away"; app.setActive(true)
        XCTAssertTrue(starts(app, level: 151).isEmpty)
        app.sheet = .settings; app.notice = nil
        XCTAssertTrue(starts(app, level: 151).isEmpty)
        app.errorMessage = "test blocking error"; app.sheet = nil
        try await drainPresentationChanges()
        XCTAssertTrue(starts(app, level: 151).isEmpty)
        // Mimic a single business callback replacing an error with another
        // modal: the synchronous empty gap must not count as playable time.
        app.errorMessage = nil; app.notice = "replacement notice"
        XCTAssertTrue(starts(app, level: 151).isEmpty)
        try await drainPresentationChanges()
        XCTAssertTrue(starts(app, level: 151).isEmpty)
        let availableAt = Date()
        app.notice = nil
        try await drainPresentationChanges()
        let first = try XCTUnwrap(starts(app, level: 151).first)
        XCTAssertGreaterThanOrEqual(first.eventTime, availableAt)
        XCTAssertEqual(first.sessionID, app.analytics.events.last { $0.eventName == "session_start" }?.sessionID)
        XCTAssertEqual(first.parameters["attempt_no"], .integer(1))
        XCTAssertEqual(app.session, generated)
        app.setActive(false); app.setActive(true); app.setActive(true)
        app.sheet = .settings; app.sheet = nil; app.startOrContinue()
        try await drainPresentationChanges()
        XCTAssertEqual(try eventData(starts(app, level: 151)), try eventData([first]))
        try assertPersistedStartsMatch(app)
    }

    @MainActor func testStartupAndReplacedPendingAttemptCannotPublishAnUnplayableOrStaleStart() async throws {
        let app = model(at: directory(), ready: false)
        app.start(level: 2)
        XCTAssertTrue(starts(app).isEmpty)
        app.interstitialBusy = true; app.challengePending = true; app.loading = true
        app.startupReady()
        XCTAssertTrue(starts(app).isEmpty)
        app.loading = false; app.challengePending = false
        XCTAssertTrue(starts(app).isEmpty)
        // Starting a replacement while still blocked discards only the old
        // unpublished request, never an already recorded queue event.
        app.start(level: 3)
        XCTAssertTrue(starts(app).isEmpty)
        app.interstitialBusy = false
        try await drainPresentationChanges()
        XCTAssertEqual(starts(app).map(\.levelID), [3])
        let first = try XCTUnwrap(starts(app).first)
        app.startupReady(); app.startOrContinue(); app.notice = "test"; app.notice = nil
        try await drainPresentationChanges()
        XCTAssertEqual(try eventData(starts(app)), try eventData([first]))
        try assertPersistedStartsMatch(app)
    }

    @MainActor func testColdContinueRecordsPreviouslyUnplayedSavedAttemptInCurrentSessionOnlyOnce() async throws {
        let root = directory(), identity = AvailabilityIdentity()
        var previous: AppModel? = model(at: root, identity: identity)
        previous?.setActive(false); previous?.start(level: 2)
        let saved = try XCTUnwrap(previous?.session)
        let oldAnalyticsSession = try XCTUnwrap(previous?.analytics.events.last?.sessionID)
        XCTAssertTrue(starts(try XCTUnwrap(previous)).isEmpty)
        previous = nil

        let cold = model(at: root, identity: identity, ready: false)
        XCTAssertEqual(cold.session, saved)
        cold.startupReady()
        XCTAssertTrue(starts(cold).isEmpty, "Home must not count as playing a restored board.")
        cold.notice = "review recovered board"; cold.startOrContinue()
        XCTAssertTrue(starts(cold).isEmpty)
        cold.notice = nil
        try await drainPresentationChanges()
        let first = try XCTUnwrap(starts(cold).first)
        XCTAssertNotEqual(first.sessionID, oldAnalyticsSession)
        XCTAssertEqual(first.sessionID, cold.analytics.events.last { $0.eventName == "session_start" }?.sessionID)
        XCTAssertEqual(first.levelID, 2); XCTAssertEqual(first.parameters["attempt_no"], .integer(1))
        XCTAssertEqual(cold.session, saved)
        cold.setActive(false); cold.setActive(true); cold.startOrContinue()
        try await drainPresentationChanges()
        XCTAssertEqual(try eventData(starts(cold)), try eventData([first]))
        try assertPersistedStartsMatch(cold)
    }
}
