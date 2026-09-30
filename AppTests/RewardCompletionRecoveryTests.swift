import XCTest
import CapydokuCore
@testable import Capydoku

private final class ReceiptIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}
private final class ReceiptRewards: RewardProvider {
    var requests: [(String, (RewardSignal) -> Void)] = []
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) { requests.append((offerID, completion)) }
}

final class RewardCompletionRecoveryTests: XCTestCase {
    private func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    @MainActor private func model(_ dir: URL, _ identity: ReceiptIdentity, rewards: ReceiptRewards? = nil,
                                  consent: Bool = true, asyncSaves: Bool = false) -> AppModel {
        let app = AppModel(saveDirectory: dir, rewardProvider: rewards, runsTimer: asyncSaves,
                           feedbackEnabled: false, analyticsIdentityStore: identity)
        if consent { app.consentAccepted() }
        app.config = DemoConfig(initialLives: 1, hintsPerLevel: 0, directPerLevel: 0)
        app.progress.tutorialCompleted = true
        if app.session == nil { app.start(level: 1) }
        app.notice = nil
        return app
    }
    @MainActor private func completions(_ app: AppModel) -> [AnalyticsRecorder.Event] {
        app.analytics.events.filter { $0.eventName == "ad_result" && $0.parameters["status"] == .text("completed") }
    }
    @MainActor private func store(_ app: AppModel) throws -> SaveStore {
        let board = try XCTUnwrap(app.session?.puzzle)
        return SaveStore(directory: app.saveDirectory, packagedPuzzle: { $0 == board.id ? board : nil })
    }
    @MainActor func testInterruptedToolReceiptsCompensateOnceWithOriginalEventContextEvenAfterChangingLevel() async throws {
        for kind: RewardKind in [.direct, .hint] {
            let dir = directory(), identity = ReceiptIdentity(), rewards = ReceiptRewards()
            let app = model(dir, identity, rewards: rewards)
            let board = try XCTUnwrap(app.session)
            app.offer(kind)
            let request = try XCTUnwrap(rewards.requests.last)
            request.1(.started); request.1(.interrupted); request.1(.interrupted)
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertTrue(completions(app).isEmpty, "Receipt alone must not claim successful effect or compensation")
            let record = try XCTUnwrap(app.progress.rewardLedger[request.0])
            let frozen = try JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: XCTUnwrap(record.completionEvent))
            XCTAssertEqual(record.state, .rewarded)
            XCTAssertEqual(app.session, board)
            let restored = model(dir, identity, consent: false)
            XCTAssertEqual(restored.session, board, "Cold compensation cannot replay board actions")
            restored.start(level: 2) // Delivery must retain the original offer's level and config.
            restored.consentAccepted()
            let event = try XCTUnwrap(completions(restored).first)
            XCTAssertEqual(event.eventID, frozen.event.eventID)
            XCTAssertEqual(event.eventTime, frozen.event.eventTime)
            XCTAssertEqual(event.userID, frozen.event.userID)
            XCTAssertEqual(event.sessionID, frozen.event.sessionID)
            XCTAssertEqual(event.levelID, 1)
            XCTAssertEqual(event.pawdokuConfigVersion, board.config.version)
            XCTAssertEqual(event.parameters["offer_id"], .text(request.0))
            XCTAssertEqual(event.parameters["reward_granted"], .flag(true))
            XCTAssertEqual(restored.progress.bonusDirect, kind == .direct ? 1 : 0)
            XCTAssertEqual(restored.progress.bonusHints, kind == .hint ? 1 : 0)
            XCTAssertFalse(restored.analytics.events.contains { $0.eventName == "buff_use" })
            let again = model(dir, identity)
            XCTAssertEqual(completions(again).count, 1)
            XCTAssertEqual(again.progress.rewardLedger[request.0]?.state, .compensated)
            XCTAssertNil(again.progress.rewardLedger[request.0]?.completionEvent)
            XCTAssertEqual(again.progress.bonusDirect, restored.progress.bonusDirect)
            XCTAssertEqual(again.progress.bonusHints, restored.progress.bonusHints)
        }
    }
    @MainActor func testInterruptedReviveReportsCompletedWithoutGrantOrReplay() async throws {
        let dir = directory(), identity = ReceiptIdentity(), rewards = ReceiptRewards()
        let app = model(dir, identity, rewards: rewards)
        let board = try XCTUnwrap(app.session?.puzzle)
        app.submit(try XCTUnwrap(board.regions.indices.first { !board.solution.contains($0) }))
        let lost = app.session
        app.revive()
        let request = try XCTUnwrap(rewards.requests.last)
        request.1(.interrupted)
        try await Task.sleep(nanoseconds: 30_000_000)
        let restored = model(dir, identity)
        XCTAssertEqual(restored.session, lost)
        XCTAssertEqual(restored.session?.status, .lost)
        XCTAssertEqual(restored.progress.bonusHints + restored.progress.bonusDirect, 0)
        XCTAssertEqual(restored.progress.rewardLedger[request.0]?.state, .cancelled)
        XCTAssertEqual(completions(restored).count, 1)
        XCTAssertEqual(completions(restored).first?.parameters["reward_granted"], .flag(false))
    }
    @MainActor func testQueueFailureAndLostAcknowledgementDoNotChangeReceiptEventOrRepeatReward() async throws {
        let dir = directory(), identity = ReceiptIdentity(), rewards = ReceiptRewards()
        let app = model(dir, identity, rewards: rewards)
        app.offer(.hint)
        let request = try XCTUnwrap(rewards.requests.last)
        request.1(.started)
        try await Task.sleep(nanoseconds: 30_000_000)
        let queue = dir.appendingPathComponent("analytics-demo-queue.json"), previous = try Data(contentsOf: queue)
        try FileManager.default.removeItem(at: queue)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: false)
        app.setActive(false)
        request.1(.earned); request.1(.earned)
        try await Task.sleep(nanoseconds: 30_000_000)
        let beforeAcknowledgement = app.progress
        let frozen = try JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self,
            from: XCTUnwrap(beforeAcknowledgement.rewardLedger[request.0]?.completionEvent))
        XCTAssertEqual(beforeAcknowledgement.rewardLedger[request.0]?.state, .executed)
        try FileManager.default.removeItem(at: queue)
        try previous.write(to: queue, options: .atomic)
        let recovered = model(dir, identity)
        let event = try XCTUnwrap(completions(recovered).first)
        XCTAssertEqual(event.eventID, frozen.event.eventID)
        XCTAssertEqual(event.eventTime, frozen.event.eventTime)
        XCTAssertEqual(event.sessionID, frozen.event.sessionID)
        XCTAssertEqual(event.parameters["reward_granted"], .flag(true))
        XCTAssertEqual(recovered.progress.bonusHints, 1)
        try store(recovered).save(beforeAcknowledgement)
        let again = model(dir, identity)
        XCTAssertEqual(completions(again).count, 1)
        XCTAssertEqual(again.progress.bonusHints, 1)
        XCTAssertNil(again.progress.rewardLedger[request.0]?.completionEvent)
    }
    @MainActor func testReceiptSaveFailureRetriesTheFirstFrozenCompletionWithoutPrematureSuccess() async throws {
        let dir = directory(), identity = ReceiptIdentity(), rewards = ReceiptRewards()
        let app = model(dir, identity, rewards: rewards)
        app.offer(.direct)
        let request = try XCTUnwrap(rewards.requests.last)
        let primary = dir.appendingPathComponent("progress.json"), previous = try Data(contentsOf: primary)
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        request.1(.earned)
        try await Task.sleep(nanoseconds: 30_000_000)
        let originalCallbackHandledBy = Date()
        XCTAssertTrue(app.rewardRetryPending)
        XCTAssertTrue(completions(app).isEmpty)
        XCTAssertEqual(app.session?.found.count, 0)
        try FileManager.default.removeItem(at: primary)
        try previous.write(to: primary, options: .atomic)
        app.runReward()
        XCTAssertEqual(completions(app).count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(completions(app).first?.eventTime), originalCallbackHandledBy)
        XCTAssertEqual(app.session?.found.count, 1)
        XCTAssertFalse(app.rewardRetryPending)
        request.1(.earned)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(completions(app).count, 1)
        XCTAssertEqual(app.session?.found.count, 1)
    }
    @MainActor func testLegacyOrPreConsentReceiptDoesNotFabricateAnalytics() throws {
        let dir = directory(), identity = ReceiptIdentity(), app = model(dir, identity, consent: false)
        let store = try store(app), offer = UUID().uuidString
        XCTAssertTrue(try store.prepareReward(offerID: offer, kind: .hint, progress: &app.progress))
        XCTAssertTrue(try store.markRewardReceived(offerID: offer, progress: &app.progress))
        let restored = model(dir, identity)
        XCTAssertEqual(restored.progress.bonusHints, 1)
        XCTAssertTrue(completions(restored).isEmpty)
        XCTAssertFalse(restored.analytics.events.contains { $0.eventName == "ad_offer_shown" })
    }
    @MainActor func testProductionAsyncAcknowledgementSurvivesImmediateNavigationAndRelaunch() async throws {
        let dir = directory(), identity = ReceiptIdentity(), rewards = ReceiptRewards()
        let app = model(dir, identity, rewards: rewards, asyncSaves: true)
        app.offer(.direct)
        let request = try XCTUnwrap(rewards.requests.last)
        request.1(.started); request.1(.earned)
        try await Task.sleep(nanoseconds: 30_000_000)
        app.home(); app.start(level: 2); app.flushPendingSaves()
        try await Task.sleep(nanoseconds: 30_000_000)
        app.flushPendingSaves()
        let restored = model(dir, identity)
        XCTAssertEqual(completions(restored).count, 1)
        XCTAssertEqual(completions(restored).first?.levelID, 1)
        XCTAssertEqual(completions(restored).first?.parameters["offer_id"], .text(request.0))
        XCTAssertEqual(restored.progress.rewardLedger[request.0]?.state, .executed)
        XCTAssertNil(restored.progress.rewardLedger[request.0]?.completionEvent)
        XCTAssertEqual(restored.session?.puzzle.id, 2)
        XCTAssertEqual(restored.progress.bonusDirect, 0)
    }
}
