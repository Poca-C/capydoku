import XCTest
import CapydokuCore
@testable import Capydoku

private final class MemoryIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}
final class AnalyticsRecorderTests: XCTestCase {
    @MainActor func testNoCollectionBeforeConsentAndFirstOpenAndBusinessResultsAreIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MemoryIdentity()
        let recorder = AnalyticsRecorder(directory: directory, identityStore: identity)
        XCTAssertFalse(recorder.record("level_start", key: "attempt", level: 1, config: "test", parameters: [:]))
        XCTAssertNil(identity.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        recorder.acceptConsent(); recorder.acceptConsent()
        XCTAssertEqual(recorder.events.map(\.eventName), ["first_open", "session_start"])
        for _ in 0..<20 { recorder.record("level_start", key: "attempt", level: 1, config: "test", parameters: ["attempt_no":"1", "grid_size":"4x4", "is_tutorial":"true", "direct_find_visible":"true", "direct_find_inventory":"1", "hint_inventory":"1", "level_start_free_available":"false"]) }
        XCTAssertEqual(recorder.events.filter { $0.eventName == "level_start" }.count, 1)
        XCTAssertEqual(recorder.events.last?.parameters["attempt_no"], .integer(1))
        XCTAssertEqual(recorder.events.last?.parameters["is_tutorial"], .flag(true))
        let first = recorder.events.first!
        recorder.endSession(reason: "quit"); recorder.endSession(reason: "quit")
        XCTAssertEqual(recorder.events.filter { $0.eventName == "session_end" }.count, 1)
        let restored = AnalyticsRecorder(directory: directory, identityStore: identity)
        restored.acceptConsent()
        XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
        XCTAssertEqual(restored.events.first?.eventTime, first.eventTime)
        XCTAssertEqual(restored.events.first?.userID, first.userID)
        XCTAssertEqual(restored.events.first?.sessionID, first.sessionID)
        XCTAssertFalse(restored.record("coin_change", key: "bad", parameters: [:]))
        XCTAssertFalse(restored.record("cell_tap", key: "bad", parameters: [:]))
        XCTAssertFalse(restored.record("level_start", key: "no-config", level: 2, parameters: [:]))
        XCTAssertTrue(restored.events.allSatisfy { $0.environment == "internal-demo-offline" })
    }

