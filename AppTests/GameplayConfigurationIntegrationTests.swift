import XCTest
import CryptoKit
import CapydokuCore
@testable import Capydoku

private final class IntegrationConfigurationProvider: GameplayConfigurationProvider {
    var requests: [GameplayConfigurationRequest] = []
    var callbacks: [(Result<GameplayConfigurationResponse, Error>) -> Void] = []
    func fetch(_ request: GameplayConfigurationRequest,
               completion: @escaping (Result<GameplayConfigurationResponse, Error>) -> Void) -> (() -> Void)? {
        requests.append(request); callbacks.append(completion)
        return nil
    }
}

private final class ConfigurationIntegrationRewards: RewardProvider {
    var callbacks: [(RewardSignal) -> Void] = []
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) { callbacks.append(completion) }
}

final class GameplayConfigurationIntegrationTests: XCTestCase {
    private let target = GameplayConfigurationTarget(appVersion: "synthetic-app-only", environment: "synthetic-integration-only")
    private func directory() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("capy-config-integration-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    @MainActor private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("The expected asynchronous configuration state did not arrive.", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Complete synthetic data is used exclusively by the test bundle, never as
    /// evidence for or a replacement of the missing frozen Pawdoku baseline.
    private func configuration(version: String, freeHints: Int = 1, adsEnabled: Bool = true,
                               rewardCount: Int = 2) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
        var row = try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: url))
        row.adsEnabled = adsEnabled
        row.hint.initialFreeCount = freeHints
        row.hint.regrantPolicy = .oncePerLevel
        row.directFind.inventoryAcrossLevels = .reset
        row.failure.restartCreatesNewBoard = false
        row.levelStartFreeAd.enabled = true; row.levelStartFreeAd.visible = true
        row.levelStartFreeAd.buttonState = .enabled
        row.levelStartFreeAd.freeCount = 1; row.levelStartFreeAd.reward = .hint
        row.levelStartFreeAd.rewardCount = rewardCount
        row.levelStartFreeAd.inventoryAcrossLevels = .retain
        row.levelStartFreeAd.resetPolicy = .oncePerLevel
        var rowJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as! [String: Any]
        rowJSON["bannerReviewEvidenceID"] = NSNull()
        let json: [String: Any] = [
            "schemaVersion": 1, "status": "frozen", "configVersion": version,
            "baseline": ["product": "Pawdoku", "storeVersion": "synthetic-only",
                         "capturedAt": "2026-09-30T00:00:00Z", "device": "synthetic-only", "osVersion": "synthetic-only",
                         "sourceArchiveSHA256": String(repeating: "a", count: 64), "evidenceFiles": ["synthetic-only"]],
            "importedSourceSHA256": String(repeating: "b", count: 64),
            "levels": (1...150).map { ["level": $0, "configuration": rowJSON] }
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
    private func response(_ data: Data, revision: Int = 1) -> GameplayConfigurationResponse {
        GameplayConfigurationResponse(target: target, revision: revision, configurationData: data,
                                      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    @MainActor private func service(_ directory: URL, bundled: Data?, provider: IntegrationConfigurationProvider? = nil) -> GameplayConfigurationStore {
        GameplayConfigurationStore(directory: directory, target: target, bundledData: bundled, provider: provider, timeout: 1)
    }
    @MainActor private func model(_ directory: URL, service: GameplayConfigurationStore,
                                  rewards: ConfigurationIntegrationRewards? = nil) -> AppModel {
        let app = AppModel(saveDirectory: directory, rewardProvider: rewards, runsTimer: false,
                           feedbackEnabled: false, gameplayConfigurationStore: service)
        app.progress.tutorialCompleted = true
        return app
    }

    @MainActor func testDelayedRefreshDoesNotBlockHomeOrChangeCurrentSessionAndAppliesToNextNewGame() async throws {
        let root = directory(), provider = IntegrationConfigurationProvider()
        let bundled = try configuration(version: "synthetic-v1")
        let app = model(root, service: service(root, bundled: bundled, provider: provider))
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(app.screen, .home)
        XCTAssertFalse(app.loading)
        XCTAssertNil(app.errorMessage)
        app.start(level: 1)
        let previous = try XCTUnwrap(app.session)
        provider.callbacks[0](.success(response(try configuration(version: "synthetic-v2", freeHints: 4))))
        try await waitUntil { app.referenceConfiguration?.configVersion == "synthetic-v2" }
        XCTAssertEqual(app.referenceConfiguration?.configVersion, "synthetic-v2")
        XCTAssertEqual(app.session, previous)
        XCTAssertEqual(app.progress.availableHints, 1)
        app.exportDiagnostics()
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(app.exportURL))) as! [String: Any]
        XCTAssertNotNil(report["gameplayConfiguration"])
        XCTAssertEqual((report["referenceGameplay"] as? [String: Any])?["configVersion"] as? String, "synthetic-v2")
        let savedSession = (report["progress"] as? [String: Any])?["session"] as? [String: Any]
        XCTAssertEqual((savedSession?["config"] as? [String: Any])?["version"] as? String, "synthetic-v1")
        app.start(level: 2)
        XCTAssertEqual(app.session?.config.version, "synthetic-v2")
        XCTAssertEqual(app.progress.availableHints, 4)
    }

    @MainActor func testNextLaunchUsesSuccessfulCacheWhenRefreshFailsWithoutBlockingGameplay() async throws {
        let root = directory(), seedProvider = IntegrationConfigurationProvider()
        let bundled = try configuration(version: "synthetic-v1")
        let seed = service(root, bundled: bundled, provider: seedProvider)
        seed.refresh()
        seedProvider.callbacks[0](.success(response(try configuration(version: "synthetic-v2", freeHints: 3))))
        try await waitUntil { seed.configuration?.configVersion == "synthetic-v2" }
        let offline = IntegrationConfigurationProvider()
        let app = model(root, service: service(root, bundled: bundled, provider: offline))
        XCTAssertEqual(app.referenceConfiguration?.configVersion, "synthetic-v2")
        XCTAssertEqual(app.screen, .home)
        offline.callbacks[0](.failure(URLError(.notConnectedToInternet)))
        try await waitUntil { !app.gameplayConfigurationDiagnostics.isRefreshing }
        XCTAssertNil(app.errorMessage)
        app.start(level: 1)
        XCTAssertEqual(app.session?.config.version, "synthetic-v2")
        XCTAssertEqual(app.progress.availableHints, 3)
        let marks = app.session?.marks
        app.toggle(0)
        XCTAssertNotEqual(app.session?.marks, marks, "Offline configuration must still permit a real board action.")
    }

    @MainActor func testContinueRestartAndProcessRestoreKeepSavedSessionWhileLaterLevelUsesCachedUpdate() async throws {
        let root = directory(), provider = IntegrationConfigurationProvider()
        let bundled = try configuration(version: "synthetic-v1")
        let app = model(root, service: service(root, bundled: bundled, provider: provider))
        app.start(level: 1)
        app.progress.session?.toggleMark(at: 0)
        let old = try XCTUnwrap(app.session)
        provider.callbacks[0](.success(response(try configuration(version: "synthetic-v2", freeHints: 5))))
        try await waitUntil { app.referenceConfiguration?.configVersion == "synthetic-v2" }
        app.home(); app.startOrContinue()
        XCTAssertEqual(app.session, old)
        app.setActive(false)
        let restored = model(root, service: service(root, bundled: bundled))
        XCTAssertEqual(restored.referenceConfiguration?.configVersion, "synthetic-v2")
        XCTAssertEqual(restored.session, old)
        restored.startOrContinue()
        XCTAssertEqual(restored.session, old)
        restored.restart()
        XCTAssertEqual(restored.session?.config, old.config)
        XCTAssertEqual(restored.session?.attempt, old.attempt + 1)
        XCTAssertEqual(restored.progress.availableHints, 1)
        restored.start(level: 2)
        XCTAssertEqual(restored.session?.config.version, "synthetic-v2")
        XCTAssertEqual(restored.progress.availableHints, 5)
    }

    @MainActor func testRemoteAdDisableAndRewardChangeCannotRewriteAnInFlightOffer() async throws {
        let root = directory(), provider = IntegrationConfigurationProvider(), rewards = ConfigurationIntegrationRewards()
        let bundled = try configuration(version: "synthetic-v1", rewardCount: 2)
        let app = model(root, service: service(root, bundled: bundled, provider: provider), rewards: rewards)
        app.start(level: 1)
        XCTAssertTrue(app.levelStartFreeAvailable)
        app.levelStartFree()
        XCTAssertEqual(rewards.callbacks.count, 1)
        let offer = try XCTUnwrap(app.progress.rewardLedger.values.first)
        XCTAssertEqual(offer.inventoryCount, 2)
        provider.callbacks[0](.success(response(try configuration(version: "synthetic-v2", freeHints: 4,
                                                                  adsEnabled: false, rewardCount: 7))))
        try await waitUntil { app.referenceConfiguration?.configVersion == "synthetic-v2" }
        XCTAssertTrue(app.rewardBusy)
        XCTAssertEqual(app.progress.rewardLedger[offer.id], offer)
        XCTAssertEqual(app.session?.config.version, "synthetic-v1")
        rewards.callbacks[0](.earned)
        rewards.callbacks[0](.earned)
        try await waitUntil { !app.rewardBusy }
        XCTAssertEqual(app.progress.rewardLedger[offer.id]?.state, .executed)
        XCTAssertEqual(app.progress.availableHints, 3, "one original free hint plus the recorded two-use advertisement reward")
        XCTAssertFalse(app.rewardBusy)
        app.start(level: 2)
        XCTAssertEqual(app.session?.config.version, "synthetic-v2")
        XCTAssertFalse(app.levelStartFreeAvailable)
        app.offer(.levelStartFree)
        XCTAssertEqual(rewards.callbacks.count, 1)
    }

    @MainActor func testMissingOrPendingBaselineKeepsExplicitDemoAndDoesNotFetchInventedReference() throws {
        let pending: [String: Any] = ["schemaVersion": 1, "status": "awaiting_baseline", "configVersion": NSNull(),
                                    "baseline": NSNull(), "importedSourceSHA256": NSNull(),
                                    "levels": (1...150).map { ["level": $0, "configuration": NSNull()] }]
        for data in [nil, try JSONSerialization.data(withJSONObject: pending)] as [Data?] {
            let root = directory(), provider = IntegrationConfigurationProvider()
            let app = model(root, service: service(root, bundled: data, provider: provider))
            XCTAssertNil(app.referenceConfiguration)
            XCTAssertTrue(provider.requests.isEmpty)
            XCTAssertEqual(app.screen, .home)
            XCTAssertNil(app.errorMessage)
            app.start(level: 1)
            XCTAssertEqual(app.session?.config.version, DemoConfig.default.version)
            XCTAssertNil(app.session?.config.referenceGameplay)
            let marks = app.session?.marks
            app.toggle(0)
            XCTAssertNotEqual(app.session?.marks, marks, "Missing reference input must not block the explicit Demo path.")
        }
    }

    @MainActor func testRejectedRefreshKeepsBundledConfigurationAndDoesNotPresentBlockingError() async throws {
        let root = directory(), provider = IntegrationConfigurationProvider()
        let app = model(root, service: service(root, bundled: try configuration(version: "synthetic-v1"), provider: provider))
        var invalid = response(try configuration(version: "synthetic-v2", freeHints: 9))
        invalid.sha256 = String(repeating: "0", count: 64)
        provider.callbacks[0](.success(invalid))
        try await waitUntil { !app.gameplayConfigurationDiagnostics.isRefreshing }
        XCTAssertEqual(app.referenceConfiguration?.configVersion, "synthetic-v1")
        XCTAssertNil(app.errorMessage)
        XCTAssertFalse(app.loading)
        app.start(level: 1)
        XCTAssertEqual(app.session?.config.version, "synthetic-v1")
        XCTAssertEqual(app.progress.availableHints, 1)
    }
}
