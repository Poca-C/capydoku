import XCTest
import CapydokuCore
@testable import Capydoku

private final class InterstitialTestIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}

private final class ControlledAnalyticsInterstitial: InterstitialProvider {
    var isReady: Bool
    var loads: [(RewardReadiness) -> Void] = []
    var displays: [(InterstitialSignal) -> Void] = []
    var analyticsMetadata = InterstitialAnalyticsMetadata(
        placementID: "demo_interstitial_win_v1", network: "controlled-test", adUnitID: "controlled-unit")
    init(ready: Bool = true) { isReady = ready }
    func load(completion: @escaping (RewardReadiness) -> Void) { loads.append(completion) }
    func present(completion: @escaping (InterstitialSignal) -> Void) { displays.append(completion) }
}

private final class DefaultMetadataInterstitial: InterstitialProvider {
    var displays: [(InterstitialSignal) -> Void] = []
    func present(completion: @escaping (InterstitialSignal) -> Void) { displays.append(completion) }
}

/// Read-only view of the durable outbox. The tests never synthesize a completion
/// or rewrite only part of the private win-ad state; lost acknowledgement uses
/// the exact complete on-disk envelope captured before successful delivery.
private struct InterstitialPendingSnapshot: Codable {
    var pendingEvents: [AnalyticsRecorder.PreparedEvent]?
    var shown: Set<UUID>?
    var eligibleCount: Int?
    var lastShownAt: Date?
}

