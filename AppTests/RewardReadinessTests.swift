import XCTest
import CapydokuCore
@testable import Capydoku

private final class ReadinessRewards: RewardProvider {
    var loads: [(placement: RewardKind, callback: (RewardReadiness) -> Void)] = []
    var displays: [(id: String, callback: (RewardSignal) -> Void)] = []
    var displayedPlacements: [RewardKind] = []
    var replacements: [RewardKind] = []
    func preload(placement: RewardKind, completion: @escaping (RewardReadiness) -> Void) {
        loads.append((placement, completion))
    }
    func isReady(placement: RewardKind) -> Bool { false }
    func present(placement: RewardKind, offerID: String, completion: @escaping (RewardSignal) -> Void) {
        displayedPlacements.append(placement); displays.append((offerID, completion))
    }
    func replenish(placement: RewardKind) { replacements.append(placement) }
}

private final class ReadinessInterstitial: InterstitialProvider {
    var callbacks: [(InterstitialSignal) -> Void] = []
    var loads: [(RewardReadiness) -> Void] = []
    var isReady: Bool
    init(ready: Bool = true) { isReady = ready }
    func load(completion: @escaping (RewardReadiness) -> Void) { loads.append(completion) }
    func present(completion: @escaping (InterstitialSignal) -> Void) { callbacks.append(completion) }
}

