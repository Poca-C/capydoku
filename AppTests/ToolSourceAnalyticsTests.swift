import XCTest
import CapydokuCore
@testable import Capydoku

private final class SourceTestRewards: RewardProvider {
    var callbacks: [(RewardSignal) -> Void] = []
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) {
        callbacks.append(completion)
    }
}

private final class SourceTestIdentity: AnalyticsIdentityStore {
    var identity: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { identity }
    func save(_ identity: AnalyticsIdentity) -> Bool { self.identity = identity; return true }
}

final class ToolSourceAnalyticsTests: XCTestCase {
    private var identities: [String: SourceTestIdentity] = [:]
    private func directory() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    private func configuration() throws -> DemoConfig {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
        var row = try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: url))
        row.adsEnabled = true
        row.hint.initialFreeCount = 0; row.hint.firstUnlockBonusCount = 0
        row.hint.regrantPolicy = .never
        row.directFind.initialFreeCount = 0; row.directFind.firstUnlockBonusCount = 0
        row.directFind.regrantPolicy = .never
        row.directFind.enabled = true; row.directFind.visible = true
        row.directFind.unlockLevel = 1; row.directFind.buttonState = .enabled
        row.directFind.rewardedAdEnabled = true; row.hint.rewardedAdEnabled = true
        return DemoConfig(referenceGameplay: row)
    }
    @MainActor private func model(_ directory: URL, config: DemoConfig,
                                  rewards: SourceTestRewards? = nil) -> AppModel {
        let identity = identities[directory.path] ?? SourceTestIdentity()
        identities[directory.path] = identity
        let app = AppModel(saveDirectory: directory, rewardProvider: rewards, runsTimer: false,
                           feedbackEnabled: false, analyticsIdentityStore: identity)
        app.analytics.acceptConsent()
        XCTAssertTrue(app.analytics.enabled, app.analytics.lastError ?? "Analytics did not initialize after consent.")
        app.progress.tutorialCompleted = true; app.config = config
        if app.session == nil { app.start(level: 1) } else { app.startOrContinue() }
        app.notice = nil
        return app
    }
    @MainActor private func uses(_ app: AppModel, type: String) -> [AnalyticsRecorder.Event] {
        app.analytics.events.filter { $0.eventName == "buff_use" && $0.parameters["buff_type"] == .text(type) }
    }

    @MainActor func testConfiguredFreeAndFirstUnlockGrantHaveDifferentSources() throws {
        var config = try configuration()
        config.referenceGameplay?.hint.initialFreeCount = 1
        config.referenceGameplay?.hint.firstUnlockBonusCount = 1
        config.referenceGameplay?.hint.regrantPolicy = .oncePerLevel
        config.referenceGameplay?.directFind.initialFreeCount = 1
        config.referenceGameplay?.directFind.regrantPolicy = .oncePerLevel
        let app = model(directory(), config: config)
        app.showHint(); XCTAssertNotNil(app.hint)
        app.hint = nil; app.showHint(); XCTAssertNotNil(app.hint)
        let hints = uses(app, type: "hint")
        XCTAssertEqual(hints.count, 2)
        XCTAssertEqual(hints.map { $0.parameters["source"] }, [.text("level_config_free"), .text("initial_free")])
        XCTAssertEqual(hints.map { $0.parameters["inventory_after"] }, [.integer(1), .integer(0)])
        app.hint = nil; app.direct()
        XCTAssertEqual(uses(app, type: "direct_find").last?.parameters["source"], .text("level_config_free"))
    }

    @MainActor func testRetainedLevelStartAdRewardReportsRewardedSourceAfterReload() async throws {
        var config = try configuration()
        config.referenceGameplay?.levelStartFreeAd.enabled = true
        config.referenceGameplay?.levelStartFreeAd.visible = true
        config.referenceGameplay?.levelStartFreeAd.buttonState = .enabled
        config.referenceGameplay?.levelStartFreeAd.freeCount = 1
        config.referenceGameplay?.levelStartFreeAd.reward = .directFind
        config.referenceGameplay?.levelStartFreeAd.rewardCount = 2
        config.referenceGameplay?.levelStartFreeAd.inventoryAcrossLevels = .retain
        let dir = directory(), provider = SourceTestRewards()
        let app = model(dir, config: config, rewards: provider)
        app.levelStartFree()
        XCTAssertEqual(provider.callbacks.count, 1)
        let reward = try XCTUnwrap(provider.callbacks.first)
        reward(.earned); reward(.earned)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(app.progress.availableDirect, 2)
        XCTAssertTrue(uses(app, type: "direct_find").isEmpty, "A grant alone is not a tool use.")
        let restored = model(dir, config: config)
        restored.direct()
        let event = try XCTUnwrap(uses(restored, type: "direct_find").last)
        XCTAssertEqual(event.parameters["source"], .text("rewarded_ad"))
        XCTAssertEqual(event.parameters["inventory_before"], .integer(2))
        XCTAssertEqual(event.parameters["inventory_after"], .integer(1))
    }

    @MainActor func testInterruptedConfirmedDirectRewardKeepsSourceThroughCompensation() throws {
        let dir = directory(), config = try configuration()
        let app = model(dir, config: config)
        let puzzle = try XCTUnwrap(app.session?.puzzle)
        let store = SaveStore(directory: dir, packagedPuzzle: { $0 == puzzle.id ? puzzle : nil })
        XCTAssertTrue(try store.prepareReward(offerID: "confirmed-before-exit", kind: .direct, progress: &app.progress))
        XCTAssertTrue(try store.markRewardReceived(offerID: "confirmed-before-exit", progress: &app.progress))
        let restored = model(dir, config: config)
        XCTAssertEqual(restored.progress.availableDirect, 1)
        restored.direct(); restored.direct()
        let events = uses(restored, type: "direct_find")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.parameters["source"], .text("rewarded_ad"))
        XCTAssertEqual(restored.progress.availableDirect, 0)
    }

    @MainActor func testRewardedHintPreviewAndApplyRetainSourceAfterBackgroundAndReload() async throws {
        let dir = directory(), config = try configuration(), provider = SourceTestRewards()
        let app = model(dir, config: config, rewards: provider)
        app.showHint(); XCTAssertEqual(provider.callbacks.count, 1)
        app.setActive(false)
        try XCTUnwrap(provider.callbacks.first)(.earned)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(app.hint)
        let restored = model(dir, config: config)
        let marks = restored.session?.marks
        restored.showHint(); XCTAssertNotNil(restored.hint)
        XCTAssertEqual(restored.session?.marks, marks)
        _ = restored.progress.claimCheckIn(config: config)
        restored.applyHint(); restored.applyHint()
        let events = uses(restored, type: "hint")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map { $0.parameters["source"] }, [.text("rewarded_ad"), .text("rewarded_ad")])
        XCTAssertEqual(events.map { $0.parameters["applied"] }, [.flag(false), .flag(true)])
        XCTAssertNotEqual(restored.session?.marks, marks)
    }

    @MainActor func testCheckInGiftIsFreeWithoutInventingARewardedEvent() throws {
        let config = try configuration(), app = model(directory(), config: try configuration())
        _ = app.progress.claimCheckIn(config: config)
        app.showHint()
        XCTAssertNotNil(app.hint)
        XCTAssertEqual(uses(app, type: "hint").first?.parameters["source"], .text("initial_free"))
    }

    @MainActor func testUnknownLegacyBalanceRemainsUsableAndIsVisibleInDiagnostics() throws {
        let dir = directory(), config = try configuration()
        let app = model(dir, config: config)
        // Models a pre-provenance balance. Neither a grant nor a receipt proves its source.
        app.progress.bonusHints = 1; app.save()
        let restored = model(dir, config: config)
        restored.showHint(); XCTAssertNotNil(restored.hint)
        restored.applyHint(); restored.applyHint()
        XCTAssertEqual(restored.progress.availableHints, 0)
        XCTAssertTrue(uses(restored, type: "hint").isEmpty)
        XCTAssertEqual(restored.unattributedToolUseCount, 1)
        restored.exportDiagnostics()
        let data = try Data(contentsOf: XCTUnwrap(restored.exportURL))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["unattributedToolUsesSinceLaunch"] as? Int, 1)
    }
}