final class InterstitialAnalyticsTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("interstitial-analytics-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func drain() async { try? await Task.sleep(nanoseconds: 40_000_000) }

    @MainActor private func model(_ directory: URL, identity: InterstitialTestIdentity,
                                  provider: InterstitialProvider, consent: Bool = true, asyncSaves: Bool = false) -> AppModel {
        let feedback = FeedbackPlayer(manifest: .silent, resourceResolver: { _ in nil },
                                      playerFactory: { _ in nil }, sessionControl: { _ in true }, observeSystem: false)
        let app = AppModel(saveDirectory: directory, runsTimer: asyncSaves, feedbackEnabled: false,
                           interstitialProvider: provider, analyticsIdentityStore: identity, feedbackPlayer: feedback)
        if consent { app.consentAccepted() }
        app.notice = nil
        return app
    }

    @MainActor private func winning(_ directory: URL, identity: InterstitialTestIdentity,
                                    provider: InterstitialProvider, level: Int = 2, consent: Bool = true,
                                    asyncSaves: Bool = false,
                                    configure: ((inout ReferenceLevelGameplay) -> Void)? = nil) throws -> AppModel {
        let app = model(directory, identity: identity, provider: provider, consent: consent, asyncSaves: asyncSaves)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
        var row = try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: url))
        row.adsEnabled = true
        row.interstitial.enabled = true
        row.interstitial.startLevel = 1
        row.interstitial.frequency = 1
        row.interstitial.cooldownSeconds = 0
        row.interstitial.onNextLevel = true
        row.interstitial.onReturnHome = true
        row.interstitial.adTimeoutSeconds = 1
        configure?(&row)
        app.config = DemoConfig(referenceGameplay: row)
        app.progress.tutorialCompleted = true
        app.start(level: level)
        try win(app)
        return app
    }

    @MainActor private func win(_ app: AppModel) throws {
        for cell in try XCTUnwrap(app.session).puzzle.solution { app.submit(cell) }
        XCTAssertEqual(app.session?.status, .won)
    }
    @MainActor private func adEvents(_ app: AppModel, _ name: String? = nil) -> [AnalyticsRecorder.Event] {
        app.analytics.events.filter {
            $0.parameters["ad_type"] == .text("interstitial") && (name == nil || $0.eventName == name)
        }
    }
    @MainActor private func offer(_ app: AppModel, index: Int = 0) throws -> AnalyticsRecorder.Event {
        let offers = adEvents(app, "ad_offer_shown")
        return try XCTUnwrap(offers.indices.contains(index) ? offers[index] : nil)
    }
    @MainActor private func results(_ app: AppModel, for offered: AnalyticsRecorder.Event) -> [AnalyticsRecorder.Event] {
        adEvents(app, "ad_result").filter { $0.parameters["offer_id"] == offered.parameters["offer_id"] }
    }
    @MainActor private func statuses(_ app: AppModel, for offered: AnalyticsRecorder.Event) -> [AnalyticsRecorder.Value] {
        results(app, for: offered).compactMap { $0.parameters["status"] }
    }
    @MainActor private func assertNoRewards(_ app: AppModel, hints: Int = 0, direct: Int = 0,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.progress.bonusHints, hints, file: file, line: line)
        XCTAssertEqual(app.progress.bonusDirect, direct, file: file, line: line)
        XCTAssertTrue(app.progress.rewardLedger.isEmpty, file: file, line: line)
        for event in adEvents(app, "ad_offer_shown") {
            XCTAssertEqual(event.parameters["reward_amount"], .integer(0), file: file, line: line)
            XCTAssertEqual(event.parameters["reward_type"], .text(""), file: file, line: line)
            XCTAssertEqual(event.parameters["buff_type"], .text(""), file: file, line: line)
        }
        for event in adEvents(app, "ad_result") {
            XCTAssertEqual(event.parameters["reward_granted"], .flag(false), file: file, line: line)
        }
        XCTAssertFalse(app.analytics.events.contains { $0.eventName == "buff_use" }, file: file, line: line)
    }
    @MainActor private func pending(_ directory: URL) throws -> [AnalyticsRecorder.PreparedEvent] {
        try savedState(directory).pendingEvents ?? []
    }
    @MainActor private func savedState(_ directory: URL) throws -> InterstitialPendingSnapshot {
        let value = try DurableStateFile<InterstitialPendingSnapshot>(url: directory.appendingPathComponent("win-ad-state.json")).load()
        return try XCTUnwrap(value)
    }
    @MainActor private func assertSameEvent(_ actual: AnalyticsRecorder.Event, _ frozen: AnalyticsRecorder.Event,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.eventID, frozen.eventID, file: file, line: line)
        XCTAssertEqual(actual.eventTime, frozen.eventTime, file: file, line: line)
        XCTAssertEqual(actual.userID, frozen.userID, file: file, line: line)
        XCTAssertEqual(actual.sessionID, frozen.sessionID, file: file, line: line)
        XCTAssertEqual(actual.levelID, frozen.levelID, file: file, line: line)
        XCTAssertEqual(actual.pawdokuConfigVersion, frozen.pawdokuConfigVersion, file: file, line: line)
        XCTAssertEqual(actual.parameters, frozen.parameters, file: file, line: line)
    }

    @MainActor func testOnlyConfirmedPresentationStartsAudioBlockAndFrozenOfferIsIdempotent() async throws {
        let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
        let app = try winning(directory, identity: identity, provider: provider)
        let won = try XCTUnwrap(app.session)
        app.next(); app.next(); app.home()
        XCTAssertEqual(provider.loads.count, 1)
        XCTAssertEqual(provider.displays.count, 1)
        XCTAssertTrue(app.interstitialBusy)
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
        let offered = try offer(app)
        XCTAssertEqual(adEvents(app, "ad_offer_shown").count, 1)
        XCTAssertTrue(results(app, for: offered).isEmpty)
        XCTAssertEqual(offered.levelID, 2)
        XCTAssertEqual(offered.pawdokuConfigVersion, won.config.version)
        XCTAssertEqual(offered.parameters["placement_id"], .text("demo_interstitial_win_v1"))
        provider.analyticsMetadata = .init(placementID: "changed-after-request", network: "changed", adUnitID: "changed")
        provider.displays[0](.started); provider.displays[0](.started)
        await drain()
        XCTAssertEqual(statuses(app, for: offered), [.text("started")])
        XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.advertisement))
        XCTAssertEqual(app.session, won)
        provider.displays[0](.closed); provider.displays[0](.closed); provider.displays[0](.failed)
        await drain()
        XCTAssertEqual(statuses(app, for: offered), [.text("started"), .text("completed")])
        XCTAssertEqual(app.session?.puzzle.id, 3)
        XCTAssertFalse(app.interstitialBusy)
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
        for result in results(app, for: offered) {
            XCTAssertEqual(result.sessionID, offered.sessionID)
            XCTAssertEqual(result.levelID, offered.levelID)
            XCTAssertEqual(result.pawdokuConfigVersion, offered.pawdokuConfigVersion)
            for key in ["placement_id", "network", "ad_unit_id"] { XCTAssertEqual(result.parameters[key], offered.parameters[key]) }
        }
        assertNoRewards(app)
    }

    @MainActor func testNoFillAndRealLoadingTimeoutNeverInventPresentation() async throws {
        for timesOut in [false, true] {
            let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial(ready: false)
            let app = try winning(directory, identity: identity, provider: provider)
            app.next()
            let offered = try offer(app)
            XCTAssertTrue(provider.displays.isEmpty)
            XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
            if timesOut { try await Task.sleep(nanoseconds: 1_200_000_000) }
            else { provider.loads[0](.unavailable); await drain() }
            XCTAssertEqual(statuses(app, for: offered), [.text("failed")])
            XCTAssertEqual(app.session?.puzzle.id, 3)
            XCTAssertFalse(app.interstitialBusy)
            let nextSession = app.session
            provider.loads[0](.ready); provider.loads[0](.unavailable)
            await drain()
            XCTAssertTrue(provider.displays.isEmpty)
            XCTAssertEqual(app.session, nextSession)
            XCTAssertEqual(results(app, for: offered).count, 1)
            assertNoRewards(app)
        }
    }

    @MainActor func testPresentationFailureAndAdapterTimeoutAreTerminalWithoutInventedStarted() async throws {
        for signal in [InterstitialSignal.failed, .timedOut] {
            for didStart in [false, true] {
                let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
                let app = try winning(directory, identity: identity, provider: provider)
                app.next()
                let offered = try offer(app)
                if didStart { provider.displays[0](.started); await drain() }
                provider.displays[0](signal); provider.displays[0](signal); provider.displays[0](.started)
                await drain()
                XCTAssertEqual(statuses(app, for: offered), didStart ? [.text("started"), .text("failed")] : [.text("failed")])
                XCTAssertEqual(app.session?.puzzle.id, 3)
                XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
                XCTAssertFalse(app.interstitialBusy)
                assertNoRewards(app)
            }
        }
    }

    @MainActor func testOldSignalsCannotStartFinishOrUnlockTheNextOffer() async throws {
        let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
        let app = try winning(directory, identity: identity, provider: provider)
        app.next()
        let firstOffer = try offer(app), firstCallback = try XCTUnwrap(provider.displays.first)
        firstCallback(.failed); await drain()
        try win(app)
        app.next()
        let secondOffer = try offer(app, index: 1), current = app.session
        XCTAssertNotEqual(firstOffer.parameters["offer_id"], secondOffer.parameters["offer_id"])
        XCTAssertEqual(provider.displays.count, 2)
        firstCallback(.started); firstCallback(.closed); firstCallback(.skipped)
        await drain()
        XCTAssertEqual(statuses(app, for: firstOffer), [.text("failed")])
        XCTAssertTrue(results(app, for: secondOffer).isEmpty)
        XCTAssertEqual(app.session, current)
        XCTAssertTrue(app.interstitialBusy)
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
        provider.displays[1](.started); provider.displays[1](.closed)
        await drain()
        XCTAssertEqual(statuses(app, for: secondOffer), [.text("started"), .text("completed")])
        XCTAssertEqual(app.session?.puzzle.id, 4)
        assertNoRewards(app)
    }

    @MainActor func testTenthLevelAdEndsBeforeChallengeAndHomeDestinationIsPreserved() async throws {
        for toHome in [false, true] {
            let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
            let app = try winning(directory, identity: identity, provider: provider, level: 10)
            if toHome { app.home(); app.home() } else { app.next(); app.next() }
            let offered = try offer(app)
            XCTAssertEqual(provider.displays.count, 1)
            XCTAssertFalse(app.challengePending)
            XCTAssertEqual(app.session?.puzzle.id, 10)
            provider.displays[0](.started); provider.displays[0](.closed); provider.displays[0](.closed)
            await drain()
            XCTAssertEqual(statuses(app, for: offered), [.text("started"), .text("completed")])
            XCTAssertFalse(app.interstitialBusy)
            if toHome {
                XCTAssertEqual(app.screen, .home)
                XCTAssertFalse(app.challengePending)
                XCTAssertEqual(app.session?.puzzle.id, 10)
            } else {
                XCTAssertTrue(app.challengePending)
                XCTAssertEqual(app.session?.puzzle.id, 10)
                app.continueChallenge(); app.continueChallenge()
                XCTAssertEqual(app.session?.puzzle.id, 11)
                XCTAssertFalse(app.challengePending)
            }
            XCTAssertEqual(provider.displays.count, 1)
            assertNoRewards(app)
        }
    }

    @MainActor func testBackgroundCloseRecordsNowButWaitsForForegroundToNavigate() async throws {
        for toHome in [false, true] {
            let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
            let app = try winning(directory, identity: identity, provider: provider)
            let won = app.session
            if toHome { app.home() } else { app.next() }
            let offered = try offer(app)
            provider.displays[0](.started); await drain()
            app.setActive(false)
            provider.displays[0](.closed); provider.displays[0](.closed); await drain()
            XCTAssertEqual(statuses(app, for: offered), [.text("started"), .text("completed")])
            XCTAssertEqual(app.session, won)
            XCTAssertEqual(app.screen, .game)
            XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
            XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.background))
            app.setActive(true); app.setActive(true)
            XCTAssertEqual(app.screen, toHome ? .home : .game)
            XCTAssertEqual(app.session?.puzzle.id, toHome ? 2 : 3)
            XCTAssertEqual(provider.displays.count, 1)
            XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.background))
            XCTAssertEqual(results(app, for: offered).count, 2)
            assertNoRewards(app)
        }
    }

    @MainActor func testOfferResultsKeepOriginalSessionAfterAnalyticsSessionRollover() async throws {
        let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
        let app = try winning(directory, identity: identity, provider: provider)
        app.next()
        let offered = try offer(app)
        app.analytics.endSession(reason: "quit")
        app.analytics.beginSession(source: "resume")
        let newSession = try XCTUnwrap(app.analytics.events.last { $0.eventName == "session_start" }?.sessionID)
        XCTAssertNotEqual(newSession, offered.sessionID)
        provider.displays[0](.started); provider.displays[0](.closed); await drain()
        for result in results(app, for: offered) {
            XCTAssertEqual(result.sessionID, offered.sessionID)
            XCTAssertEqual(result.levelID, offered.levelID)
            XCTAssertEqual(result.userID, offered.userID)
            XCTAssertEqual(result.pawdokuConfigVersion, offered.pawdokuConfigVersion)
        }
        XCTAssertEqual(results(app, for: offered).count, 2)
        XCTAssertEqual(app.analytics.events.last { $0.eventName == "level_start" && $0.levelID == 3 }?.sessionID, newSession)
        assertNoRewards(app)
    }

    @MainActor func testPreConsentOfferDoesNotBackfillEvenIfConsentArrivesBeforeItsCallbacks() async throws {
        for consentDuringOffer in [false, true] {
            let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
            let app = try winning(directory, identity: identity, provider: provider, consent: false)
            app.next()
            if consentDuringOffer { app.consentAccepted() }
            provider.displays[0](.started); provider.displays[0](.closed); await drain()
            app.consentAccepted()
            XCTAssertTrue(adEvents(app).isEmpty)
            let coldProvider = ControlledAnalyticsInterstitial()
            let restored = model(directory, identity: identity, provider: coldProvider)
            XCTAssertTrue(adEvents(restored).isEmpty)
            XCTAssertTrue(coldProvider.loads.isEmpty)
            XCTAssertTrue(coldProvider.displays.isEmpty)
            assertNoRewards(restored)
        }
    }

    @MainActor func testQueueWriteFailureColdRecoveryAndLostAcknowledgementKeepOriginalCompletion() async throws {
        let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
        let app = try winning(directory, identity: identity, provider: provider)
        app.next()
        let offered = try offer(app)
        provider.displays[0](.started); await drain()
        let queue = directory.appendingPathComponent("analytics-demo-queue.json")
        let savedQueue = try Data(contentsOf: queue)
        try FileManager.default.removeItem(at: queue)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: false)
        app.setActive(false)
        provider.displays[0](.closed); provider.displays[0](.closed); await drain()
        let frozen = try XCTUnwrap(try pending(directory).first { $0.event.parameters["status"] == .text("completed") })
        let stateURL = directory.appendingPathComponent("win-ad-state.json")
        let beforeAcknowledgement = try Data(contentsOf: stateURL)
        XCTAssertEqual(frozen.event.parameters["offer_id"], offered.parameters["offer_id"])
        XCTAssertEqual(frozen.event.sessionID, offered.sessionID)
        XCTAssertEqual(app.session?.puzzle.id, 2)
        try FileManager.default.removeItem(at: queue)
        try savedQueue.write(to: queue, options: .atomic)
        let coldProvider = ControlledAnalyticsInterstitial()
        let recovered = model(directory, identity: identity, provider: coldProvider)
        let result = try XCTUnwrap(results(recovered, for: offered).first { $0.parameters["status"] == .text("completed") })
        assertSameEvent(result, frozen.event)
        XCTAssertTrue(try pending(directory).isEmpty)
        XCTAssertTrue(coldProvider.displays.isEmpty)
        assertNoRewards(recovered)
        // Emulate termination after durable queue delivery but before its outbox
        // acknowledgement reaches disk, using the real pre-acknowledgement file.
        try beforeAcknowledgement.write(to: stateURL, options: .atomic)
        try beforeAcknowledgement.write(to: stateURL.appendingPathExtension("backup"), options: .atomic)
        let again = model(directory, identity: identity, provider: ControlledAnalyticsInterstitial())
        let completions = results(again, for: offered).filter { $0.parameters["status"] == .text("completed") }
        XCTAssertEqual(completions.count, 1)
        assertSameEvent(try XCTUnwrap(completions.first), frozen.event)
        XCTAssertTrue(try pending(directory).isEmpty)
        assertNoRewards(again)
    }

    @MainActor func testColdRecoveryOfOfferAndStartedNeverFabricatesATerminalResultOrReplay() async throws {
        let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
        let app = try winning(directory, identity: identity, provider: provider)
        let queue = directory.appendingPathComponent("analytics-demo-queue.json")
        let savedQueue = try Data(contentsOf: queue)
        try FileManager.default.removeItem(at: queue)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: false)
        app.next()
        provider.displays[0](.started); await drain()
        let frozen = try pending(directory)
        XCTAssertEqual(frozen.count, 2)
        XCTAssertEqual(Set(frozen.map { $0.event.eventName }), ["ad_offer_shown", "ad_result"])
        XCTAssertEqual(frozen.first { $0.event.eventName == "ad_result" }?.event.parameters["status"], .text("started"))
        try FileManager.default.removeItem(at: queue)
        try savedQueue.write(to: queue, options: .atomic)
        let coldProvider = ControlledAnalyticsInterstitial()
        let recovered = model(directory, identity: identity, provider: coldProvider)
        for original in frozen {
            let delivered = try XCTUnwrap(adEvents(recovered).first { $0.eventID == original.event.eventID })
            assertSameEvent(delivered, original.event)
        }
        let offered = try offer(recovered)
        XCTAssertEqual(statuses(recovered, for: offered), [.text("started")])
        XCTAssertTrue(try pending(directory).isEmpty)
        recovered.startOrContinue()
        recovered.next()
        XCTAssertEqual(recovered.session?.puzzle.id, 3)
        XCTAssertTrue(coldProvider.loads.isEmpty)
        XCTAssertTrue(coldProvider.displays.isEmpty)
        XCTAssertEqual(statuses(recovered, for: offered), [.text("started")])
        assertNoRewards(recovered)
    }

    @MainActor func testBackgroundCloseColdRestoreKeepsConfirmedNextChallengeAndHomeDestinations() async throws {
        for (level, toHome) in [(2, false), (10, false), (2, true)] {
            let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
            let app = try winning(directory, identity: identity, provider: provider, level: level)
            let originalBoard = try XCTUnwrap(app.session)
            if toHome { app.home() } else { app.next() }
            let offered = try offer(app)
            provider.displays[0](.started); await drain()
            app.setActive(false)
            provider.displays[0](.closed); await drain()
            let completion = try XCTUnwrap(results(app, for: offered).first { $0.parameters["status"] == .text("completed") })
            XCTAssertEqual(app.session, originalBoard)
            XCTAssertFalse(app.challengePending)
            let coldProvider = ControlledAnalyticsInterstitial()
            let recovered = model(directory, identity: identity, provider: coldProvider)
            XCTAssertEqual(recovered.screen, .home)
            XCTAssertEqual(recovered.session, originalBoard)
            XCTAssertFalse(recovered.challengePending)
            recovered.setActive(true)
            XCTAssertEqual(recovered.screen, .home, "Cold foregrounding does not auto-enter a level.")
            recovered.startOrContinue()
            if toHome {
                XCTAssertEqual(recovered.session, originalBoard, "Home was fulfilled on cold startup; Continue must not invent a next-level request.")
            } else if level == 10 {
                XCTAssertTrue(recovered.challengePending)
                XCTAssertEqual(recovered.session?.puzzle.id, 10)
                recovered.continueChallenge(); recovered.continueChallenge()
                XCTAssertFalse(recovered.challengePending)
                XCTAssertEqual(recovered.session?.puzzle.id, 11)
            } else {
                XCTAssertEqual(recovered.session?.puzzle.id, 3)
            }
            let terminal = results(recovered, for: offered).filter { $0.parameters["status"] == .text("completed") }
            XCTAssertEqual(terminal.count, 1)
            assertSameEvent(try XCTUnwrap(terminal.first), completion)
            XCTAssertTrue(coldProvider.loads.isEmpty)
            XCTAssertTrue(coldProvider.displays.isEmpty)
            assertNoRewards(recovered)
        }
    }

    @MainActor func testDefaultAdapterMetadataAndMockSimulationRemainDistinct() async throws {
        let defaults = DefaultMetadataInterstitial()
        let app = try winning(directory(), identity: InterstitialTestIdentity(), provider: defaults)
        app.next()
        let offered = try offer(app)
        XCTAssertEqual(offered.parameters["network"], .text("unconfigured"))
        XCTAssertEqual(offered.parameters["ad_unit_id"], .text("unconfigured"))
        defaults.displays[0](.failed); await drain()
        assertNoRewards(app)
        for scenario in [RewardScenario.success, .cancel, .failure] {
            let simulated = try winning(directory(), identity: InterstitialTestIdentity(), provider: MockInterstitialProvider(scenario: scenario))
            simulated.next()
            let offered = try offer(simulated)
            try await Task.sleep(nanoseconds: 650_000_000)
            XCTAssertEqual(offered.parameters["network"], .text("simulation"))
            XCTAssertEqual(offered.parameters["ad_unit_id"], .text("internal-demo"))
            switch scenario {
            case .success: XCTAssertEqual(statuses(simulated, for: offered), [.text("started"), .text("completed")])
            case .cancel: XCTAssertEqual(statuses(simulated, for: offered), [.text("started"), .text("skipped")])
            case .failure: XCTAssertEqual(statuses(simulated, for: offered), [.text("failed")])
            default: XCTFail("Unexpected scenario")
            }
            XCTAssertFalse(simulated.interstitialBusy)
            assertNoRewards(simulated)
        }
    }

    @MainActor func testWinAdStateWriteFailureKeepsFrequencyAndOfferUnconsumedUntilRetry() async throws {
        let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
        let app = try winning(directory, identity: identity, provider: provider,
                              configure: { $0.interstitial.frequency = 2 })
        let firstWin = try XCTUnwrap(app.session?.id)
        app.next() // First eligible win establishes a committed N=2 baseline, without an ad.
        XCTAssertEqual(app.session?.puzzle.id, 3)
        try win(app)
        let secondWin = try XCTUnwrap(app.session)
        let before = try savedState(directory)
        XCTAssertEqual(before.eligibleCount, 1)
        XCTAssertEqual(before.shown, [firstWin])
        let file = directory.appendingPathComponent("win-ad-state.json")
        let savedBytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        app.next(); app.next()
        XCTAssertNotNil(app.errorMessage)
        XCTAssertEqual(app.session, secondWin)
        XCTAssertFalse(app.interstitialBusy)
        XCTAssertTrue(provider.loads.isEmpty)
        XCTAssertTrue(provider.displays.isEmpty)
        XCTAssertTrue(adEvents(app).isEmpty)
        // The primary is blocked; the last valid backup must still describe the
        // old frequency state rather than a silently consumed new opportunity.
        let failed = try savedState(directory)
        XCTAssertEqual(failed.eligibleCount, before.eligibleCount)
        XCTAssertEqual(failed.shown, before.shown)
        XCTAssertEqual(failed.lastShownAt, before.lastShownAt)
        XCTAssertTrue(failed.pendingEvents?.isEmpty ?? true)
        try FileManager.default.removeItem(at: file)
        try savedBytes.write(to: file, options: .atomic)
        app.errorMessage = nil; app.notice = nil
        app.next(); app.next()
        XCTAssertEqual(provider.loads.count, 1)
        XCTAssertEqual(provider.displays.count, 1)
        XCTAssertEqual(adEvents(app, "ad_offer_shown").count, 1)
        let retried = try savedState(directory)
        XCTAssertEqual(retried.eligibleCount, 2)
        XCTAssertEqual(retried.shown, [firstWin, secondWin.id])
        provider.displays[0](.failed); await drain()
        XCTAssertEqual(app.session?.puzzle.id, 4)
        assertNoRewards(app)
    }

    @MainActor func testFrequencyCooldownAndEligibilityUseSessionSnapshotAndConsumeEachWinOnce() async throws {
        let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
        let app = try winning(directory, identity: identity, provider: provider, configure: {
            $0.interstitial.frequency = 2
            $0.interstitial.cooldownSeconds = 60
        })
        // The active win keeps N=2 even when the next-game configuration changes.
        app.config.referenceGameplay?.interstitial.frequency = 1
        app.home()
        XCTAssertEqual(app.screen, .home)
        XCTAssertTrue(provider.loads.isEmpty)
        XCTAssertTrue(adEvents(app).isEmpty)
        XCTAssertEqual(try savedState(directory).eligibleCount, 1)
        app.startOrContinue(); app.home()
        XCTAssertEqual(try savedState(directory).eligibleCount, 1)
        app.start(level: 3); try win(app)
        app.home()
        XCTAssertEqual(provider.displays.count, 1, "The new game's N=1 configuration now applies.")
        provider.displays[0](.started); provider.displays[0](.closed); await drain()
        XCTAssertEqual(app.screen, .home)
        XCTAssertEqual(try savedState(directory).eligibleCount, 2)
        app.startOrContinue(); app.home()
        XCTAssertEqual(try savedState(directory).eligibleCount, 2)
        XCTAssertEqual(provider.displays.count, 1)
        app.start(level: 4); try win(app)
        app.home() // Eligible, but still inside the frozen sixty-second cooldown.
        XCTAssertEqual(app.screen, .home)
        XCTAssertEqual(try savedState(directory).eligibleCount, 3)
        XCTAssertEqual(provider.displays.count, 1)
        XCTAssertEqual(adEvents(app, "ad_offer_shown").count, 1)
        app.startOrContinue(); app.home()
        XCTAssertEqual(try savedState(directory).eligibleCount, 3)
        assertNoRewards(app)

        for gate in ["ads", "enabled", "starting-level", "next-entry", "home-entry"] {
            let gateDirectory = self.directory(), gateIdentity = InterstitialTestIdentity(), gateProvider = ControlledAnalyticsInterstitial()
            let toHome = gate == "home-entry"
            let gated = try winning(gateDirectory, identity: gateIdentity, provider: gateProvider, configure: { row in
                switch gate {
                case "ads": row.adsEnabled = false
                case "enabled": row.interstitial.enabled = false
                case "starting-level": row.interstitial.startLevel = 99
                case "next-entry": row.interstitial.onNextLevel = false
                case "home-entry": row.interstitial.onReturnHome = false
                default: break
                }
            })
            var future = try XCTUnwrap(gated.config.referenceGameplay)
            future.adsEnabled = true; future.interstitial.enabled = true; future.interstitial.startLevel = 1
            future.interstitial.onNextLevel = true; future.interstitial.onReturnHome = true
            gated.config.referenceGameplay = future
            if toHome { gated.home() } else { gated.next() }
            XCTAssertTrue(gateProvider.loads.isEmpty, "The active session must preserve its disabled \(gate) gate.")
            XCTAssertTrue(adEvents(gated).isEmpty)
            gated.start(level: 4); try win(gated)
            if toHome { gated.home() } else { gated.next() }
            XCTAssertEqual(gateProvider.loads.count, 1)
            XCTAssertEqual(gateProvider.displays.count, 1)
            XCTAssertEqual(adEvents(gated, "ad_offer_shown").count, 1)
            gateProvider.displays[0](.failed); await drain()
            assertNoRewards(gated)
        }
    }

    @MainActor func testSettingsNoticeAndNonWinningStatesCannotRequestInterstitials() async throws {
        let directory = directory(), identity = InterstitialTestIdentity(), provider = ControlledAnalyticsInterstitial()
        let app = try winning(directory, identity: identity, provider: provider)
        let won = app.session
        app.sheet = .settings
        app.next(); app.home()
        XCTAssertEqual(app.session, won)
        XCTAssertEqual(app.screen, .game)
        app.sheet = nil; app.notice = "Synthetic permission notice"
        app.next(); app.home()
        XCTAssertEqual(app.session, won)
        XCTAssertEqual(app.screen, .game)
        app.notice = nil
        app.start(level: 3)
        let playing = app.session
        app.next()
        XCTAssertEqual(app.session, playing)
        app.home()
        XCTAssertEqual(app.screen, .home)
        XCTAssertTrue(provider.loads.isEmpty)
        XCTAssertTrue(provider.displays.isEmpty)
        XCTAssertTrue(adEvents(app).isEmpty)
        app.startOrContinue(); try win(app)
        app.next(); app.next()
        XCTAssertEqual(provider.loads.count, 1)
        XCTAssertEqual(provider.displays.count, 1)
        XCTAssertEqual(adEvents(app, "ad_offer_shown").count, 1)
        provider.displays[0](.failed); await drain()
        assertNoRewards(app)
    }

    @MainActor func testProductionAsyncSaveNavigationAndSecondWinColdRecoveryDoNotReplayOrSkipLevels() async throws {
        let directory = directory(), identity = InterstitialTestIdentity(), firstProvider = ControlledAnalyticsInterstitial()
        let app = try winning(directory, identity: identity, provider: firstProvider, asyncSaves: true)
        app.next()
        let firstOffer = try offer(app)
        firstProvider.displays[0](.started); firstProvider.displays[0](.closed)
        await drain()
        XCTAssertEqual(app.session?.puzzle.id, 3)
        let nextBoard = try XCTUnwrap(app.session?.id)
        app.startOrContinue()
        app.flushPendingSaves()
        app.setActive(false)
        let secondProvider = ControlledAnalyticsInterstitial()
        let recovered = model(directory, identity: identity, provider: secondProvider, asyncSaves: true)
        recovered.config = app.config
        recovered.startOrContinue(); recovered.startOrContinue()
        XCTAssertEqual(recovered.session?.id, nextBoard)
        XCTAssertEqual(recovered.session?.puzzle.id, 3)
        XCTAssertTrue(secondProvider.loads.isEmpty)
        XCTAssertEqual(statuses(recovered, for: firstOffer), [.text("started"), .text("completed")])
        try win(recovered)
        recovered.next()
        let secondOffer = try offer(recovered, index: 1)
        secondProvider.displays[0](.started); await drain()
        recovered.setActive(false)
        secondProvider.displays[0](.closed)
        firstProvider.displays[0](.closed) // An obsolete owner cannot complete the new owner's continuation.
        await drain()
        recovered.flushPendingSaves()
        XCTAssertEqual(recovered.session?.puzzle.id, 3)
        XCTAssertEqual(recovered.session?.status, .won)
        let coldProvider = ControlledAnalyticsInterstitial()
        let final = model(directory, identity: identity, provider: coldProvider)
        XCTAssertEqual(final.screen, .home)
        final.startOrContinue(); final.startOrContinue()
        XCTAssertEqual(final.session?.puzzle.id, 4)
        XCTAssertEqual(final.session?.attempt, 1)
        XCTAssertEqual(statuses(final, for: firstOffer), [.text("started"), .text("completed")])
        XCTAssertEqual(statuses(final, for: secondOffer), [.text("started"), .text("completed")])
        XCTAssertEqual(adEvents(final, "ad_offer_shown").count, 2)
        XCTAssertTrue(coldProvider.loads.isEmpty)
        XCTAssertTrue(coldProvider.displays.isEmpty)
        XCTAssertNil(final.errorMessage)
        assertNoRewards(final)
    }
}