final class RewardReadinessTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func drain() async { try? await Task.sleep(nanoseconds: 30_000_000) }
    private func referenceRow() throws -> ReferenceLevelGameplay {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
        return try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: url))
    }
    @MainActor private func model(_ root: URL, _ provider: ReadinessRewards, timeout: TimeInterval = 1) -> AppModel {
        let app = AppModel(saveDirectory: root, rewardProvider: provider, rewardTimeout: timeout, runsTimer: false, feedbackEnabled: false)
        app.progress.tutorialCompleted = true; app.start(level: 1)
        app.showHint(); XCTAssertNotNil(app.hint); app.closeHint()
        XCTAssertEqual(app.progress.availableHints, 0)
        return app
    }
    @MainActor func testStartupGateBlocksAllAdEntryPointsAndWarmsOnlyEnabledPlacements() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = ReadinessRewards(), interstitial = ReadinessInterstitial()
        let app = AppModel(saveDirectory: root, rewardProvider: provider, runsTimer: false, feedbackEnabled: false,
                           interstitialProvider: interstitial, startupBypassForTesting: false)
        var row = try referenceRow(); row.adsEnabled = true
        row.directFind.visible = false; row.directFind.buttonState = .hidden; row.revive.enabled = false
        row.hint.initialFreeCount = 0
        row.interstitial.enabled = true; row.interstitial.frequency = 1
        row.interstitial.onNextLevel = true; row.interstitial.startLevel = 1
        app.config = DemoConfig(referenceGameplay: row); app.progress.tutorialCompleted = true
        app.start(level: 1) // Same path that a DEBUG -level argument can invoke before Welcome.
        XCTAssertNil(app.errorMessage, "The startup-gate fixture must also be a valid persistable configuration.")
        app.offer(.hint); app.sheet = .reward; app.runReward(); app.sheet = nil
        XCTAssertTrue(provider.loads.isEmpty); XCTAssertTrue(provider.displays.isEmpty)
        XCTAssertTrue(app.progress.rewardLedger.isEmpty)
        XCTAssertNil(app.notice)
        let beforeStartup = try XCTUnwrap(app.session)
        for cell in beforeStartup.puzzle.solution { app.submit(cell) }
        XCTAssertEqual(app.session, beforeStartup, "Startup must also block board input.")
        // Model a previously won board waiting behind startup. Construct that
        // fixture through the core; application input may no longer bypass the
        // startup gate just to arrange an interstitial test.
        for cell in beforeStartup.puzzle.solution { _ = app.progress.session?.submit(cell: cell) }
        XCTAssertTrue(app.progress.finishWin())
        XCTAssertEqual(app.session?.status, .won)
        app.save()
        app.next()
        XCTAssertEqual(app.session?.puzzle.id, 1); XCTAssertTrue(interstitial.callbacks.isEmpty)
        app.startupReady(); app.startupReady()
        XCTAssertEqual(provider.loads.map(\.placement), [.hint])
        provider.loads[0].callback(.ready); await drain()
        XCTAssertTrue(provider.displays.isEmpty, "Speculative preload must never present an ad or create an offer")
        XCTAssertTrue(app.progress.rewardLedger.isEmpty)
        app.next(); XCTAssertEqual(interstitial.callbacks.count, 1)
        try XCTUnwrap(interstitial.callbacks.first)(.closed); await drain()
    }
    @MainActor func testPendingReadinessPreservesBoardThenDisplaysOnceAndReplenishesOnce() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = ReadinessRewards(); let app = model(root, provider)
        let before = app.session
        app.offer(.hint)
        let loading = try XCTUnwrap(provider.loads.last)
        XCTAssertEqual(loading.placement, .hint)
        XCTAssertTrue(app.rewardBusy); XCTAssertTrue(provider.displays.isEmpty)
        XCTAssertEqual(app.session, before); XCTAssertEqual(app.progress.availableHints, 0)
        let id = try XCTUnwrap(app.progress.rewardLedger.keys.first)
        XCTAssertEqual(app.progress.rewardLedger[id]?.state, .offered)
        loading.callback(.ready); loading.callback(.ready); await drain()
        XCTAssertEqual(provider.displays.count, 1); XCTAssertEqual(provider.displays[0].id, id)
        XCTAssertEqual(provider.displayedPlacements, [.hint])
        XCTAssertEqual(provider.replacements, [.hint], "A consumed presentation immediately requests one replacement")
        provider.displays[0].callback(.earned); provider.displays[0].callback(.earned); await drain()
        XCTAssertEqual(app.progress.rewardLedger[id]?.state, .executed)
        XCTAssertNotNil(app.hint); XCTAssertFalse(app.rewardBusy)
        app.closeHint()
        loading.callback(.ready); provider.displays[0].callback(.earned); await drain()
        XCTAssertNil(app.hint); XCTAssertEqual(app.progress.availableHints, 0)
        XCTAssertEqual(provider.displays.count, 1); XCTAssertEqual(provider.replacements, [.hint])
    }
    @MainActor func testPreloadTimeoutRejectsLateReadinessIncludingDuringANewerOffer() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = ReadinessRewards(); let app = model(root, provider, timeout: 0.1)
        app.offer(.hint)
        let oldLoad = try XCTUnwrap(provider.loads.last)
        let oldID = try XCTUnwrap(app.progress.rewardLedger.keys.first)
        try? await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertFalse(app.rewardBusy); XCTAssertNil(app.sheet)
        XCTAssertEqual(app.progress.rewardLedger[oldID]?.state, .cancelled)
        XCTAssertTrue(provider.displays.isEmpty); XCTAssertTrue(provider.replacements.isEmpty)
        app.notice = nil; app.offer(.hint)
        let newLoad = try XCTUnwrap(provider.loads.last)
        oldLoad.callback(.ready); await drain()
        XCTAssertTrue(app.rewardBusy); XCTAssertTrue(provider.displays.isEmpty)
        XCTAssertEqual(app.progress.availableHints, 0)
        newLoad.callback(.ready); await drain()
        XCTAssertEqual(provider.displays.count, 1); XCTAssertNotEqual(provider.displays[0].id, oldID)
        provider.displays[0].callback(.cancelled); await drain()
        XCTAssertEqual(app.progress.availableHints, 0)
    }
    @MainActor func testUnavailablePreloadNeverDisplaysOrReplenishesOrGrants() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = ReadinessRewards(); let app = model(root, provider)
        app.offer(.hint)
        let load = try XCTUnwrap(provider.loads.last), id = try XCTUnwrap(app.progress.rewardLedger.keys.first)
        load.callback(.unavailable); load.callback(.ready); await drain()
        XCTAssertFalse(app.rewardBusy); XCTAssertNil(app.sheet)
        XCTAssertTrue(provider.displays.isEmpty); XCTAssertTrue(provider.replacements.isEmpty)
        XCTAssertEqual(app.progress.rewardLedger[id]?.state, .cancelled)
        XCTAssertEqual(app.progress.availableHints, 0)
    }
    @MainActor func testReadyWhileBackgroundedWaitsForForegroundWithoutDuplicateDisplay() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = ReadinessRewards(); let app = model(root, provider)
        app.offer(.hint); app.setActive(false)
        let load = try XCTUnwrap(provider.loads.last)
        load.callback(.ready); await drain()
        XCTAssertTrue(provider.displays.isEmpty); XCTAssertTrue(app.rewardBusy)
        app.setActive(true); app.setActive(true)
        XCTAssertEqual(provider.displays.count, 1); XCTAssertEqual(provider.replacements, [.hint])
        provider.displays[0].callback(.failed); await drain()
        XCTAssertFalse(app.rewardBusy); XCTAssertEqual(app.progress.availableHints, 0)
        XCTAssertEqual(provider.replacements, [.hint])
    }
    @MainActor private func winningModel(_ root: URL, provider: ReadinessInterstitial) throws -> AppModel {
        let app = AppModel(saveDirectory: root, runsTimer: false, feedbackEnabled: false, interstitialProvider: provider)
        var row = try referenceRow(); row.adsEnabled = true; row.interstitial.enabled = true
        row.interstitial.startLevel = 1; row.interstitial.frequency = 1; row.interstitial.cooldownSeconds = 0
        row.interstitial.onNextLevel = true; row.interstitial.adTimeoutSeconds = 1
        app.config = DemoConfig(referenceGameplay: row); app.progress.tutorialCompleted = true; app.start(level: 2)
        for cell in try XCTUnwrap(app.session).puzzle.solution { app.submit(cell) }
        XCTAssertEqual(app.session?.status, .won)
        return app
    }
    @MainActor func testInterstitialFailureContinuesExactlyOnceWithoutReward() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = ReadinessInterstitial(), app = try winningModel(root, provider: provider)
        let bonusHints = app.progress.bonusHints, bonusDirect = app.progress.bonusDirect
        app.next(); XCTAssertTrue(app.interstitialBusy); XCTAssertEqual(provider.callbacks.count, 1)
        provider.callbacks[0](.failed); provider.callbacks[0](.closed); await drain()
        XCTAssertFalse(app.interstitialBusy); XCTAssertNil(app.sheet); XCTAssertEqual(app.session?.puzzle.id, 3)
        let newSession = app.session?.id
        provider.callbacks[0](.closed); await drain()
        XCTAssertEqual(app.session?.id, newSession); XCTAssertTrue(app.progress.rewardLedger.isEmpty)
        XCTAssertEqual(app.progress.bonusHints, bonusHints); XCTAssertEqual(app.progress.bonusDirect, bonusDirect)
    }
    @MainActor func testInterstitialLoadTimesOutAndLateReadinessDoesNotAdvanceAgain() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = ReadinessInterstitial(ready: false), app = try winningModel(root, provider: provider)
        let bonusHints = app.progress.bonusHints, bonusDirect = app.progress.bonusDirect
        app.next(); XCTAssertTrue(app.interstitialBusy); XCTAssertTrue(provider.callbacks.isEmpty)
        XCTAssertEqual(provider.loads.count, 1)
        try? await Task.sleep(nanoseconds: 1_150_000_000)
        XCTAssertFalse(app.interstitialBusy); XCTAssertNil(app.sheet); XCTAssertEqual(app.session?.puzzle.id, 3)
        let newSession = app.session?.id
        provider.loads[0](.ready); provider.loads[0](.unavailable); await drain()
        XCTAssertTrue(provider.callbacks.isEmpty)
        XCTAssertEqual(app.session?.id, newSession); XCTAssertTrue(app.progress.rewardLedger.isEmpty)
        XCTAssertEqual(app.progress.bonusHints, bonusHints); XCTAssertEqual(app.progress.bonusDirect, bonusDirect)
    }

    @MainActor func testDisplayedInterstitialWaitsForCloseBeyondLoadingBudget() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = ReadinessInterstitial(), app = try winningModel(root, provider: provider)
        let board = app.session
        app.next(); XCTAssertEqual(provider.callbacks.count, 1)
        try? await Task.sleep(nanoseconds: 1_150_000_000)
        XCTAssertTrue(app.interstitialBusy); XCTAssertEqual(app.session, board)
        app.next(); XCTAssertEqual(provider.callbacks.count, 1)
        provider.callbacks[0](.closed); provider.callbacks[0](.closed); await drain()
        XCTAssertFalse(app.interstitialBusy); XCTAssertEqual(app.session?.puzzle.id, 3)
        XCTAssertTrue(app.progress.rewardLedger.isEmpty)
    }

    @MainActor func testInterstitialReadyWhileBackgroundedWaitsToPresentThenRestoresHome() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = ReadinessInterstitial(ready: false), app = try winningModel(root, provider: provider)
        var row = try referenceRow(); row.adsEnabled = true; row.interstitial.enabled = true
        row.interstitial.onReturnHome = true; row.interstitial.startLevel = 1
        row.interstitial.frequency = 1; row.interstitial.cooldownSeconds = 0; row.interstitial.adTimeoutSeconds = 1
        app.config = DemoConfig(referenceGameplay: row); app.start(level: 2)
        for cell in try XCTUnwrap(app.session).puzzle.solution { app.submit(cell) }
        app.home(); app.setActive(false)
        provider.loads[0](.ready); await drain()
        try? await Task.sleep(nanoseconds: 1_150_000_000)
        XCTAssertTrue(app.interstitialBusy); XCTAssertTrue(provider.callbacks.isEmpty)
        app.setActive(true); app.setActive(true)
        XCTAssertEqual(provider.callbacks.count, 1)
        provider.callbacks[0](.closed); await drain()
        XCTAssertEqual(app.screen, .home); XCTAssertEqual(app.session?.puzzle.id, 2)
        XCTAssertTrue(app.progress.rewardLedger.isEmpty)
    }
}
