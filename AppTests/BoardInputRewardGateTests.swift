import XCTest
import CapydokuCore
@testable import Capydoku

private final class InputGateIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}

private final class InputGateRewards: RewardProvider {
    var loads: [RewardKind] = []
    var displays: [(kind: RewardKind, id: String, callback: (RewardSignal) -> Void)] = []
    var analyticsMetadata: RewardAnalyticsMetadata { .simulation }
    func preload(placement: RewardKind, completion: @escaping (RewardReadiness) -> Void) {
        loads.append(placement)
        completion(.ready)
    }
    func present(placement: RewardKind, offerID: String, completion: @escaping (RewardSignal) -> Void) {
        displays.append((placement, offerID, completion))
    }
}

final class BoardInputRewardGateTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("board-input-gate-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func row(hints: Int = 0, direct: Int = 0) throws -> ReferenceLevelGameplay {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
        var row = try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: url))
        row.adsEnabled = true
        row.directFind.initialFreeCount = direct
        row.directFind.firstUnlockBonusCount = 0
        row.hint.initialFreeCount = hints
        row.hint.firstUnlockBonusCount = 0
        row.failure.restartCreatesNewBoard = false
        row.levelStartFreeAd.enabled = true
        row.levelStartFreeAd.visible = true
        row.levelStartFreeAd.buttonState = .enabled
        row.levelStartFreeAd.freeCount = 1
        row.levelStartFreeAd.reward = .hint
        row.levelStartFreeAd.rewardCount = 2
        row.levelStartFreeAd.resetPolicy = .oncePerLevel
        // triggerOrder deliberately remains the fixture's documented synthetic value.
        return row
    }

    @MainActor private func model(_ row: ReferenceLevelGameplay, rewards: InputGateRewards = InputGateRewards()) throws -> AppModel {
        let feedback = FeedbackPlayer(manifest: .silent, resourceResolver: { _ in nil },
                                      playerFactory: { _ in nil }, sessionControl: { _ in true }, observeSystem: false)
        let app = AppModel(saveDirectory: directory(), rewardProvider: rewards, runsTimer: false,
                           feedbackEnabled: false, analyticsIdentityStore: InputGateIdentity(), feedbackPlayer: feedback)
        app.consentAccepted()
        app.progress.tutorialCompleted = true
        app.config = DemoConfig(referenceGameplay: row)
        app.start(level: 1)
        XCTAssertNil(app.errorMessage, "Every input-gate fixture must satisfy the real configuration validator")
        let puzzle = try XCTUnwrap(app.session?.puzzle)
        let persisted = SaveStore(directory: app.saveDirectory, packagedPuzzle: { $0 == puzzle.id ? puzzle : nil }).load()
        XCTAssertEqual(persisted.source, .primary)
        XCTAssertEqual(persisted.progress.session, app.session)
        return app
    }

    @MainActor private func assertNoOffer(_ app: AppModel, _ rewards: InputGateRewards,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.progress.rewardLedger.isEmpty, file: file, line: line)
        XCTAssertTrue(rewards.displays.isEmpty, file: file, line: line)
        XCTAssertFalse(app.rewardBusy, file: file, line: line)
        XCTAssertTrue(app.analytics.events.filter { $0.eventName == "ad_offer_shown" || $0.eventName == "ad_result" }.isEmpty,
                      file: file, line: line)
    }

    @MainActor func testZeroInventoryGestureBlocksEveryToolAndOfferEntryWithoutCreatingOrDisplayingReward() async throws {
        let rewards = InputGateRewards(), app = try model(row(), rewards: rewards)
        let sessionID = try XCTUnwrap(app.session?.id), owner = UUID()
        let before = app.progress, preloadCount = rewards.loads.count
        app.setBoardInputActivity(owner, active: true, sessionID: sessionID)
        XCTAssertTrue(app.boardInputInProgress)
        app.direct(); app.showHint(); app.levelStartFree()
        app.offer(.direct); app.offer(.hint); app.offer(.levelStartFree)
        app.rewardKind = .hint; app.sheet = .reward; app.runReward(); app.sheet = nil
        XCTAssertEqual(app.progress, before)
        XCTAssertEqual(rewards.loads.count, preloadCount)
        XCTAssertNil(app.hint)
        assertNoOffer(app, rewards)
        app.setBoardInputActivity(owner, active: false, sessionID: sessionID)
        XCTAssertFalse(app.boardInputInProgress)
        app.direct()
        XCTAssertEqual(rewards.displays.count, 1, "A blocked attempt must not leave a debounce or reward lock behind")
        let display = try XCTUnwrap(rewards.displays.first)
        XCTAssertEqual(display.kind, .direct)
        XCTAssertEqual(app.progress.rewardLedger[display.id]?.state, .offered)
        display.callback(.earned); display.callback(.earned)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(app.session?.found.count, 1)
        XCTAssertEqual(app.progress.rewardLedger.count, 1)
        XCTAssertEqual(app.progress.rewardLedger[display.id]?.state, .executed)
        XCTAssertEqual(app.progress.availableDirect, 0)
    }

    @MainActor func testPositiveInventoryToolsWaitForGestureWithoutSpendingOrInterruptingIt() throws {
        let rewards = InputGateRewards(), app = try model(row(hints: 2, direct: 2), rewards: rewards)
        let sessionID = try XCTUnwrap(app.session?.id), owner = UUID(), before = app.progress
        app.setBoardInputActivity(owner, active: true, sessionID: sessionID)
        for _ in 0..<4 { app.direct(); app.showHint(); app.levelStartFree() }
        XCTAssertEqual(app.progress, before)
        XCTAssertNil(app.hint)
        XCTAssertNil(app.sheet)
        assertNoOffer(app, rewards)
        app.setBoardInputActivity(owner, active: false, sessionID: sessionID)
        app.direct()
        XCTAssertEqual(app.progress.availableDirect, before.availableDirect - 1)
        XCTAssertEqual(app.session?.found.count, 1)
        app.showHint()
        XCTAssertNotNil(app.hint)
        XCTAssertEqual(app.progress.availableHints, before.availableHints - 1)
        XCTAssertTrue(rewards.displays.isEmpty)
    }

    @MainActor func testCurrentGestureCanStillToggleSubmitAndMarkWhileRewardEntryIsGated() throws {
        let rewards = InputGateRewards(), app = try model(row(hints: 2, direct: 2), rewards: rewards)
        let session = try XCTUnwrap(app.session), owner = UUID()
        let wrong = session.puzzle.regions.indices.filter { !session.puzzle.solution.contains($0) }
        let cell = try XCTUnwrap(wrong.first)
        app.setBoardInputActivity(owner, active: true, sessionID: session.id)
        app.toggle(cell)
        XCTAssertTrue(app.session?.marks.contains(cell) == true)
        app.toggle(cell)
        XCTAssertFalse(app.session?.marks.contains(cell) == true)
        app.submit(session.puzzle.solution[0])
        XCTAssertEqual(app.session?.found.count, 1)
        app.mark(Array(wrong.prefix(3)))
        XCTAssertTrue(Set(wrong.prefix(3)).isSubset(of: try XCTUnwrap(app.session?.marks)))
        app.submit(cell)
        XCTAssertEqual(app.session?.lives, session.lives - 1)
        XCTAssertTrue(app.session?.errors.contains(cell) == true)
        XCTAssertEqual(app.progress.availableHints, 2)
        XCTAssertEqual(app.progress.availableDirect, 2)
        XCTAssertTrue(app.boardInputInProgress)
        assertNoOffer(app, rewards)
        app.setBoardInputActivity(owner, active: false, sessionID: session.id)
        XCTAssertFalse(app.boardInputInProgress)
    }

    @MainActor func testOldOwnerAndUnknownOwnerCannotReleaseAnotherViewsActiveGesture() throws {
        let app = try model(row(hints: 1, direct: 2))
        let sessionID = try XCTUnwrap(app.session?.id), oldOwner = UUID(), newOwner = UUID()
        app.setBoardInputActivity(oldOwner, active: true, sessionID: sessionID)
        app.setBoardInputActivity(oldOwner, active: true, sessionID: sessionID)
        app.setBoardInputActivity(newOwner, active: true, sessionID: sessionID)
        app.setBoardInputActivity(oldOwner, active: false, sessionID: sessionID)
        app.setBoardInputActivity(UUID(), active: false, sessionID: sessionID)
        app.setBoardInputActivity(oldOwner, active: false, sessionID: sessionID)
        XCTAssertTrue(app.boardInputInProgress)
        app.direct()
        XCTAssertEqual(app.session?.found.count, 0)
        app.setBoardInputActivity(newOwner, active: false, sessionID: sessionID)
        XCTAssertFalse(app.boardInputInProgress)
        app.direct()
        XCTAssertEqual(app.session?.found.count, 1)
    }

    @MainActor func testNewSessionDropsOldGateAndLateOldSessionCallbacksCannotChangeNewOwner() throws {
        let app = try model(row(hints: 1, direct: 2))
        let oldSession = try XCTUnwrap(app.session?.id), oldOwner = UUID(), newOwner = UUID()
        app.setBoardInputActivity(oldOwner, active: true, sessionID: oldSession)
        app.start(level: 2)
        let newSession = try XCTUnwrap(app.session?.id)
        XCTAssertNotEqual(newSession, oldSession)
        XCTAssertFalse(app.boardInputInProgress)
        app.setBoardInputActivity(oldOwner, active: true, sessionID: oldSession)
        XCTAssertFalse(app.boardInputInProgress)
        app.setBoardInputActivity(newOwner, active: true, sessionID: newSession)
        app.setBoardInputActivity(oldOwner, active: false, sessionID: oldSession)
        app.setBoardInputActivity(newOwner, active: false, sessionID: oldSession)
        XCTAssertTrue(app.boardInputInProgress)
        app.direct()
        XCTAssertEqual(app.session?.found.count, 0)
        app.setBoardInputActivity(newOwner, active: false, sessionID: newSession)
        app.direct()
        XCTAssertEqual(app.session?.found.count, 1)
    }

    @MainActor func testBackgroundNavigationAndRestartClearGateWithoutBlockingFreshInput() throws {
        let app = try model(row(hints: 1, direct: 2))
        let sessionID = try XCTUnwrap(app.session?.id), oldOwner = UUID()
        app.setBoardInputActivity(oldOwner, active: true, sessionID: sessionID)
        app.setActive(false)
        XCTAssertFalse(app.boardInputInProgress)
        app.setBoardInputActivity(oldOwner, active: true, sessionID: sessionID)
        XCTAssertFalse(app.boardInputInProgress, "A late background callback must not recreate input ownership")
        app.setActive(true)
        XCTAssertFalse(app.boardInputInProgress)
        let secondOwner = UUID()
        app.setBoardInputActivity(secondOwner, active: true, sessionID: sessionID)
        app.setBoardInputActivity(oldOwner, active: false, sessionID: sessionID)
        XCTAssertTrue(app.boardInputInProgress)
        app.screen = .checkIn
        XCTAssertFalse(app.boardInputInProgress)
        app.setBoardInputActivity(secondOwner, active: true, sessionID: sessionID)
        XCTAssertFalse(app.boardInputInProgress)
        app.screen = .game
        XCTAssertFalse(app.boardInputInProgress)
        let restartOwner = UUID()
        app.setBoardInputActivity(restartOwner, active: true, sessionID: sessionID)
        app.restart()
        let restartedSession = try XCTUnwrap(app.session?.id)
        XCTAssertNotEqual(restartedSession, sessionID)
        XCTAssertFalse(app.boardInputInProgress)
        let currentOwner = UUID()
        app.setBoardInputActivity(currentOwner, active: true, sessionID: restartedSession)
        app.setBoardInputActivity(restartOwner, active: false, sessionID: sessionID)
        XCTAssertTrue(app.boardInputInProgress)
        app.setBoardInputActivity(currentOwner, active: false, sessionID: restartedSession)
        app.direct()
        XCTAssertEqual(app.session?.found.count, 1)
        XCTAssertNil(app.errorMessage)
    }

    @MainActor func testDisabledAndLockedFreeRewardRemainVisibleButCannotBeClaimed() throws {
        for (enabled, state) in [(false, ReferenceButtonState.disabled), (true, .disabled), (true, .locked)] {
            var config = try row()
            config.levelStartFreeAd.enabled = enabled
            config.levelStartFreeAd.buttonState = state
            let rewards = InputGateRewards(), app = try model(config, rewards: rewards)
            XCTAssertTrue(app.levelStartFreeVisible)
            XCTAssertFalse(app.levelStartFreeAvailable)
            let before = app.progress
            app.levelStartFree(); app.offer(.levelStartFree)
            XCTAssertEqual(app.progress, before)
            assertNoOffer(app, rewards)
        }
    }

    @MainActor func testHiddenOrGloballyDisabledAdsHideFreeRewardAndDoNotRequestIt() throws {
        for adsOff in [false, true] {
            var config = try row()
            if adsOff { config.adsEnabled = false }
            else { config.levelStartFreeAd.visible = false; config.levelStartFreeAd.buttonState = .hidden }
            let rewards = InputGateRewards(), app = try model(config, rewards: rewards)
            XCTAssertFalse(app.levelStartFreeVisible)
            XCTAssertFalse(app.levelStartFreeAvailable)
            let before = app.progress
            app.levelStartFree(); app.offer(.levelStartFree)
            XCTAssertEqual(app.progress, before)
            assertNoOffer(app, rewards)
        }
    }

    @MainActor func testExhaustedFreeRewardQuotaStaysVisibleAndDuplicateCallbacksCannotGrantAgain() async throws {
        let rewards = InputGateRewards(), app = try model(row(), rewards: rewards)
        XCTAssertTrue(app.levelStartFreeVisible)
        XCTAssertTrue(app.levelStartFreeAvailable)
        let before = app.progress.availableHints
        app.levelStartFree(); app.levelStartFree()
        XCTAssertEqual(rewards.displays.count, 1)
        let display = try XCTUnwrap(rewards.displays.first)
        XCTAssertEqual(display.kind, .levelStartFree)
        display.callback(.earned); display.callback(.earned)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(app.progress.availableHints, before + 2)
        XCTAssertEqual(app.progress.rewardLedger.count, 1)
        XCTAssertEqual(app.progress.rewardLedger[display.id]?.state, .executed)
        XCTAssertEqual(app.progress.levelStartFreeRewardsRemaining, 0)
        XCTAssertTrue(app.levelStartFreeVisible)
        XCTAssertFalse(app.levelStartFreeAvailable)
        let after = app.progress
        app.levelStartFree(); app.offer(.levelStartFree)
        display.callback(.earned); display.callback(.cancelled)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(rewards.displays.count, 1)
        XCTAssertEqual(app.progress, after)
        XCTAssertTrue(app.analytics.events.filter { $0.eventName == "buff_use" }.isEmpty,
                      "Granting a free tool is not consuming one")
    }
}
