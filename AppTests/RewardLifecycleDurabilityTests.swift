import XCTest
import CapydokuCore
@testable import Capydoku

private final class LifecycleIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}

private final class LifecycleRewards: RewardProvider {
    var analyticsMetadata = RewardAnalyticsMetadata(network: "fixture-network", adUnitID: "fixture-unit")
    var ready = true
    var loads: [(placement: RewardKind, callback: (RewardReadiness) -> Void)] = []
    var requests: [(id: String, signal: (RewardSignal) -> Void)] = []
    func preload(placement: RewardKind, completion: @escaping (RewardReadiness) -> Void) {
        loads.append((placement, completion))
        if ready { completion(.ready) }
    }
    func isReady(placement: RewardKind) -> Bool { ready }
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) {
        requests.append((offerID, completion))
    }
}

private final class UnconfiguredLifecycleRewards: RewardProvider {
    var requests: [(String, (RewardSignal) -> Void)] = []
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) {
        requests.append((offerID, completion))
    }
}

final class RewardLifecycleDurabilityTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reward-lifecycle-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor private func model(_ directory: URL, identity: LifecycleIdentity,
                                  rewards: RewardProvider? = nil, consent: Bool = true,
                                  asyncSaves: Bool = false, timeout: TimeInterval = 5) -> AppModel {
        let feedback = FeedbackPlayer(manifest: .silent, resourceResolver: { _ in nil },
                                      playerFactory: { _ in nil }, sessionControl: { _ in true }, observeSystem: false)
        let app = AppModel(saveDirectory: directory, rewardProvider: rewards, rewardTimeout: timeout,
                           runsTimer: asyncSaves, feedbackEnabled: false,
                           analyticsIdentityStore: identity, feedbackPlayer: feedback)
        if consent { app.consentAccepted() }
        app.config = DemoConfig(initialLives: 1, hintsPerLevel: 0, directPerLevel: 0)
        app.progress.tutorialCompleted = true
        if app.session == nil { app.start(level: 1) }
        app.notice = nil
        return app
    }

    private func drain() async throws { try await Task.sleep(nanoseconds: 40_000_000) }

    @MainActor private func ads(_ app: AppModel, offer: String, name: String? = nil) -> [AnalyticsRecorder.Event] {
        app.analytics.events.filter {
            ["ad_offer_shown", "ad_result"].contains($0.eventName) &&
                $0.parameters["offer_id"] == .text(offer) && (name == nil || $0.eventName == name)
        }
    }

    @MainActor private func results(_ app: AppModel, offer: String) -> [AnalyticsRecorder.Event] {
        ads(app, offer: offer, name: "ad_result")
    }

    private func decode(_ data: Data?) throws -> AnalyticsRecorder.PreparedEvent {
        try JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: XCTUnwrap(data))
    }

    private func pending(_ record: RewardRecord) throws -> [AnalyticsRecorder.PreparedEvent] {
        try record.pendingAdEvents.values.map { try decode($0) }
    }

    // Read the real saved ledger without SaveStore.load(), whose intentional cold
    // recovery would cancel an offered record and change the scenario under test.
    private func savedRecord(_ directory: URL, offer: String) throws -> RewardRecord {
        struct Envelope: Decodable { let payload: Data }
        struct Ledger: Decodable { let rewardLedger: [String: RewardRecord] }
        let envelope = try JSONDecoder().decode(Envelope.self,
            from: Data(contentsOf: directory.appendingPathComponent("progress.json")))
        let ledger = try JSONDecoder().decode(Ledger.self, from: envelope.payload)
        return try XCTUnwrap(ledger.rewardLedger[offer])
    }

    @MainActor private func store(_ app: AppModel) throws -> SaveStore {
        let puzzle = try XCTUnwrap(app.session?.puzzle)
        return SaveStore(directory: app.saveDirectory, packagedPuzzle: { $0 == puzzle.id ? puzzle : nil })
    }

    private func block(_ url: URL) throws -> Data {
        let previous = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return previous
    }

    private func unblock(_ url: URL, restoring data: Data) throws {
        try FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
    }

    private func assertSameEvent(_ actual: AnalyticsRecorder.Event, _ original: AnalyticsRecorder.Event,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.eventID, original.eventID, file: file, line: line)
        XCTAssertEqual(actual.eventName, original.eventName, file: file, line: line)
        XCTAssertEqual(actual.eventTime, original.eventTime, file: file, line: line)
        XCTAssertEqual(actual.userID, original.userID, file: file, line: line)
        XCTAssertEqual(actual.sessionID, original.sessionID, file: file, line: line)
        XCTAssertEqual(actual.levelID, original.levelID, file: file, line: line)
        XCTAssertEqual(actual.pawdokuConfigVersion, original.pawdokuConfigVersion, file: file, line: line)
        XCTAssertEqual(actual.parameters, original.parameters, file: file, line: line)
        XCTAssertEqual(actual.environment, original.environment, file: file, line: line)
        XCTAssertEqual(actual.platform, original.platform, file: file, line: line)
        XCTAssertEqual(actual.appVersion, original.appVersion, file: file, line: line)
        XCTAssertEqual(actual.country, original.country, file: file, line: line)
        XCTAssertEqual(actual.installDate, original.installDate, file: file, line: line)
    }

    @MainActor func testOfferQueueFailureColdRecoveryOnlyReplaysOriginalOfferWithoutInventingOutcome() throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = LifecycleRewards()
        let app = model(directory, identity: identity, rewards: rewards)
        let queue = directory.appendingPathComponent("analytics-demo-queue.json"), oldQueue = try block(queue)
        app.offer(.hint)
        let request = try XCTUnwrap(rewards.requests.first)
        let durable = try savedRecord(directory, offer: request.id)
        let offer = try decode(durable.analyticsOffer)
        XCTAssertTrue(durable.analyticsOfferPending)
        XCTAssertEqual(durable.state, .offered)
        XCTAssertTrue(durable.pendingAdEvents.isEmpty)
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
        let beforeAcknowledgement = app.progress
        try unblock(queue, restoring: oldQueue)
        let recoveredRewards = LifecycleRewards()
        let recovered = model(directory, identity: identity, rewards: recoveredRewards)
        XCTAssertEqual(recovered.screen, .home)
        XCTAssertTrue(recoveredRewards.requests.isEmpty)
        XCTAssertEqual(ads(recovered, offer: request.id).count, 1)
        assertSameEvent(try XCTUnwrap(ads(recovered, offer: request.id).first), offer.event)
        XCTAssertTrue(results(recovered, offer: request.id).isEmpty)
        XCTAssertEqual(recovered.progress.rewardLedger[request.id]?.state, .cancelled)
        XCTAssertEqual(recovered.progress.rewardLedger[request.id]?.analyticsOfferPending, false)
        XCTAssertEqual(recovered.progress.bonusHints + recovered.progress.bonusDirect, 0)
        try store(recovered).save(beforeAcknowledgement)
        let again = model(directory, identity: identity)
        XCTAssertEqual(ads(again, offer: request.id).count, 1)
        assertSameEvent(try XCTUnwrap(ads(again, offer: request.id).first), offer.event)
        XCTAssertTrue(results(again, offer: request.id).isEmpty)
    }

    @MainActor func testStartedQueueFailureSurvivesColdRecoveryWithoutSyntheticTerminalOrReward() async throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = LifecycleRewards()
        let app = model(directory, identity: identity, rewards: rewards)
        app.offer(.hint)
        let request = try XCTUnwrap(rewards.requests.first)
        let queue = directory.appendingPathComponent("analytics-demo-queue.json"), oldQueue = try block(queue)
        request.signal(.started); request.signal(.started)
        try await drain()
        let durable = try savedRecord(directory, offer: request.id)
        let original = try XCTUnwrap(try pending(durable).first)
        XCTAssertEqual(durable.pendingAdEvents.count, 1)
        XCTAssertEqual(original.event.parameters["status"], .text("started"))
        XCTAssertEqual(durable.state, .offered)
        XCTAssertTrue(app.rewardBusy)
        XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.advertisement))
        let beforeAcknowledgement = app.progress
        try unblock(queue, restoring: oldQueue)
        let recovered = model(directory, identity: identity)
        XCTAssertEqual(results(recovered, offer: request.id).count, 1)
        assertSameEvent(try XCTUnwrap(results(recovered, offer: request.id).first), original.event)
        XCTAssertEqual(recovered.progress.rewardLedger[request.id]?.state, .cancelled)
        XCTAssertEqual(recovered.progress.rewardLedger[request.id]?.pendingAdEvents.isEmpty, true)
        XCTAssertNil(recovered.progress.rewardLedger[request.id]?.completionEvent)
        XCTAssertEqual(recovered.progress.bonusHints + recovered.progress.bonusDirect, 0)
        try store(recovered).save(beforeAcknowledgement)
        let again = model(directory, identity: identity)
        XCTAssertEqual(results(again, offer: request.id).count, 1)
        assertSameEvent(try XCTUnwrap(results(again, offer: request.id).first), original.event)
    }

    @MainActor private func assertTerminalQueueRecovery(signal: RewardSignal?) async throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = LifecycleRewards()
        rewards.ready = signal != nil
        let app = model(directory, identity: identity, rewards: rewards, timeout: 0.03)
        let board = app.session
        let queue = directory.appendingPathComponent("analytics-demo-queue.json"), oldQueue = try block(queue)
        app.offer(.hint)
        let offerID = try XCTUnwrap(app.progress.rewardLedger.keys.first)
        if let signal {
            let request = try XCTUnwrap(rewards.requests.first)
            if signal == .cancelled { request.signal(.started) }
            request.signal(signal); request.signal(signal)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let durable = try savedRecord(directory, offer: offerID)
        let frozen = try pending(durable), offer = try decode(durable.analyticsOffer)
        let expected = signal == .cancelled ? "skipped" : "failed"
        XCTAssertEqual(durable.state, .cancelled)
        XCTAssertTrue(durable.analyticsOfferPending)
        XCTAssertEqual(frozen.filter { $0.event.parameters["status"] == .text(expected) }.count, 1)
        XCTAssertEqual(frozen.count, signal == .cancelled ? 2 : 1)
        let terminal = try XCTUnwrap(frozen.first { $0.event.parameters["status"] == .text(expected) })
        XCTAssertEqual(terminal.event.parameters["error_code"],
                       .text(signal == .cancelled ? "" : signal == nil ? "loading_timeout" : "presentation_failed"))
        XCTAssertNil(durable.completionEvent)
        XCTAssertEqual(app.session, board)
        XCTAssertEqual(app.progress.availableHints, 0)
        XCTAssertFalse(app.rewardBusy)
        XCTAssertFalse(app.rewardRetryPending)
        if signal == nil { XCTAssertTrue(rewards.requests.isEmpty, "Loading timeout must not invent presentation.") }
        let beforeAcknowledgement = app.progress
        try unblock(queue, restoring: oldQueue)
        let recovered = model(directory, identity: identity)
        XCTAssertEqual(ads(recovered, offer: offerID, name: "ad_offer_shown").count, 1)
        assertSameEvent(try XCTUnwrap(ads(recovered, offer: offerID, name: "ad_offer_shown").first), offer.event)
        XCTAssertEqual(results(recovered, offer: offerID).count, frozen.count)
        for original in frozen {
            let actual = try XCTUnwrap(results(recovered, offer: offerID).first { $0.eventID == original.event.eventID })
            assertSameEvent(actual, original.event)
            XCTAssertEqual(actual.parameters["reward_granted"], .flag(false))
        }
        XCTAssertEqual(recovered.progress.rewardLedger[offerID]?.pendingAdEvents.isEmpty, true)
        XCTAssertEqual(recovered.progress.rewardLedger[offerID]?.analyticsOfferPending, false)
        try store(recovered).save(beforeAcknowledgement)
        let again = model(directory, identity: identity)
        XCTAssertEqual(results(again, offer: offerID).count, frozen.count)
        XCTAssertEqual(Set(results(again, offer: offerID).map(\.eventID)), Set(frozen.map { $0.event.eventID }))
        XCTAssertEqual(again.progress.bonusHints + again.progress.bonusDirect, 0)
        XCTAssertEqual(again.session, board)
    }

    @MainActor func testSkippedQueueFailureAndLostAcknowledgementReplayOriginalLifecycle() async throws {
        try await assertTerminalQueueRecovery(signal: .cancelled)
    }

    @MainActor func testFailureQueueFailureAndLostAcknowledgementReplayOriginalFailureWithoutStarted() async throws {
        try await assertTerminalQueueRecovery(signal: .failed)
    }

    @MainActor func testLoadingTimeoutQueueFailureAndLostAcknowledgementNeverInventPresentation() async throws {
        try await assertTerminalQueueRecovery(signal: nil)
    }

    @MainActor func testStartedProgressFailureKeepsVideoActiveThenEarnedPersistsOriginalStartedAndCompletion() async throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = LifecycleRewards()
        let app = model(directory, identity: identity, rewards: rewards)
        app.offer(.direct)
        let request = try XCTUnwrap(rewards.requests.first)
        let primary = directory.appendingPathComponent("progress.json"), oldProgress = try block(primary)
        request.signal(.started); request.signal(.started)
        try await drain()
        let firstCallbackHandledBy = Date()
        XCTAssertNotNil(app.rewardRecordingError)
        XCTAssertTrue(app.rewardBusy)
        XCTAssertFalse(app.rewardRetryPending)
        XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.advertisement))
        XCTAssertTrue(results(app, offer: request.id).isEmpty)
        XCTAssertEqual(app.session?.found.count, 0)
        let queue = directory.appendingPathComponent("analytics-demo-queue.json"), oldQueue = try block(queue)
        try unblock(primary, restoring: oldProgress)
        request.signal(.earned); request.signal(.earned)
        try await drain()
        let durable = try savedRecord(directory, offer: request.id)
        let started = try XCTUnwrap(try pending(durable).first)
        let completed = try decode(durable.completionEvent)
        XCTAssertEqual(durable.state, .executed)
        XCTAssertEqual(durable.pendingAdEvents.count, 1)
        XCTAssertEqual(started.event.parameters["status"], .text("started"))
        XCTAssertLessThanOrEqual(started.event.eventTime, firstCallbackHandledBy)
        XCTAssertEqual(app.session?.found.count, 1)
        XCTAssertNil(app.rewardRecordingError)
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
        try unblock(queue, restoring: oldQueue)
        let recovered = model(directory, identity: identity)
        let recoveredResults = results(recovered, offer: request.id)
        XCTAssertEqual(recoveredResults.map { $0.parameters["status"] }, [.text("started"), .text("completed")])
        assertSameEvent(try XCTUnwrap(recoveredResults.first), started.event)
        var granted = completed.event
        granted.parameters["reward_granted"] = .flag(true)
        assertSameEvent(try XCTUnwrap(recoveredResults.last), granted)
        XCTAssertEqual(recovered.session?.found.count, 1)
        XCTAssertEqual(recovered.progress.bonusDirect, 0)
    }

    @MainActor func testStartedProgressFailureBackgroundSaveRetriesSameOccurrenceWithoutReplayingVideo() async throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = LifecycleRewards()
        let app = model(directory, identity: identity, rewards: rewards)
        app.offer(.hint)
        let request = try XCTUnwrap(rewards.requests.first)
        let primary = directory.appendingPathComponent("progress.json"), oldProgress = try block(primary)
        request.signal(.started)
        try await drain()
        let firstCallbackHandledBy = Date()
        XCTAssertNotNil(app.rewardRecordingError)
        app.setActive(false)
        XCTAssertNotNil(app.rewardRecordingError)
        XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.advertisement))
        try unblock(primary, restoring: oldProgress)
        app.setActive(true)
        XCTAssertNil(app.rewardRecordingError, "Foreground must retry the observed fact without another callback.")
        XCTAssertEqual(results(app, offer: request.id).count, 1)
        app.save(force: true)
        let started = try XCTUnwrap(results(app, offer: request.id).first)
        XCTAssertEqual(started.parameters["status"], .text("started"))
        XCTAssertLessThanOrEqual(started.eventTime, firstCallbackHandledBy)
        XCTAssertNil(app.rewardRecordingError)
        XCTAssertEqual(rewards.requests.count, 1)
        XCTAssertTrue(app.rewardBusy)
        request.signal(.started); try await drain()
        XCTAssertEqual(results(app, offer: request.id).count, 1)
        let recovered = model(directory, identity: identity)
        XCTAssertEqual(results(recovered, offer: request.id).count, 1)
        assertSameEvent(try XCTUnwrap(results(recovered, offer: request.id).first), started)
        XCTAssertEqual(recovered.progress.rewardLedger[request.id]?.state, .cancelled)
    }

    @MainActor func testTerminalProgressFailureRetriesFirstResultWithoutNewRequestOrContradictoryReward() async throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = LifecycleRewards()
        let app = model(directory, identity: identity, rewards: rewards)
        app.offer(.hint)
        let request = try XCTUnwrap(rewards.requests.first)
        request.signal(.started); try await drain()
        let primary = directory.appendingPathComponent("progress.json"), oldProgress = try block(primary)
        request.signal(.cancelled); try await drain()
        let firstTerminalHandledBy = Date()
        XCTAssertTrue(app.rewardRetryPending)
        XCTAssertNotNil(app.errorMessage)
        XCTAssertEqual(app.sheet, .reward)
        XCTAssertEqual(app.progress.rewardLedger[request.id]?.state, .offered)
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
        XCTAssertEqual(results(app, offer: request.id).map { $0.parameters["status"] }, [.text("started")])
        request.signal(.earned); request.signal(.failed); request.signal(.started)
        try await drain()
        XCTAssertEqual(app.progress.availableHints, 0)
        XCTAssertNil(app.hint)
        try unblock(primary, restoring: oldProgress)
        app.setActive(false); app.setActive(true); app.save(force: true)
        XCTAssertTrue(app.rewardRetryPending)
        XCTAssertEqual(try savedRecord(directory, offer: request.id).state, .offered)
        XCTAssertTrue(try savedRecord(directory, offer: request.id).pendingAdEvents.isEmpty)
        XCTAssertEqual(results(app, offer: request.id).map { $0.parameters["status"] }, [.text("started")],
                       "Ordinary/background saves must not publish half of a failed terminal transaction.")
        let loadCount = rewards.loads.count
        app.runReward(); app.runReward()
        XCTAssertEqual(rewards.requests.count, 1)
        XCTAssertEqual(rewards.loads.count, loadCount)
        XCTAssertFalse(app.rewardRetryPending)
        XCTAssertEqual(app.progress.rewardLedger[request.id]?.state, .cancelled)
        let events = results(app, offer: request.id)
        XCTAssertEqual(events.map { $0.parameters["status"] }, [.text("started"), .text("skipped")])
        XCTAssertLessThanOrEqual(try XCTUnwrap(events.last?.eventTime), firstTerminalHandledBy)
        XCTAssertEqual(app.progress.availableHints, 0)
        request.signal(.earned); request.signal(.cancelled); try await drain()
        XCTAssertEqual(results(app, offer: request.id).count, 2)
        let recovered = model(directory, identity: identity)
        XCTAssertEqual(results(recovered, offer: request.id).count, 2)
        XCTAssertEqual(recovered.progress.availableHints, 0)
    }

    @MainActor func testResultAttributionRemainsWithOriginalOfferAcrossSessionLevelKindAndProviderChanges() async throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = LifecycleRewards()
        let app = model(directory, identity: identity, rewards: rewards)
        app.offer(.hint)
        let request = try XCTUnwrap(rewards.requests.first)
        let offer = try decode(app.progress.rewardLedger[request.id]?.analyticsOffer).event
        app.analytics.endSession(reason: "quit")
        app.analytics.beginSession(source: "resume")
        app.rewardKind = .direct
        rewards.analyticsMetadata = .init(network: "changed-network", adUnitID: "changed-unit")
        let queue = directory.appendingPathComponent("analytics-demo-queue.json"), oldQueue = try block(queue)
        request.signal(.started); request.signal(.failed); try await drain()
        XCTAssertNotEqual(offer.sessionID, app.analytics.events.last { $0.eventName == "session_start" }?.sessionID)
        XCTAssertEqual(app.session?.puzzle.id, 1)
        let durable = try savedRecord(directory, offer: request.id)
        let frozen = try pending(durable)
        XCTAssertEqual(durable.state, .cancelled)
        XCTAssertEqual(frozen.count, 2)
        XCTAssertEqual(frozen.filter { $0.event.parameters["status"] == .text("started") }.count, 1)
        XCTAssertEqual(frozen.filter { $0.event.parameters["status"] == .text("failed") }.count, 1)
        // Starting another board intentionally cancels an unresolved offered
        // record. Change levels only after observing the real terminal result;
        // delivery is still blocked so cold recovery must use its frozen origin.
        app.config = DemoConfig(version: "later-demo-config", hintsPerLevel: 0, directPerLevel: 0)
        app.start(level: 2)
        XCTAssertEqual(app.session?.puzzle.id, 2)
        XCTAssertNotEqual(app.session?.config.version, offer.pawdokuConfigVersion)
        try unblock(queue, restoring: oldQueue)
        let recovered = model(directory, identity: identity, consent: false)
        XCTAssertEqual(recovered.session?.puzzle.id, 2)
        XCTAssertNotEqual(recovered.session?.config.version, offer.pawdokuConfigVersion)
        recovered.consentAccepted()
        let events = results(recovered, offer: request.id)
        XCTAssertEqual(events.map { $0.parameters["status"] }, [.text("started"), .text("failed")])
        for original in frozen {
            assertSameEvent(try XCTUnwrap(events.first { $0.eventID == original.event.eventID }), original.event)
        }
        for event in events {
            XCTAssertEqual(event.sessionID, offer.sessionID)
            XCTAssertEqual(event.userID, offer.userID)
            XCTAssertEqual(event.levelID, offer.levelID)
            XCTAssertEqual(event.pawdokuConfigVersion, offer.pawdokuConfigVersion)
            XCTAssertEqual(event.parameters["placement_id"], offer.parameters["placement_id"])
            XCTAssertEqual(event.parameters["network"], offer.parameters["network"])
            XCTAssertEqual(event.parameters["ad_unit_id"], offer.parameters["ad_unit_id"])
            XCTAssertEqual(event.parameters["reward_granted"], .flag(false))
        }
        XCTAssertEqual(offer.parameters["placement_id"], .text("hint"))
        XCTAssertEqual(offer.parameters["network"], .text("fixture-network"))
        XCTAssertEqual(offer.parameters["ad_unit_id"], .text("fixture-unit"))
    }

    @MainActor func testPreConsentAndLegacyOffersNeverInventLifecycleWhenConsentArrivesLater() async throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = LifecycleRewards()
        let app = model(directory, identity: identity, rewards: rewards, consent: false)
        app.offer(.hint)
        let request = try XCTUnwrap(rewards.requests.first)
        XCTAssertNil(app.progress.rewardLedger[request.id]?.analyticsOffer)
        request.signal(.started); try await drain()
        app.consentAccepted()
        request.signal(.cancelled); try await drain()
        XCTAssertTrue(ads(app, offer: request.id).isEmpty)
        XCTAssertEqual(app.progress.rewardLedger[request.id]?.pendingAdEvents.isEmpty, true)
        XCTAssertEqual(app.progress.rewardLedger[request.id]?.analyticsOfferPending, false)
        let legacyID = UUID().uuidString
        XCTAssertTrue(try store(app).prepareReward(offerID: legacyID, kind: .hint, progress: &app.progress))
        let recovered = model(directory, identity: identity)
        XCTAssertEqual(recovered.progress.rewardLedger[legacyID]?.state, .cancelled)
        XCTAssertTrue(ads(recovered, offer: request.id).isEmpty)
        XCTAssertTrue(ads(recovered, offer: legacyID).isEmpty)
        XCTAssertEqual(recovered.progress.bonusHints + recovered.progress.bonusDirect, 0)
    }

    @MainActor func testProductionAsyncOldSavesCannotOverwriteTerminalOrResurrectPendingEvents() async throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = LifecycleRewards()
        let app = model(directory, identity: identity, rewards: rewards, asyncSaves: true)
        app.offer(.hint)
        let request = try XCTUnwrap(rewards.requests.first)
        app.save(); app.save()
        request.signal(.started); try await drain()
        app.save(); app.save()
        request.signal(.cancelled); request.signal(.earned); try await drain()
        let original = results(app, offer: request.id)
        XCTAssertEqual(original.map { $0.parameters["status"] }, [.text("started"), .text("skipped")])
        app.notice = nil
        app.home(); app.start(level: 2); app.flushPendingSaves()
        try await drain()
        app.flushPendingSaves()
        let recovered = model(directory, identity: identity)
        XCTAssertEqual(recovered.session?.puzzle.id, 2)
        XCTAssertEqual(recovered.progress.rewardLedger[request.id]?.state, .cancelled)
        XCTAssertEqual(recovered.progress.rewardLedger[request.id]?.analyticsOfferPending, false)
        XCTAssertEqual(recovered.progress.rewardLedger[request.id]?.pendingAdEvents.isEmpty, true)
        XCTAssertNil(recovered.progress.rewardLedger[request.id]?.completionEvent)
        XCTAssertEqual(results(recovered, offer: request.id).count, 2)
        for event in original {
            assertSameEvent(try XCTUnwrap(results(recovered, offer: request.id).first { $0.eventID == event.eventID }), event)
        }
        XCTAssertEqual(recovered.progress.bonusHints + recovered.progress.bonusDirect, 0)
        XCTAssertEqual(rewards.requests.count, 1)
    }

    @MainActor func testOldAndRepeatedCallbacksCannotAffectNewOfferOrItsAudioOwnership() async throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = LifecycleRewards()
        let app = model(directory, identity: identity, rewards: rewards)
        app.offer(.hint)
        let first = try XCTUnwrap(rewards.requests.first)
        first.signal(.failed); try await drain()
        app.notice = nil
        app.offer(.hint); app.runReward(); app.offer(.hint)
        let second = try XCTUnwrap(rewards.requests.last)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(rewards.requests.count, 2)
        first.signal(.started); first.signal(.earned); first.signal(.cancelled)
        try await drain()
        XCTAssertTrue(app.rewardBusy)
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
        XCTAssertTrue(results(app, offer: second.id).isEmpty)
        XCTAssertEqual(app.progress.rewardLedger[second.id]?.state, .offered)
        second.signal(.started); second.signal(.started); try await drain()
        first.signal(.failed); try await drain()
        XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.advertisement))
        XCTAssertEqual(results(app, offer: second.id).map { $0.parameters["status"] }, [.text("started")])
        second.signal(.cancelled); second.signal(.earned); try await drain()
        XCTAssertEqual(results(app, offer: first.id).map { $0.parameters["status"] }, [.text("failed")])
        XCTAssertEqual(results(app, offer: second.id).map { $0.parameters["status"] }, [.text("started"), .text("skipped")])
        XCTAssertEqual(app.progress.availableHints, 0)
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
    }

    @MainActor func testStartedWriteFailureMergesIntoDurableReceiptBeforeColdCompensation() async throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = LifecycleRewards()
        let app = model(directory, identity: identity, rewards: rewards)
        let board = app.session
        app.offer(.direct)
        let request = try XCTUnwrap(rewards.requests.first)
        let primary = directory.appendingPathComponent("progress.json"), oldProgress = try block(primary)
        request.signal(.started); try await drain()
        let firstCallbackHandledBy = Date()
        XCTAssertNotNil(app.rewardRecordingError)
        let queue = directory.appendingPathComponent("analytics-demo-queue.json"), oldQueue = try block(queue)
        try unblock(primary, restoring: oldProgress)
        request.signal(.interrupted); try await drain()
        // .interrupted stops after the real receipt write, before any direct
        // effect, compensation, or completed-event delivery has occurred.
        let receipt = try savedRecord(directory, offer: request.id)
        let started = try XCTUnwrap(try pending(receipt).first)
        let completed = try decode(receipt.completionEvent)
        XCTAssertEqual(receipt.state, .rewarded)
        XCTAssertEqual(receipt.pendingAdEvents.count, 1)
        XCTAssertLessThanOrEqual(started.event.eventTime, firstCallbackHandledBy)
        XCTAssertEqual(app.session, board)
        XCTAssertEqual(app.progress.bonusDirect, 0)
        XCTAssertFalse(results(app, offer: request.id).contains { $0.parameters["status"] == .text("completed") })
        try unblock(queue, restoring: oldQueue)
        let recovered = model(directory, identity: identity)
        XCTAssertEqual(recovered.progress.rewardLedger[request.id]?.state, .compensated)
        XCTAssertEqual(recovered.progress.bonusDirect, 1)
        XCTAssertEqual(recovered.session, board)
        let events = results(recovered, offer: request.id)
        XCTAssertEqual(events.map { $0.parameters["status"] }, [.text("started"), .text("completed")])
        assertSameEvent(try XCTUnwrap(events.first), started.event)
        var granted = completed.event
        granted.parameters["reward_granted"] = .flag(true)
        assertSameEvent(try XCTUnwrap(events.last), granted)
        let again = model(directory, identity: identity)
        XCTAssertEqual(again.progress.bonusDirect, 1)
        XCTAssertEqual(results(again, offer: request.id).count, 2)
    }

    @MainActor func testProviderWithoutMetadataStaysUnconfiguredWhileMockDeclaresSimulation() async throws {
        let directory = directory(), identity = LifecycleIdentity(), rewards = UnconfiguredLifecycleRewards()
        let app = model(directory, identity: identity, rewards: rewards)
        app.offer(.hint)
        let request = try XCTUnwrap(rewards.requests.first)
        request.1(.failed); try await drain()
        XCTAssertEqual(ads(app, offer: request.0).count, 2)
        for event in ads(app, offer: request.0) {
            XCTAssertEqual(event.parameters["network"], .text("unconfigured"))
            XCTAssertEqual(event.parameters["ad_unit_id"], .text("unconfigured"))
            XCTAssertEqual(event.parameters["ad_type"], .text("rewarded"))
        }
        XCTAssertEqual(MockRewardProvider(scenario: .success).analyticsMetadata.network, "simulation")
        XCTAssertEqual(MockRewardProvider(scenario: .success).analyticsMetadata.adUnitID, "internal-demo")
    }
}
