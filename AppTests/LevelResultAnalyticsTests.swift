import XCTest
import CapydokuCore
@testable import Capydoku

private final class ResultIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}
private final class ResultRewards: RewardProvider {
    var callbacks: [(RewardSignal) -> Void] = []
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) { callbacks.append(completion) }
}

final class LevelResultAnalyticsTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor private func model(_ directory: URL, identity: ResultIdentity = ResultIdentity(),
                                  rewards: ResultRewards? = nil, consent: Bool = true, asyncSaves: Bool = false) -> AppModel {
        let app = AppModel(saveDirectory: directory, rewardProvider: rewards, runsTimer: asyncSaves,
                           feedbackEnabled: false, analyticsIdentityStore: identity)
        if consent { app.consentAccepted() }
        app.progress.tutorialCompleted = true
        app.config = DemoConfig(initialLives: 1, directPerLevel: 0)
        if app.session == nil { app.start(level: 1) }
        app.notice = nil
        return app
    }
    @MainActor private func ends(_ app: AppModel) -> [AnalyticsRecorder.Event] {
        app.analytics.events.filter { $0.eventName == "level_end" }
    }
    @MainActor private func store(_ app: AppModel) throws -> SaveStore {
        let board = try XCTUnwrap(app.session?.puzzle)
        // App saves contain a packaged-board reference, not an embedded board.
        return SaveStore(directory: app.saveDirectory, packagedPuzzle: { $0 == board.id ? board : nil })
    }
    @MainActor private func win(_ app: AppModel) throws {
        let solution = try XCTUnwrap(app.session?.puzzle.solution)
        for cell in solution where app.session?.found.contains(cell) == false { app.submit(cell) }
        XCTAssertEqual(app.session?.status, .won)
    }
    @MainActor func testRepeatedLossRevivalAndWinAllRecordWithoutNewLevelStart() async throws {
        let rewards = ResultRewards(), app = model(directory(), rewards: rewards)
        let original = try XCTUnwrap(app.session)
        let wrong = original.puzzle.regions.indices.filter { !original.puzzle.solution.contains($0) }
        for i in 0..<2 {
            app.submit(wrong[i]); XCTAssertEqual(app.session?.status, .lost)
            app.submit(wrong[i]) // A duplicate gesture cannot add another loss.
            app.revive()
            let callback = try XCTUnwrap(rewards.callbacks.last)
            callback(.started); callback(.earned); callback(.earned)
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(app.session?.status, .playing)
        }
        try win(app)
        app.submit(original.puzzle.solution[0]); app.home()
        XCTAssertEqual(ends(app).map { $0.parameters["result"] }, [.text("lose"), .text("lose"), .text("win")])
        XCTAssertEqual(Set(ends(app).map(\.eventID)).count, 3)
        XCTAssertTrue(ends(app).allSatisfy { $0.parameters["attempt_no"] == .integer(1) })
        XCTAssertEqual(app.session?.id, original.id)
        XCTAssertEqual(app.analytics.events.filter { $0.eventName == "level_start" }.count, 1)
        XCTAssertTrue(app.progress.pendingLevelResultEvents.isEmpty)
    }
    @MainActor func testQuitContinueBackgroundAndColdRestorePreserveEveryActualResult() throws {
        let dir = directory(), identity = ResultIdentity(), app = model(dir, identity: identity)
        app.progress.session?.advanceTime(by: 10)
        app.home(); app.home()
        XCTAssertEqual(ends(app).count, 1)
        app.setActive(false); app.setActive(true)
        XCTAssertEqual(ends(app).count, 1)
        let restored = model(dir, identity: identity)
        restored.startOrContinue(); restored.startOrContinue()
        restored.progress.session?.advanceTime(by: 5)
        restored.home(); restored.startOrContinue()
        try win(restored)
        XCTAssertEqual(ends(restored).map { $0.parameters["result"] }, [.text("quit"), .text("quit"), .text("win")])
        XCTAssertEqual(ends(restored).map { $0.parameters["duration_sec"] }, [.integer(10), .integer(15), .integer(15)])
        XCTAssertEqual(restored.analytics.events.filter { $0.eventName == "level_start" }.count, 1)
        XCTAssertEqual(restored.session?.attempt, 1)
    }
    @MainActor func testRestartCreatesNewAttemptAndIndependentWin() throws {
        let app = model(directory())
        let original = try XCTUnwrap(app.session)
        app.submit(try XCTUnwrap(original.puzzle.regions.indices.first { !original.puzzle.solution.contains($0) }))
        app.restart()
        try win(app)
        XCTAssertNotEqual(app.session?.id, original.id)
        XCTAssertEqual(ends(app).map { $0.parameters["result"] }, [.text("lose"), .text("win")])
        XCTAssertEqual(ends(app).map { $0.parameters["attempt_no"] }, [.integer(1), .integer(2)])
        XCTAssertEqual(app.analytics.events.filter { $0.eventName == "level_start" }.count, 2)
    }
    @MainActor func testQueueWriteFailureColdRecoveryAndLostAcknowledgementReuseFrozenEvent() throws {
        let dir = directory(), identity = ResultIdentity(), app = model(dir, identity: identity)
        let queue = dir.appendingPathComponent("analytics-demo-queue.json")
        let previousQueue = try Data(contentsOf: queue)
        try FileManager.default.removeItem(at: queue)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: false)
        try win(app)
        XCTAssertEqual(app.progress.pendingLevelResultEvents.count, 1)
        let beforeAcknowledgement = try store(app).load().progress
        XCTAssertEqual(beforeAcknowledgement.session?.status, .won)
        let data = try XCTUnwrap(beforeAcknowledgement.pendingLevelResultEvents.values.first)
        let prepared = try JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: data)
        try FileManager.default.removeItem(at: queue)
        try previousQueue.write(to: queue, options: .atomic)
        let recovered = model(dir, identity: identity)
        let event = try XCTUnwrap(ends(recovered).first)
        XCTAssertEqual(event.eventID, prepared.event.eventID)
        XCTAssertEqual(event.eventTime, prepared.event.eventTime)
        XCTAssertEqual(event.sessionID, prepared.event.sessionID)
        XCTAssertEqual(event.userID, prepared.event.userID)
        XCTAssertEqual(event.parameters, prepared.event.parameters)
        XCTAssertNotEqual(event.sessionID, recovered.analytics.events.last { $0.eventName == "session_start" }?.sessionID)
        XCTAssertTrue(recovered.progress.pendingLevelResultEvents.isEmpty)
        // Model a kill after the analytics queue committed but before progress acknowledged it.
        try store(recovered).save(beforeAcknowledgement)
        let replayed = model(dir, identity: identity)
        XCTAssertEqual(ends(replayed).count, 1)
        XCTAssertEqual(ends(replayed).first?.eventID, event.eventID)
        XCTAssertTrue(replayed.progress.pendingLevelResultEvents.isEmpty)
    }
    @MainActor func testUnsavedGameplayResultIsNotDeliveredUntilTheSaveSucceeds() throws {
        let dir = directory(), app = model(dir)
        let primary = dir.appendingPathComponent("progress.json")
        let previous = try Data(contentsOf: primary)
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        try win(app)
        XCTAssertEqual(app.progress.pendingLevelResultEvents.count, 1)
        XCTAssertTrue(ends(app).isEmpty)
        XCTAssertNotNil(app.errorMessage)
        try FileManager.default.removeItem(at: primary)
        try previous.write(to: primary, options: .atomic)
        app.save()
        XCTAssertEqual(ends(app).count, 1)
        XCTAssertTrue(app.progress.pendingLevelResultEvents.isEmpty)
        let saved = try store(app).load().progress
        XCTAssertEqual(saved.session?.status, .won)
        XCTAssertTrue(saved.pendingLevelResultEvents.isEmpty)
    }
    @MainActor func testPreConsentPlayDoesNotCreateRetroactiveEvents() throws {
        let app = model(directory(), consent: false)
        try win(app)
        XCTAssertTrue(app.progress.pendingLevelResultEvents.isEmpty)
        XCTAssertTrue(app.analytics.events.isEmpty)
        app.consentAccepted(); app.save()
        XCTAssertTrue(ends(app).isEmpty)
    }
    @MainActor func testCheckInReturnAfterColdRestoreIsNotAQuitFromGameplay() throws {
        let dir = directory(), identity = ResultIdentity(), app = model(dir, identity: identity)
        app.setActive(false)
        let restored = model(dir, identity: identity)
        XCTAssertEqual(restored.screen, .home)
        restored.screen = .checkIn; restored.home(); restored.home()
        XCTAssertTrue(ends(restored).isEmpty)
        XCTAssertNil(restored.session?.resultPhaseEnd)
        restored.startOrContinue(); restored.home()
        XCTAssertEqual(ends(restored).map { $0.parameters["result"] }, [.text("quit")])
    }
    @MainActor func testWinningRewardTransactionSurvivesKillBeforeAnyAfterActionSave() throws {
        let dir = directory(), identity = ResultIdentity(), app = model(dir, identity: identity)
        let board = try XCTUnwrap(app.session?.puzzle)
        for cell in board.solution.dropLast() { app.submit(cell) }
        let store = try store(app), offer = UUID().uuidString
        XCTAssertTrue(try store.prepareReward(offerID: offer, kind: .direct, progress: &app.progress))
        let outcome = try store.grantReward(offerID: offer, progress: &app.progress) { candidate, result in
            app.finalizeRewardResult(result, in: &candidate)
        }
        guard case .directRevealed = outcome else { return XCTFail("Expected the final animal reward") }
        // Stop at exactly the reward commit: do not call afterAction or app.save.
        let committed = store.load().progress
        XCTAssertEqual(committed.session?.status, .won)
        XCTAssertEqual(committed.session?.resultPhaseEnd, .win)
        XCTAssertEqual(committed.rewardLedger[offer]?.state, .executed)
        XCTAssertTrue(committed.completedLevels.contains(1))
        XCTAssertEqual(committed.unlockedLevel, 2)
        XCTAssertEqual(committed.pendingLevelResultEvents.count, 1)
        XCTAssertTrue(ends(app).isEmpty)
        let recovered = model(dir, identity: identity)
        XCTAssertEqual(ends(recovered).map { $0.parameters["result"] }, [.text("win")])
        XCTAssertEqual(recovered.session?.puzzle, board)
        XCTAssertTrue(recovered.progress.pendingLevelResultEvents.isEmpty)
        XCTAssertTrue(recovered.progress.completedLevels.contains(1))
    }
    @MainActor func testFinalDirectRewardCallbackRecordsExactlyOneWinAndCompletion() async throws {
        let rewards = ResultRewards(), app = model(directory(), rewards: rewards)
        let board = try XCTUnwrap(app.session?.puzzle)
        for cell in board.solution.dropLast() { app.submit(cell) }
        app.offer(.direct)
        let callback = try XCTUnwrap(rewards.callbacks.last)
        callback(.started); callback(.earned); callback(.earned)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(app.session?.status, .won)
        XCTAssertEqual(ends(app).map { $0.parameters["result"] }, [.text("win")])
        XCTAssertEqual(app.progress.rewardLedger.values.filter { $0.state == .executed }.count, 1)
        XCTAssertTrue(app.progress.pendingLevelResultEvents.isEmpty)
        let committed = try store(app).load().progress
        XCTAssertEqual(committed.session?.resultPhaseEnd, .win)
        XCTAssertTrue(committed.completedLevels.contains(1))
        XCTAssertEqual(committed.unlockedLevel, 2)
    }
    @MainActor func testProductionAsyncSavesKeepQuitThenWinAcrossImmediateNextLevel() async throws {
        let app = model(directory(), asyncSaves: true)
        app.home(); app.startOrContinue(); try win(app)
        app.start(level: 2)
        app.flushPendingSaves()
        try await Task.sleep(nanoseconds: 60_000_000)
        app.flushPendingSaves()
        XCTAssertEqual(ends(app).map { $0.parameters["result"] }, [.text("quit"), .text("win")])
        XCTAssertTrue(ends(app).allSatisfy { $0.levelID == 1 })
        XCTAssertEqual(app.session?.puzzle.id, 2)
        XCTAssertTrue(app.progress.pendingLevelResultEvents.isEmpty)
        let restored = try store(app).load()
        XCTAssertEqual(restored.source, .primary)
        XCTAssertTrue(restored.progress.pendingLevelResultEvents.isEmpty)
    }
}
