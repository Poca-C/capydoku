import XCTest
import CapydokuCore
@testable import Capydoku

private final class PresentationRewards: RewardProvider {
    var requests: [(id: String, signal: (RewardSignal) -> Void)] = []
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) { requests.append((offerID, completion)) }
}

private final class PresentationIdentity: AnalyticsIdentityStore {
    var identity: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { identity }
    func save(_ identity: AnalyticsIdentity) -> Bool { self.identity = identity; return true }
}

final class RewardPresentationTests: XCTestCase {
    @MainActor private func model(_ rewards: RewardProvider) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(saveDirectory: root, rewardProvider: rewards, runsTimer: false,
                           feedbackEnabled: false, analyticsIdentityStore: PresentationIdentity())
        app.consentAccepted()
        XCTAssertTrue(app.analytics.enabled)
        app.progress.tutorialCompleted = true
        app.config = DemoConfig(hintsPerLevel: 0)
        app.start(level: 1)
        return app
    }
    private func drain() async { try? await Task.sleep(nanoseconds: 30_000_000) }
    @MainActor private func results(_ app: AppModel, offer: String) -> [AnalyticsRecorder.Event] {
        app.analytics.events.filter { $0.eventName == "ad_result" && $0.parameters["offer_id"] == .text(offer) }
    }

    @MainActor func testReadyButFailedToPresentDoesNotInventStartedOrChangeGame() async throws {
        let rewards = PresentationRewards(), app = model(rewards)
        let before = app.session
        app.offer(.hint)
        let request = try XCTUnwrap(rewards.requests.first)
        XCTAssertTrue(results(app, offer: request.id).isEmpty)
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
        XCTAssertTrue(app.rewardBusy)
        XCTAssertEqual(app.analytics.events.filter { $0.eventName == "ad_offer_shown" }.count, 1)
        request.signal(.failed); await drain()
        XCTAssertEqual(results(app, offer: request.id).map { $0.parameters["status"] }, [.text("failed")])
        XCTAssertEqual(app.session, before)
        XCTAssertEqual(app.progress.availableHints, 0)
        XCTAssertEqual(app.progress.rewardLedger[request.id]?.state, .cancelled)
        XCTAssertFalse(app.rewardBusy)
    }

    @MainActor func testConfirmedStartedIsNonterminalAndDeduplicatedThroughBackgroundAndCompletion() async throws {
        let rewards = PresentationRewards(), app = model(rewards)
        let before = app.session
        app.offer(.hint)
        let request = try XCTUnwrap(rewards.requests.first)
        request.signal(.started); request.signal(.started); await drain()
        XCTAssertTrue(app.rewardBusy)
        XCTAssertEqual(app.sheet, .reward)
        XCTAssertEqual(app.session, before)
        XCTAssertEqual(app.progress.rewardLedger[request.id]?.state, .offered)
        XCTAssertEqual(results(app, offer: request.id).map { $0.parameters["status"] }, [.text("started")])
        XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.advertisement))
        app.setActive(false)
        request.signal(.started); await drain()
        XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.background))
        XCTAssertEqual(results(app, offer: request.id).count, 1)
        request.signal(.earned); request.signal(.earned); await drain()
        XCTAssertEqual(results(app, offer: request.id).map { $0.parameters["status"] }, [.text("started"), .text("completed")])
        XCTAssertEqual(results(app, offer: request.id).last?.parameters["reward_granted"], .flag(true))
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
        XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.background))
        XCTAssertNil(app.hint)
        app.setActive(true)
        XCTAssertNotNil(app.hint)
        XCTAssertEqual(app.progress.availableHints, 0)
        request.signal(.started); await drain()
        XCTAssertEqual(results(app, offer: request.id).count, 2)
        XCTAssertFalse(app.rewardBusy)
    }

    @MainActor func testLateStartedFromFailedOfferCannotMarkOrUnlockNewOffer() async throws {
        let rewards = PresentationRewards(), app = model(rewards)
        app.offer(.hint)
        let first = try XCTUnwrap(rewards.requests.first)
        first.signal(.failed); await drain()
        app.notice = nil
        app.offer(.hint)
        let second = try XCTUnwrap(rewards.requests.last)
        XCTAssertNotEqual(first.id, second.id)
        first.signal(.started); first.signal(.earned); await drain()
        XCTAssertTrue(app.rewardBusy)
        XCTAssertTrue(results(app, offer: second.id).isEmpty)
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
        XCTAssertEqual(app.progress.rewardLedger[second.id]?.state, .offered)
        second.signal(.started); second.signal(.cancelled); await drain()
        XCTAssertEqual(results(app, offer: second.id).map { $0.parameters["status"] }, [.text("started"), .text("skipped")])
        XCTAssertEqual(app.progress.availableHints, 0)
    }

    @MainActor func testDemoSuccessCancelAndFailureEmitOnlyObservedPresentationStates() async throws {
        for scenario in [RewardScenario.success, .cancel, .failure] {
            let app = model(MockRewardProvider(scenario: scenario))
            app.offer(.hint)
            let id = try XCTUnwrap(app.progress.rewardLedger.keys.first)
            try await Task.sleep(nanoseconds: 650_000_000)
            let statuses = results(app, offer: id).compactMap { $0.parameters["status"] }
            switch scenario {
            case .success: XCTAssertEqual(statuses, [.text("started"), .text("completed")])
            case .cancel: XCTAssertEqual(statuses, [.text("started"), .text("skipped")])
            case .failure: XCTAssertEqual(statuses, [.text("failed")])
            default: XCTFail("Unexpected fixture")
            }
            XCTAssertFalse(app.rewardBusy)
        }
    }
}