    @MainActor func testShortBackgroundKeepsSessionAndLongBackgroundEndsOnceWithoutDoubleDuration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AnalyticsRecorder(directory: directory, identityStore: MemoryIdentity(), sessionTimeout: 30)
        let start = Date(timeIntervalSince1970: 1000)
        recorder.acceptConsent(at: start)
        let firstSession = recorder.events.last!.sessionID
        recorder.endSession(reason: "background", at: start.addingTimeInterval(10))
        recorder.endSession(reason: "background", at: start.addingTimeInterval(11))
        recorder.beginSession(source: "resume", at: start.addingTimeInterval(20))
        XCTAssertEqual(recorder.events.filter { $0.eventName == "session_start" }.count, 1)
        XCTAssertTrue(recorder.record("tutorial_start", key: "tutorial", parameters: ["tutorial_id":"first"], at: start.addingTimeInterval(25)))
        XCTAssertEqual(recorder.events.last?.sessionID, firstSession)
        recorder.endSession(reason: "background", at: start.addingTimeInterval(30))
        recorder.beginSession(source: "resume", at: start.addingTimeInterval(100))
        let endings = recorder.events.filter { $0.eventName == "session_end" }
        XCTAssertEqual(endings.count, 1)
        XCTAssertEqual(endings.first?.parameters["duration_sec"], .integer(20))
        XCTAssertEqual(endings.first?.eventTime, start.addingTimeInterval(30))
        XCTAssertEqual(recorder.events.filter { $0.eventName == "session_start" }.count, 2)
        XCTAssertNotEqual(recorder.events.last?.sessionID, firstSession)
    }

    @MainActor func testInterruptedSessionRecoversOriginalIDsAndKnownDuration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MemoryIdentity(), start = Date(timeIntervalSince1970: 1000)
        let first = AnalyticsRecorder(directory: directory, identityStore: identity)
        first.acceptConsent(at: start)
        XCTAssertTrue(first.record("tutorial_start", key: "tutorial", parameters: ["tutorial_id":"first"], at: start.addingTimeInterval(15)))
        let firstSession = first.events.last!.sessionID
        let restored = AnalyticsRecorder(directory: directory, identityStore: identity)
        restored.acceptConsent(at: start.addingTimeInterval(40))
        let ending = try XCTUnwrap(restored.events.first { $0.eventName == "session_end" })
        XCTAssertEqual(ending.sessionID, firstSession)
        XCTAssertEqual(ending.parameters["duration_sec"], .integer(15))
        XCTAssertEqual(ending.parameters["end_reason"], .text("quit"))
        XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
    }

    @MainActor func testContractRejectsMissingFieldsPIIAndWrongEnumsWithoutCoercingStringIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AnalyticsRecorder(directory: directory, identityStore: MemoryIdentity())
        recorder.acceptConsent()
        XCTAssertFalse(recorder.record("level_start", key: "bad", level: 1, config: "test", parameters: ["attempt_no":"1"]))
        XCTAssertFalse(recorder.record("tutorial_start", key: "bad", parameters: ["tutorial_id":"one", "email":"test@example.com"]))
        XCTAssertFalse(recorder.record("session_end", key: "bad", parameters: ["duration_sec":"-1", "end_reason":"bad"]))
        let values = ["offer_id":"123", "placement_id":"hint", "status":"completed", "reward_granted":"true", "error_code":"", "ad_type":"rewarded", "network":"simulation", "ad_unit_id":"456"]
        XCTAssertTrue(recorder.record("ad_result", key: "offer", level: 1, config: "test", parameters: values))
        XCTAssertEqual(recorder.events.last?.parameters["offer_id"], .text("123"))
        XCTAssertEqual(recorder.events.last?.parameters["ad_unit_id"], .text("456"))
        XCTAssertEqual(recorder.events.last?.parameters["reward_granted"], .flag(true))
    }

    @MainActor func testInterstitialContractRequiresSeparatePlacementAndRejectsAnyGameReward() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = AnalyticsRecorder(directory: directory, identityStore: MemoryIdentity())
        recorder.acceptConsent()
        let offered = ["offer_id": "one", "placement_id": "demo_interstitial_win_v1", "reward_type": "", "buff_type": "", "reward_amount": "0", "ad_type": "interstitial", "network": "simulation", "ad_unit_id": "internal-demo"]
        let result = ["offer_id": "one", "placement_id": "demo_interstitial_win_v1", "status": "completed", "reward_granted": "false", "error_code": "", "ad_type": "interstitial", "network": "simulation", "ad_unit_id": "internal-demo"]
        XCTAssertTrue(recorder.record("ad_offer_shown", key: "one", level: 2, config: "demo", parameters: offered))
        XCTAssertTrue(recorder.record("ad_result", key: "one:completed", level: 2, config: "demo", parameters: result))
        for (field, value) in [("reward_amount", "1"), ("reward_type", "hint"), ("buff_type", "hint"), ("placement_id", "hint"), ("placement_id", "  ")] {
            var invalid = offered; invalid[field] = value
            XCTAssertFalse(recorder.record("ad_offer_shown", key: UUID().uuidString, level: 2, config: "demo", parameters: invalid))
        }
        var awarded = result; awarded["reward_granted"] = "true"
        XCTAssertFalse(recorder.record("ad_result", key: "invalid-grant", level: 2, config: "demo", parameters: awarded))
        var borrowed = result; borrowed["ad_type"] = "rewarded"
        XCTAssertFalse(recorder.record("ad_result", key: "invalid-rewarded-placement", level: 2, config: "demo", parameters: borrowed))
        var inventedRevenue = result; inventedRevenue["revenue"] = "1"
        XCTAssertFalse(recorder.record("ad_result", key: "invalid-revenue", level: 2, config: "demo", parameters: inventedRevenue))
        XCTAssertEqual(recorder.events.filter { $0.eventName.hasPrefix("ad_") }.count, 2)
    }

    @MainActor func testFailedWritesRetainOriginalEventsAndRetryAfterStorageRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("blocked".utf8).write(to: directory)
        let identity = MemoryIdentity()
        let recorder = AnalyticsRecorder(directory: directory, identityStore: identity)
        let date = Date(timeIntervalSince1970: 1000)
        recorder.acceptConsent(at: date)
        XCTAssertNotNil(recorder.lastError)
        let original = recorder.events.first!
        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(recorder.retryPendingWrites())
        let restored = AnalyticsRecorder(directory: directory, identityStore: identity)
        XCTAssertEqual(restored.events.first?.eventID, original.eventID)
        XCTAssertEqual(restored.events.first?.eventTime, original.eventTime)
        XCTAssertEqual(restored.events.first?.userID, original.userID)
    }

    @MainActor func testFailedCrashSessionSettlementStillStartsNewColdSessionAndRecoveryPreservesEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MemoryIdentity(), start = Date(timeIntervalSince1970: 1000)
        let first = AnalyticsRecorder(directory: directory, identityStore: identity)
        first.acceptConsent(at: start)
        XCTAssertTrue(first.record("tutorial_start", key: "previous-activity", parameters: ["tutorial_id": "first"], at: start.addingTimeInterval(15)))
        let previousID = try XCTUnwrap(first.events.last?.sessionID)

        // Read the real saved active session, then make its directory unwritable
        // by replacing the path with a regular file before crash settlement.
        let current = AnalyticsRecorder(directory: directory, identityStore: identity)
        try FileManager.default.removeItem(at: directory)
        try Data("blocked-directory".utf8).write(to: directory)
        let coldStart = start.addingTimeInterval(40)
        current.acceptConsent(at: coldStart)
        XCTAssertNotNil(current.lastError)
        let ending = try XCTUnwrap(current.events.first { $0.eventName == "session_end" })
        let newStart = try XCTUnwrap(current.events.last { $0.eventName == "session_start" })
        XCTAssertEqual(ending.sessionID, previousID)
        XCTAssertEqual(ending.eventTime, start.addingTimeInterval(15))
        XCTAssertEqual(ending.parameters["duration_sec"], .integer(15))
        XCTAssertEqual(ending.parameters["end_reason"], .text("quit"))
        XCTAssertNotEqual(newStart.sessionID, previousID)
        XCTAssertEqual(newStart.eventTime, coldStart)
        XCTAssertEqual(newStart.parameters["entry_source"], .text("cold_start"))
        XCTAssertFalse(current.record("tutorial_start", key: "new-activity", parameters: ["tutorial_id": "second"], at: coldStart.addingTimeInterval(2)))
        let activity = try XCTUnwrap(current.events.last)
        XCTAssertEqual(activity.sessionID, newStart.sessionID)

        try FileManager.default.removeItem(at: directory)
        current.acceptConsent(at: coldStart.addingTimeInterval(5)) // The existing enabled path retries writes.
        current.beginSession(source: "resume", at: coldStart.addingTimeInterval(6))
        XCTAssertNil(current.lastError)
        XCTAssertEqual(current.events.filter { $0.eventName == "session_start" }.count, 2)
        XCTAssertEqual(current.events.filter { $0.eventName == "session_end" }.count, 1)
        let restored = AnalyticsRecorder(directory: directory, identityStore: identity)
        for expected in [ending, newStart, activity] {
            let actual = try XCTUnwrap(restored.events.first { $0.eventID == expected.eventID })
            XCTAssertEqual(actual.eventTime, expected.eventTime)
            XCTAssertEqual(actual.sessionID, expected.sessionID)
            XCTAssertEqual(actual.userID, expected.userID)
            XCTAssertEqual(actual.parameters, expected.parameters)
        }
        XCTAssertEqual(restored.events.filter { $0.eventName == "first_open" }.count, 1)
    }

    @MainActor func testFailedLongBackgroundSettlementDoesNotAttachResumeActivityToEndedSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MemoryIdentity(), start = Date(timeIntervalSince1970: 1000)
        let recorder = AnalyticsRecorder(directory: directory, identityStore: identity, sessionTimeout: 30)
        recorder.acceptConsent(at: start)
        let oldID = try XCTUnwrap(recorder.events.last?.sessionID)
        recorder.endSession(reason: "background", at: start.addingTimeInterval(10))
        try FileManager.default.removeItem(at: directory)
        try Data("blocked-directory".utf8).write(to: directory)
        recorder.beginSession(source: "resume", at: start.addingTimeInterval(60))
        XCTAssertNotNil(recorder.lastError)
        let ending = try XCTUnwrap(recorder.events.first { $0.eventName == "session_end" })
        let resumed = try XCTUnwrap(recorder.events.last { $0.eventName == "session_start" })
        XCTAssertEqual(ending.sessionID, oldID)
        XCTAssertEqual(ending.eventTime, start.addingTimeInterval(10))
        XCTAssertEqual(ending.parameters["duration_sec"], .integer(10))
        XCTAssertEqual(resumed.eventTime, start.addingTimeInterval(60))
        XCTAssertEqual(resumed.parameters["entry_source"], .text("resume"))
        XCTAssertNotEqual(resumed.sessionID, oldID)
        XCTAssertFalse(recorder.record("tutorial_start", key: "resumed-activity", parameters: ["tutorial_id": "second"], at: start.addingTimeInterval(61)))
        XCTAssertEqual(recorder.events.last?.sessionID, resumed.sessionID)
        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(recorder.retryPendingWrites())
        recorder.beginSession(source: "resume", at: start.addingTimeInterval(65))
        XCTAssertEqual(recorder.events.filter { $0.eventName == "session_start" }.count, 2)
        XCTAssertEqual(recorder.events.filter { $0.eventName == "session_end" }.count, 1)
        let restored = AnalyticsRecorder(directory: directory, identityStore: identity)
        XCTAssertEqual(restored.events.map(\.eventID), recorder.events.map(\.eventID))
    }
}


