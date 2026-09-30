import XCTest
import CapydokuCore
@testable import Capydoku

private final class RoutingRewards: RewardProvider {
    var completion: ((RewardSignal) -> Void)?
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) { self.completion = completion }
}

final class AppModelFeedbackRoutingTests: XCTestCase {
    @MainActor func testStartupTutorialSettingsHintAndResultReachThePlayerAsDistinctContexts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(saveDirectory: root, runsTimer: false, feedbackEnabled: false, startupBypassForTesting: false)
        app.start(level: 1)
        XCTAssertEqual(app.currentAudioEnvironment.page, .startup)
        app.startupReady()
        XCTAssertEqual(app.currentAudioEnvironment.page, .game)
        XCTAssertEqual(app.currentAudioEnvironment.overlay, .tutorial)
        app.skipTutorial()
        XCTAssertEqual(app.currentAudioEnvironment.overlay, .none)
        app.sheet = .settings
        XCTAssertEqual(app.currentAudioEnvironment.page, .settings)
        XCTAssertEqual(app.currentAudioEnvironment.overlay, .settings)
        XCTAssertEqual(app.currentAudioEnvironment.blocks, [.inputLocked])
        app.sheet = nil; app.showHint()
        XCTAssertEqual(app.currentAudioEnvironment.page, .game)
        XCTAssertEqual(app.currentAudioEnvironment.overlay, .hint)
        XCTAssertEqual(app.currentAudioEnvironment.blocks, [.inputLocked])
        app.applyHint()
        XCTAssertEqual(app.currentAudioEnvironment.blocks, [])
        for cell in try XCTUnwrap(app.session).puzzle.solution { app.submit(cell) }
        XCTAssertEqual(app.currentAudioEnvironment.overlay, .won)
        XCTAssertEqual(app.currentAudioEnvironment.blocks, [.inputLocked])
        app.home()
        XCTAssertEqual(app.currentAudioEnvironment.page, .home)
        XCTAssertEqual(app.currentAudioEnvironment.overlay, .none)
        XCTAssertNil(app.currentAudioEnvironment.level)
        app.screen = .checkIn
        XCTAssertEqual(app.currentAudioEnvironment.page, .checkIn)
    }

    @MainActor func testAdCompletionWhileBackgroundedCannotRemoveTheBackgroundAudioBlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RoutingRewards()
        let app = AppModel(saveDirectory: root, rewardProvider: provider, runsTimer: false, feedbackEnabled: false)
        app.progress.tutorialCompleted = true; app.start(level: 1)
        let puzzle = try XCTUnwrap(app.session).puzzle
        for cell in puzzle.regions.indices.filter({ !puzzle.solution.contains($0) }).prefix(3) { app.submit(cell) }
        XCTAssertEqual(app.currentAudioEnvironment.overlay, .lost)
        app.revive()
        XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.advertisement))
        app.setActive(false)
        XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.background))
        try XCTUnwrap(provider.completion)(.earned)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(app.session?.status, .playing)
        XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
        XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.background))
        app.setActive(true)
        XCTAssertEqual(app.currentAudioEnvironment.page, .game)
        XCTAssertEqual(app.currentAudioEnvironment.overlay, .none)
        XCTAssertEqual(app.currentAudioEnvironment.blocks, [])
    }
}
