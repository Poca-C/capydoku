import XCTest
import CapydokuCore
@testable import Capydoku

private final class TestInterstitial: InterstitialProvider {
    var completions: [(InterstitialSignal) -> Void] = []
    func present(completion: @escaping (InterstitialSignal) -> Void) { completions.append(completion) }
}
final class OriginalFlowTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func row() throws -> ReferenceLevelGameplay {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
        return try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: url))
    }
    @MainActor func testAsyncSnapshotsCannotOverwriteNewerRewardAndBackgroundFlushesLatestState() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(saveDirectory: root, runsTimer: true, feedbackEnabled: false)
        app.progress.tutorialCompleted = true; app.start(level: 1)
        for _ in 0..<25 { app.toggle(0); app.toggle(2) }
        app.showHint(); XCTAssertNotNil(app.hint); app.closeHint()
        app.showHint() // Transaction must flush queued gesture/hint snapshots before its offer.
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNotNil(app.hint)
        let receiptCount = app.progress.rewardLedger.count
        XCTAssertEqual(receiptCount, 1)
        app.applyHint(); app.setActive(false)
        let restored = AppModel(saveDirectory: root, runsTimer: false, feedbackEnabled: false)
        XCTAssertNil(restored.errorMessage); XCTAssertNil(restored.notice)
        XCTAssertEqual(restored.progress.rewardLedger, app.progress.rewardLedger)
        XCTAssertEqual(restored.session?.marks, app.session?.marks)
        XCTAssertEqual(restored.progress.availableHints, 0)
    }
    @MainActor func testDuplicateInterstitialCloseShowsChallengeOnceThenEntersElevenWithoutRewards() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = TestInterstitial()
        let app = AppModel(saveDirectory: root, runsTimer: false, feedbackEnabled: false, interstitialProvider: provider)
        var reference = try row()
        reference.adsEnabled = true; reference.interstitial.enabled = true
        reference.interstitial.startLevel = 10; reference.interstitial.frequency = 1
        reference.interstitial.cooldownSeconds = 0; reference.interstitial.onNextLevel = true
        app.config = DemoConfig(referenceGameplay: reference)
        app.progress.tutorialCompleted = true; app.start(level: 10)
        for cell in try XCTUnwrap(app.session).puzzle.solution { app.submit(cell) }
        XCTAssertEqual(app.session?.status, .won)
        let inventory = app.progress.availableHints
        app.next(); app.next()
        XCTAssertEqual(provider.completions.count, 1)
        XCTAssertTrue(app.interstitialBusy); XCTAssertFalse(app.challengePending)
        XCTAssertEqual(app.session?.puzzle.id, 10)
        provider.completions[0](.closed); provider.completions[0](.closed)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(app.interstitialBusy); XCTAssertTrue(app.challengePending)
        XCTAssertEqual(app.session?.puzzle.id, 10)
        XCTAssertEqual(app.progress.availableHints, inventory)
        XCTAssertTrue(app.progress.rewardLedger.isEmpty)
        app.continueChallenge(); app.continueChallenge()
        XCTAssertEqual(app.session?.puzzle.id, 11)
        XCTAssertFalse(app.challengePending)
        try Data("damaged".utf8).write(to: root.appendingPathComponent("win-ad-state.json"))
        try Data("damaged".utf8).write(to: root.appendingPathComponent("challenge-state.json"))
        let restored = AppModel(saveDirectory: root, runsTimer: false, feedbackEnabled: false, interstitialProvider: provider)
        restored.config = DemoConfig(referenceGameplay: reference); restored.start(level: 10)
        for cell in try XCTUnwrap(restored.session).puzzle.solution { restored.submit(cell) }
        restored.next(); XCTAssertTrue(restored.interstitialBusy)
        provider.completions[1](.closed)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(restored.challengePending)
        XCTAssertEqual(restored.session?.puzzle.id, 11)
    }

    @MainActor func testUnavailableAlternateBoardCannotSilentlyRestartTheSameBoard() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(saveDirectory: root, runsTimer: false, feedbackEnabled: false)
        var reference = try row(); reference.failure.restartCreatesNewBoard = true
        app.config = DemoConfig(referenceGameplay: reference); app.start(level: 1)
        let original = app.progress
        app.restart()
        XCTAssertEqual(app.progress, original)
        XCTAssertNotNil(app.errorMessage)
    }
    @MainActor func testFreeReviveUsesConfiguredQuotaBeforeAnySimulatedAd() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(saveDirectory: root, runsTimer: false, feedbackEnabled: false)
        var reference = try row(); reference.revive.freeCount = 1; reference.revive.resetPolicy = .oncePerLevel
        app.config = DemoConfig(referenceGameplay: reference); app.progress.tutorialCompleted = true; app.start(level: 1)
        let puzzle = try XCTUnwrap(app.session).puzzle
        for cell in puzzle.regions.indices.filter({ !puzzle.solution.contains($0) }).prefix(3) { app.submit(cell) }
        XCTAssertEqual(app.session?.status, .lost)
        let marks = app.session?.marks
        XCTAssertTrue(app.reviveAvailable); XCTAssertFalse(app.reviveNeedsVideo)
        app.revive(); app.revive()
        XCTAssertEqual(app.session?.lives, reference.startingLives)
        XCTAssertEqual(app.session?.marks, marks)
        XCTAssertEqual(app.progress.freeRevivesRemaining, 0)
        XCTAssertTrue(app.progress.rewardLedger.isEmpty)
        XCTAssertNil(app.sheet)
        let restored = AppModel(saveDirectory: root, runsTimer: false, feedbackEnabled: false)
        XCTAssertEqual(restored.progress.freeRevivesRemaining, 0)
        XCTAssertEqual(restored.session?.marks, marks)
    }
}