extension AnalyticsRecorderTests {
    /// Original [383]: one real local business path. Identity DI is already
    /// verified separately; storage, AppModel actions and the shipped duplicate
    /// reward simulator are real. This does not claim SDK or backend acceptance.
    @MainActor func testOriginal383CompleteLocalBusinessPathPreservesOrderOwnershipAndDurability() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("analytics-full-path-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MemoryIdentity()
        @MainActor func model() -> AppModel {
            let localConfiguration = GameplayConfigurationStore(directory: directory, target: .current,
                                                                 bundledData: nil, provider: nil)
            return AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false,
                            analyticsIdentityStore: identity, gameplayConfigurationStore: localConfiguration)
        }
        func canonical(_ events: [AnalyticsRecorder.Event]) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return try encoder.encode(events)
        }
        let app = model()
        XCTAssertFalse(app.analytics.enabled)
        XCTAssertTrue(app.analytics.events.isEmpty)
        XCTAssertNil(identity.value)
        app.config = DemoConfig(version: "original-383-local-test-only", initialLives: 1, hintsPerLevel: 1, directPerLevel: 0)
        app.consentAccepted(); app.consentAccepted(); app.startupReady()
        XCTAssertTrue(app.analytics.enabled, app.analytics.lastError ?? "Consent should enable the local recorder.")
        app.startOrContinue()
        let teachingBoard = try XCTUnwrap(app.session?.puzzle)
        XCTAssertEqual(teachingBoard.id, 1)
        XCTAssertFalse(app.progress.tutorialCompleted)
        XCTAssertEqual(app.tutorialCount, 9)
        // Complete all original instructional operations, rather than setting
        // tutorialCompleted or manufacturing tutorial events in the recorder.
        var teachingActions: [String] = []
        for index in 0..<9 {
            let step = try XCTUnwrap(app.tutorial)
            teachingActions.append(step.action)
            switch step.action {
            case "read": app.advanceTutorial()
            case "tap": app.toggle(try XCTUnwrap(step.targetCells.first))
            case "swipe": app.mark(step.targetCells)
            case "doubleTap": app.submit(try XCTUnwrap(step.targetCells.first))
            default: XCTFail("Unexpected tutorial action: \(step.action)")
            }
            XCTAssertEqual(app.progress.tutorialStep, index + 1)
            XCTAssertNil(app.errorMessage)
        }
        XCTAssertEqual(teachingActions, ["read", "read", "read", "read", "tap", "tap", "swipe", "swipe", "doubleTap"])
        XCTAssertTrue(app.progress.tutorialCompleted); XCTAssertNil(app.tutorial)
        // The introduction is embedded in Level 1. Finish that same board and
        // use Next to enter the first ordinary attempt after the introduction.
        for cell in teachingBoard.solution where app.session?.found.contains(cell) == false { app.submit(cell) }
        XCTAssertEqual(app.session?.status, .won)
        app.next()
        let failingAttempt = try XCTUnwrap(app.session), board = failingAttempt.puzzle
        XCTAssertEqual(board.id, 2); XCTAssertEqual(failingAttempt.attempt, 1)
        XCTAssertEqual(failingAttempt.lives, 1)
        let wrong = try XCTUnwrap(board.regions.indices.first { !board.solution.contains($0) })
        app.submit(wrong); app.submit(wrong)
        XCTAssertEqual(app.session?.status, .lost)
        XCTAssertEqual(app.session?.lives, 0)
        app.restart(); app.restart() // A repeated button callback cannot add an attempt.
        let retry = try XCTUnwrap(app.session)
        XCTAssertEqual(retry.attempt, 2); XCTAssertNotEqual(retry.id, failingAttempt.id)
        XCTAssertEqual(retry.puzzle, board); XCTAssertEqual(retry.lives, 1)
        XCTAssertEqual(app.progress.availableHints, 1)
        XCTAssertEqual(app.progress.availableDirect, 0)

        let beforePreview = try XCTUnwrap(app.session?.marks)
        app.showHint()
        let hintUse = try XCTUnwrap(app.progress.activeHintUse)
        XCTAssertNotNil(app.hint)
        app.hintDidAppear(useID: hintUse.id); app.hintDidAppear(useID: hintUse.id)
        XCTAssertEqual(app.session?.marks, beforePreview)
        app.applyHint(); app.applyHint()
        XCTAssertNil(app.hint)
        XCTAssertEqual(app.session?.marks, beforePreview.union(hintUse.hint.cells))
        XCTAssertEqual(app.progress.availableHints, 0)

        // Exercise the actual local reward simulator, including its delayed
        // second earned callback. No test calls analytics.record or grants a tool.
        app.rewardScenario = .duplicate
        app.direct()
        XCTAssertTrue(app.rewardBusy)
        for _ in 0..<100 {
            if !app.rewardBusy { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(app.rewardBusy, "The local simulated reward did not finish within two seconds.")
        try await Task.sleep(nanoseconds: 250_000_000) // Also drain the simulator's 150 ms duplicate.
        XCTAssertNil(app.errorMessage); XCTAssertNil(app.notice)
        XCTAssertEqual(app.progress.rewardLedger.count, 1)
        let reward = try XCTUnwrap(app.progress.rewardLedger.values.first)
        XCTAssertEqual(reward.kind, .direct); XCTAssertEqual(reward.state, .executed)
        XCTAssertEqual(app.session?.found.count, 1, "One video must reveal only one animal despite its duplicate callback.")
        XCTAssertEqual(app.progress.availableDirect, 0)
        for cell in board.solution where app.session?.found.contains(cell) == false { app.submit(cell) }
        XCTAssertEqual(app.session?.status, .won)
        app.submit(board.solution[0]) // A terminal board cannot emit another win.
        app.home(); app.home()
        XCTAssertEqual(app.screen, .home)
        app.setActive(false); app.setActive(false)
        app.flushPendingSaves()
        let beforeColdLaunch = app.analytics.events
        XCTAssertFalse(beforeColdLaunch.contains { $0.eventName == "session_end" }, "Background timeout is intentionally deferred until a later lifecycle boundary.")
        // A real cold launch settles the interrupted background session and
        // opens the next one; the complete path below ends at the old session_end.
        let restored = model()
        restored.consentAccepted(); restored.consentAccepted()
        let events = restored.analytics.events
        XCTAssertEqual(events.map(\.eventName), [
            "first_open", "session_start", "level_start", "tutorial_start", "tutorial_end", "level_end",
            "level_start", "level_end", "level_restart", "level_start", "buff_use", "buff_use",
            "ad_offer_shown", "ad_result", "ad_result", "buff_use", "level_end", "session_end", "session_start"
        ])
        XCTAssertEqual(try canonical(Array(events.prefix(beforeColdLaunch.count))), try canonical(beforeColdLaunch))
        XCTAssertEqual(Set(events.map(\.eventID)).count, events.count)
        let first = try XCTUnwrap(events.first), newSession = try XCTUnwrap(events.last)
        XCTAssertEqual(Set(events.map(\.userID)), [first.userID])
        XCTAssertEqual(Set(events.map(\.installDate)), [first.installDate])
        XCTAssertTrue(events.dropLast().allSatisfy { $0.sessionID == first.sessionID })
        XCTAssertNotEqual(newSession.sessionID, first.sessionID)
        XCTAssertTrue(events.allSatisfy {
            UUID(uuidString: $0.eventID) != nil && UUID(uuidString: $0.userID) != nil && UUID(uuidString: $0.sessionID) != nil &&
            $0.platform == "iOS" && !$0.appVersion.isEmpty && !$0.country.isEmpty &&
            !$0.installDate.isEmpty && $0.environment == "internal-demo-offline"
        })
        for event in events {
            if ["first_open", "session_start", "session_end"].contains(event.eventName) {
                XCTAssertNil(event.levelID); XCTAssertNil(event.pawdokuConfigVersion)
            } else {
                XCTAssertNotNil(event.levelID)
                XCTAssertEqual(event.pawdokuConfigVersion, "original-383-local-test-only")
            }
        }
        func named(_ name: String) -> [AnalyticsRecorder.Event] { events.filter { $0.eventName == name } }
        func requireNonnegativeDuration(_ event: AnalyticsRecorder.Event) {
            guard case .integer(let seconds) = event.parameters["duration_sec"] else {
                return XCTFail("Missing integer duration_sec for \(event.eventName)")
            }
            XCTAssertGreaterThanOrEqual(seconds, 0)
        }
        XCTAssertEqual(first.parameters, ["install_source": .text("internal_demo"), "is_reinstall": .flag(false)])
        XCTAssertTrue(named("session_start").allSatisfy { $0.parameters == ["entry_source": .text("cold_start")] })
        XCTAssertEqual(named("tutorial_start").first?.parameters, ["tutorial_id": .text("level-1-dynamic")])
        let tutorialEnd = try XCTUnwrap(named("tutorial_end").first)
        XCTAssertEqual(tutorialEnd.levelID, 1)
        XCTAssertEqual(Set(tutorialEnd.parameters.keys), ["tutorial_id", "result", "duration_sec"])
        XCTAssertEqual(tutorialEnd.parameters["tutorial_id"], .text("level-1-dynamic"))
        XCTAssertEqual(tutorialEnd.parameters["result"], .text("complete")); requireNonnegativeDuration(tutorialEnd)
        let starts = named("level_start")
        XCTAssertEqual(starts.map(\.levelID), [1, 2, 2])
        for (index, event) in starts.enumerated() {
            let size = index == 0 ? teachingBoard.size : board.size
            XCTAssertEqual(event.parameters, ["attempt_no": .integer(index == 2 ? 2 : 1), "grid_size": .text("\(size)x\(size)"),
                "is_tutorial": .flag(index == 0), "direct_find_visible": .flag(true), "direct_find_inventory": .integer(0),
                "hint_inventory": .integer(1), "level_start_free_available": .flag(false)])
        }
        let ends = named("level_end")
        XCTAssertEqual(ends.map(\.levelID), [1, 2, 2])
        for (index, event) in ends.enumerated() {
            XCTAssertEqual(Set(event.parameters.keys), ["result", "duration_sec", "attempt_no", "fail_reason", "life_remaining"])
            XCTAssertEqual(event.parameters["result"], .text(index == 1 ? "lose" : "win"))
            XCTAssertEqual(event.parameters["attempt_no"], .integer(index == 2 ? 2 : 1))
            XCTAssertEqual(event.parameters["fail_reason"], .text(index == 1 ? "life_zero" : ""))
            XCTAssertEqual(event.parameters["life_remaining"], .integer(index == 1 ? 0 : 1))
            requireNonnegativeDuration(event)
        }
        XCTAssertEqual(named("level_restart").first?.levelID, 2)
        XCTAssertEqual(named("level_restart").first?.parameters,
                       ["restart_reason": .text("after_fail"), "previous_fail_reason": .text("life_zero"), "next_attempt_no": .integer(2)])
        let uses = named("buff_use")
        XCTAssertTrue(uses.allSatisfy { $0.levelID == 2 })
        for (index, event) in uses.enumerated() {
            XCTAssertEqual(event.parameters, ["buff_type": .text(index == 2 ? "direct_find" : "hint"),
                "source": .text(index == 2 ? "rewarded_ad" : "level_config_free"), "applied": .flag(index != 0),
                "inventory_before": .integer(index == 0 ? 1 : 0), "inventory_after": .integer(0)])
        }
        let offered = try XCTUnwrap(named("ad_offer_shown").first)
        XCTAssertEqual(offered.levelID, 2)
        XCTAssertEqual(offered.parameters, ["offer_id": .text(reward.id), "placement_id": .text("direct_find"),
            "reward_type": .text("direct_find"), "buff_type": .text("direct_find"), "reward_amount": .integer(1),
            "ad_type": .text("rewarded"), "network": .text("simulation"), "ad_unit_id": .text("internal-demo")])
        for (index, event) in named("ad_result").enumerated() {
            XCTAssertEqual(event.levelID, offered.levelID)
            XCTAssertEqual(event.parameters, ["offer_id": .text(reward.id), "placement_id": .text("direct_find"),
                "status": .text(index == 0 ? "started" : "completed"), "reward_granted": .flag(index == 1),
                "ad_type": .text("rewarded"), "network": .text("simulation"), "ad_unit_id": .text("internal-demo"), "error_code": .text("")])
        }
        let ended = try XCTUnwrap(named("session_end").first)
        XCTAssertEqual(Set(ended.parameters.keys), ["duration_sec", "end_reason"])
        XCTAssertEqual(ended.parameters["end_reason"], .text("background")); requireNonnegativeDuration(ended)
        XCTAssertLessThanOrEqual(ended.eventTime, newSession.eventTime)
        XCTAssertTrue(restored.progress.tutorialCompleted)
        XCTAssertEqual(restored.progress.session?.id, retry.id)
        XCTAssertEqual(restored.progress.session?.status, .won)
        XCTAssertTrue(restored.progress.completedLevels.isSuperset(of: [1, 2]))
        XCTAssertTrue(restored.progress.pendingBuffEvents.isEmpty)
        XCTAssertTrue(restored.progress.pendingLevelResultEvents.isEmpty)
        XCTAssertEqual(restored.progress.rewardLedger[reward.id]?.state, .executed)
        XCTAssertNil(restored.progress.rewardLedger[reward.id]?.completionEvent)
        XCTAssertTrue(restored.progress.rewardLedger[reward.id]?.pendingAdEvents.isEmpty == true)
        XCTAssertEqual(restored.progress.rewardLedger[reward.id]?.analyticsOfferPending, false)
        struct DiskQueue: Decodable { let events: [AnalyticsRecorder.Event] }
        let disk = try JSONDecoder().decode(DiskQueue.self, from: Data(contentsOf: directory.appendingPathComponent("analytics-demo-queue.json")))
        XCTAssertEqual(try canonical(disk.events), try canonical(events), "Every asserted event must actually be durable on disk.")
        let evidence = XCTAttachment(data: try canonical(disk.events), uniformTypeIdentifier: "public.json")
        evidence.name = "Original-383-local-only-event-chain"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
