import XCTest
import CapydokuCore
@testable import Capydoku

private final class ControlledRewards: RewardProvider {
    var offers: [(String, (RewardSignal) -> Void)] = []
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) {
        offers.append((offerID, completion))
    }
}

final class AppModelTests: XCTestCase {
    @MainActor private func model(directory: URL, provider: ControlledRewards = .init(), timeout: Double = 1) -> AppModel {
        let model = AppModel(saveDirectory: directory, rewardProvider: provider, rewardTimeout: timeout,
                             runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true
        if model.session == nil { model.start(level: 1) }
        else { model.startOrContinue() }
        return model
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func drainCallbacks() async { try? await Task.sleep(nanoseconds: 30_000_000) }
    @MainActor private func exhaustHint(_ model: AppModel) {
        model.showHint(); XCTAssertNotNil(model.hint)
        model.hint = nil
        XCTAssertEqual(model.progress.availableHints, 0)
    }

    @MainActor func testMissingCallbackTimesOutAndLateSuccessCannotAffectNewOffer() async {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ControlledRewards()
        let app = model(directory: dir, provider: provider, timeout: 0.25)
        exhaustHint(app)
        app.offer(.hint); app.runReward(); app.runReward()
        XCTAssertEqual(provider.offers.count, 1)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(app.rewardBusy); XCTAssertNil(app.sheet)
        XCTAssertTrue(app.notice?.contains("timed out") == true)
        XCTAssertEqual(app.progress.rewardLedger[provider.offers[0].0]?.state, .cancelled)
        XCTAssertEqual(app.progress.availableHints, 0)
        app.notice = nil; app.offer(.hint); app.runReward()
        provider.offers[0].1(.earned)
        await drainCallbacks()
        XCTAssertTrue(app.rewardBusy); XCTAssertEqual(app.sheet, .reward)
        XCTAssertEqual(app.progress.availableHints, 0)
        provider.offers[1].1(.earned)
        await drainCallbacks()
        XCTAssertFalse(app.rewardBusy); XCTAssertNotNil(app.hint)
        XCTAssertEqual(app.progress.rewardLedger[provider.offers[1].0]?.state, .executed)
        app.hint = nil
        provider.offers[0].1(.earned); provider.offers[1].1(.earned)
        await drainCallbacks()
        XCTAssertNil(app.hint); XCTAssertEqual(app.progress.availableHints, 0)
    }

    @MainActor func testBackgroundCallbackIsSavedAndRecoveredExactlyOnce() async {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ControlledRewards(); let app = model(directory: dir, provider: provider)
        exhaustHint(app); app.offer(.hint); app.runReward(); app.setActive(false)
        let callback = provider.offers[0].1
        DispatchQueue.global().async { callback(.earned); callback(.earned) }
        await drainCallbacks()
        XCTAssertNil(app.hint); XCTAssertEqual(app.progress.availableHints, 1)
        let board = app.session?.marks
        let restored = model(directory: dir)
        XCTAssertEqual(restored.progress.availableHints, 1); XCTAssertEqual(restored.session?.marks, board)
        restored.notice = nil; restored.showHint()
        XCTAssertNotNil(restored.hint); XCTAssertEqual(restored.progress.availableHints, 0)
        restored.hint = nil; restored.loadProgress()
        XCTAssertEqual(restored.progress.availableHints, 0)
    }

    @MainActor func testHintReentrySettingsAndRepeatedApplyAreIdempotent() {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = model(directory: dir)
        app.showHint(); let hint = app.hint
        for _ in 0..<30 { app.showHint(); app.submit(0); app.toggle(2) }
        XCTAssertEqual(app.hint, hint); XCTAssertEqual(app.session?.lives, 3)
        XCTAssertEqual(app.session?.marks, []); XCTAssertEqual(app.progress.availableHints, 0)
        app.sheet = .settings; app.applyHint()
        XCTAssertEqual(app.session?.marks, []); XCTAssertNotNil(app.hint)
        app.sheet = nil; app.setActive(false); app.applyHint()
        XCTAssertEqual(app.session?.marks, [])
        app.setActive(true); app.applyHint(); let expected = app.session?.marks
        XCTAssertFalse(expected?.isEmpty ?? true)
        for _ in 0..<30 { app.applyHint() }
        XCTAssertEqual(app.session?.marks, expected); XCTAssertNil(app.hint)
        XCTAssertEqual(app.progress.availableHints, 0)
    }

    @MainActor func testCorruptionRestoresBackupAndTotalCorruptionReturnsHome() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = model(directory: dir)
        app.toggle(0); app.toggle(2)
        let store = SaveStore(directory: dir)
        try Data("broken".utf8).write(to: store.primaryURL)
        app.loadProgress()
        XCTAssertEqual(app.session?.marks, [0]); XCTAssertNotNil(app.notice)
        XCTAssertEqual(app.screen, .game)
        try Data("broken".utf8).write(to: store.primaryURL)
        try Data("broken".utf8).write(to: store.backupURL)
        app.loadProgress()
        XCTAssertNil(app.session); XCTAssertEqual(app.screen, .home)
        XCTAssertTrue(app.notice?.contains("No valid save") == true)
        app.notice = nil; app.startOrContinue()
        XCTAssertNotNil(app.session); XCTAssertNil(app.errorMessage)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("progress.preserved-") })
    }

    @MainActor func testReloadCancelsPendingAdapterAndStaleReceiptCannotChangeRestoredBoard() async {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ControlledRewards(); let app = model(directory: dir, provider: provider)
        exhaustHint(app); app.offer(.hint); app.runReward()
        app.loadProgress()
        XCTAssertFalse(app.rewardBusy); XCTAssertNil(app.sheet)
        XCTAssertEqual(app.progress.rewardLedger[provider.offers[0].0]?.state, .cancelled)
        let restored = app.progress
        provider.offers[0].1(.earned)
        await drainCallbacks()
        XCTAssertEqual(app.progress, restored)
    }

    @MainActor func testStorageFailureRetainsReceiptAndRetriesWithoutRequestingAnotherReward() async throws {
        let dir = directory(), moved = directory()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: moved) }
        let provider = ControlledRewards(); let app = model(directory: dir, provider: provider)
        exhaustHint(app); app.offer(.hint); app.runReward()
        try FileManager.default.moveItem(at: dir, to: moved)
        try Data("blocked storage".utf8).write(to: dir)
        provider.offers[0].1(.earned)
        await drainCallbacks()
        XCTAssertTrue(app.rewardRetryPending); XCTAssertFalse(app.rewardBusy)
        XCTAssertEqual(app.sheet, .reward); XCTAssertNotNil(app.errorMessage)
        XCTAssertEqual(app.progress.availableHints, 0)
        provider.offers[0].1(.cancelled) // A contradictory late signal must not replace the earned result.
        await drainCallbacks()
        XCTAssertTrue(app.rewardRetryPending)
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.moveItem(at: moved, to: dir)
        app.runReward()
        XCTAssertNil(app.errorMessage)
        XCTAssertFalse(app.rewardRetryPending); XCTAssertNil(app.sheet)
        XCTAssertEqual(provider.offers.count, 1); XCTAssertNotNil(app.hint)
        XCTAssertEqual(app.progress.rewardLedger[provider.offers[0].0]?.state, .executed)
        app.hint = nil; provider.offers[0].1(.earned)
        await drainCallbacks()
        XCTAssertNil(app.hint); XCTAssertEqual(app.progress.availableHints, 0)
    }
}
