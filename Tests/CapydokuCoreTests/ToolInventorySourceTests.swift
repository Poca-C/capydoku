import XCTest
@testable import CapydokuCore

final class ToolInventorySourceTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func puzzle(_ level: Int = 3) throws -> Puzzle {
        try XCTUnwrap(JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent("Resources/levels.json"))).first { $0.id == level })
    }
    private func configuration() throws -> DemoConfig {
        var row = try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/reference-gameplay-synthetic-row.json")))
        row.adsEnabled = true
        row.directFind.initialFreeCount = 0
        row.directFind.firstUnlockBonusCount = 0
        row.directFind.regrantPolicy = .oncePerLevel
        row.hint.initialFreeCount = 0
        row.hint.firstUnlockBonusCount = 0
        row.hint.regrantPolicy = .oncePerLevel
        row.levelStartFreeAd.enabled = true
        row.levelStartFreeAd.visible = true
        row.levelStartFreeAd.freeCount = 1
        row.levelStartFreeAd.rewardCount = 2
        row.levelStartFreeAd.buttonState = .enabled
        row.levelStartFreeAd.resetPolicy = .oncePerLevel
        return DemoConfig(referenceGameplay: row)
    }
    private func store() -> SaveStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capy-tool-source-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return SaveStore(directory: folder)
    }
    private func roundTrip(_ progress: PlayerProgress) throws -> PlayerProgress {
        try JSONDecoder().decode(PlayerProgress.self, from: JSONEncoder().encode(progress))
    }
    private func modified(_ progress: PlayerProgress, _ modify: (inout [String: Any]) -> Void) throws -> PlayerProgress {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as! [String: Any]
        modify(&json)
        return try JSONDecoder().decode(PlayerProgress.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testConfigurationAndFirstUnlockGrantsKeepDistinctSourcesAcrossRestartAndSave() throws {
        var config = try configuration()
        config.referenceGameplay?.directFind.initialFreeCount = 1
        config.referenceGameplay?.directFind.firstUnlockBonusCount = 1
        config.referenceGameplay?.hint.initialFreeCount = 1
        config.referenceGameplay?.hint.firstUnlockBonusCount = 1
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle(), config: config)
        XCTAssertEqual(progress.nextDirectSource, .levelConfigFree)
        XCTAssertEqual(progress.nextHintSource, .levelConfigFree)
        XCTAssertNotNil(progress.directFind())
        XCTAssertTrue(progress.consumeHint())
        XCTAssertEqual(progress.nextDirectSource, .initialFree)
        XCTAssertEqual(progress.nextHintSource, .initialFree)
        progress.restart()
        let persistence = store()
        try persistence.save(progress)
        progress = persistence.load().progress
        XCTAssertEqual(progress.availableDirect, 1)
        XCTAssertEqual(progress.availableHints, 1)
        XCTAssertEqual(progress.nextDirectSource, .initialFree)
        XCTAssertEqual(progress.nextHintSource, .initialFree)
        XCTAssertNotNil(progress.directFind())
        XCTAssertTrue(progress.consumeHint())
        XCTAssertNil(progress.nextDirectSource)
        XCTAssertNil(progress.nextHintSource)
    }

    func testRetainedSourceOrderAndEveryAttemptGrantsFollowInventoryWithoutCloningArchivedStock() throws {
        var config = try configuration()
        config.referenceGameplay?.hint.inventoryAcrossLevels = .retain
        config.referenceGameplay?.hint.regrantPolicy = .everyAttempt
        config.referenceGameplay?.hint.initialFreeCount = 1
        config.referenceGameplay?.hint.firstUnlockBonusCount = 1
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle(3), config: config)
        XCTAssertTrue(progress.consumeHint())
        progress.restart()
        progress = try roundTrip(progress)
        XCTAssertEqual(progress.availableHints, 2)
        XCTAssertEqual(progress.nextHintSource, .initialFree)
        XCTAssertTrue(progress.consumeHint())
        XCTAssertEqual(progress.nextHintSource, .levelConfigFree)
        progress.begin(puzzle: try puzzle(4), config: config)
        XCTAssertEqual(progress.availableHints, 2)
        XCTAssertTrue(progress.consumeHint())
        progress.begin(puzzle: try puzzle(3), config: config)
        XCTAssertEqual(progress.availableHints, 2, "one carried use plus the new attempt grant; the archived level balance must not be cloned")
        XCTAssertEqual(progress.nextHintSource, .levelConfigFree)
        config.referenceGameplay?.hint.inventoryAcrossLevels = .reset
        progress.begin(puzzle: try puzzle(4), config: config)
        XCTAssertEqual(progress.availableHints, 1)
        XCTAssertEqual(progress.nextHintSource, .levelConfigFree)
    }

    func testCheckInAndInterruptedAdvertisementRemainDistinctInsideBonusPool() throws {
        for kind in [RewardKind.direct, .hint] {
            var config = try configuration()
            config.checkInCycleDays = 1
            config.cycleDirectReward = 1
            config.dailyHintReward = 1
            var progress = PlayerProgress()
            progress.begin(puzzle: try puzzle(), config: config)
            let persistence = store()
            XCTAssertTrue(try persistence.prepareReward(offerID: "ad", kind: kind, progress: &progress))
            XCTAssertTrue(try persistence.markRewardReceived(offerID: "ad", progress: &progress))
            _ = progress.claimCheckIn(on: Date(timeIntervalSince1970: 86_400), config: config)
            try persistence.save(progress)
            let loaded = persistence.load()
            XCTAssertEqual(loaded.recoveredRewardCount, 1)
            progress = loaded.progress
            XCTAssertEqual(try persistence.grantReward(offerID: "ad", progress: &progress), .duplicate)
            if kind == .direct {
                XCTAssertEqual(progress.availableDirect, 2)
                XCTAssertEqual(progress.nextDirectSource, .initialFree)
                XCTAssertNotNil(progress.directFind())
                XCTAssertEqual(progress.nextDirectSource, .rewardedAd)
                progress.restart()
                XCTAssertEqual(progress.nextDirectSource, .rewardedAd)
            } else {
                XCTAssertEqual(progress.availableHints, 2)
                XCTAssertEqual(progress.nextHintSource, .initialFree)
                XCTAssertTrue(progress.consumeHint())
                XCTAssertEqual(progress.nextHintSource, .rewardedAd)
                progress.restart()
                XCTAssertEqual(progress.nextHintSource, .rewardedAd)
            }
            try persistence.save(progress)
            XCTAssertEqual(persistence.load().progress, progress)
        }
    }

    func testLevelStartAdUsesOriginalPoolPriorityAndHonorsResetOrRetain() throws {
        for carry in [ReferenceInventoryCarry.reset, .retain] {
            var config = try configuration()
            config.referenceGameplay?.hint.initialFreeCount = 1
            config.referenceGameplay?.hint.inventoryAcrossLevels = .retain
            config.referenceGameplay?.levelStartFreeAd.reward = .hint
            config.referenceGameplay?.levelStartFreeAd.inventoryAcrossLevels = carry
            let persistence = store()
            var progress = PlayerProgress()
            progress.begin(puzzle: try puzzle(3), config: config)
            XCTAssertTrue(try persistence.prepareReward(offerID: "start", kind: .levelStartFree, progress: &progress))
            XCTAssertEqual(try persistence.grantReward(offerID: "start", progress: &progress), .inventoryGranted)
            XCTAssertEqual(progress.nextHintSource, carry == .reset ? .rewardedAd : .levelConfigFree)
            XCTAssertTrue(progress.consumeHint())
            XCTAssertEqual(progress.nextHintSource, .rewardedAd)
            progress.restart()
            try persistence.save(progress)
            progress = persistence.load().progress
            XCTAssertEqual(progress.nextHintSource, .rewardedAd)
            progress.begin(puzzle: try puzzle(4), config: config)
            XCTAssertEqual(progress.availableHints, carry == .reset ? 2 : 3)
            XCTAssertEqual(progress.nextHintSource, .levelConfigFree)
            while (progress.session?.hintsRemaining ?? 0) > 0 { XCTAssertTrue(progress.consumeHint()) }
            XCTAssertEqual(progress.nextHintSource, carry == .reset ? nil : .rewardedAd)
        }
    }

    func testImmediateRewardHintAndColdStartCompensationAreRewardedAndIdempotent() throws {
        let persistence = store()
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle(), config: try configuration())
        XCTAssertTrue(try persistence.prepareReward(offerID: "hint", kind: .hint, progress: &progress))
        XCTAssertEqual(try persistence.grantReward(offerID: "hint", progress: &progress), .hintReady)
        XCTAssertEqual(progress.nextHintSource, .rewardedAd)
        let loaded = persistence.load()
        XCTAssertEqual(loaded.recoveredRewardCount, 1)
        progress = loaded.progress
        XCTAssertFalse(progress.session!.pendingRewardHint)
        XCTAssertEqual(progress.nextHintSource, .rewardedAd)
        XCTAssertEqual(persistence.load().recoveredRewardCount, 0)
        XCTAssertEqual(try persistence.grantReward(offerID: "hint", progress: &progress), .duplicate)
        XCTAssertTrue(progress.consumeHint())
        XCTAssertEqual(progress.availableHints, 0)
        XCTAssertNil(progress.nextHintSource)
    }

    func testLegacyMixedStockIsPreservedUnknownAndNewGrantsRemainTrackable() throws {
        var config = try configuration()
        config.referenceGameplay?.hint.initialFreeCount = 1
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle(), config: config)
        progress.bonusHints = 2
        progress.bonusDirect = 2
        progress = try modified(progress) { json in
            ["bonusToolSources", "levelToolSources", "carriedToolSources"].forEach { json.removeValue(forKey: $0) }
        }
        XCTAssertEqual(progress.availableHints, 3)
        XCTAssertEqual(progress.availableDirect, 2)
        XCTAssertNil(progress.nextHintSource)
        XCTAssertNil(progress.nextDirectSource)
        _ = progress.claimCheckIn(on: Date(timeIntervalSince1970: 86_400), config: DemoConfig(dailyHintReward: 1))
        for _ in 0..<3 {
            XCTAssertNil(progress.nextHintSource)
            XCTAssertTrue(progress.consumeHint())
        }
        XCTAssertEqual(progress.nextHintSource, .initialFree)
        XCTAssertEqual(progress.availableHints, 1)
        let persistence = store()
        try persistence.save(progress)
        XCTAssertEqual(persistence.load().progress.nextHintSource, .initialFree)
        XCTAssertEqual(persistence.load().progress.availableDirect, 2)
    }

    func testPublicStockChangesInvalidateAttributionWithoutRemovingInventory() throws {
        var config = try configuration()
        config.referenceGameplay?.hint.initialFreeCount = 2
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle(), config: config)
        _ = progress.claimCheckIn(on: Date(timeIntervalSince1970: 86_400), config: DemoConfig(dailyHintReward: 1))
        XCTAssertEqual(progress.nextHintSource, .levelConfigFree)
        XCTAssertTrue(progress.session!.consumeHint(), "legacy direct session use bypasses the provenance mutation")
        XCTAssertNil(progress.nextHintSource)
        XCTAssertTrue(progress.consumeHint())
        XCTAssertEqual(progress.nextHintSource, .initialFree)
        progress.bonusHints += 2
        XCTAssertNil(progress.nextHintSource)
        XCTAssertEqual(progress.availableHints, 3)
        progress = try roundTrip(progress)
        XCTAssertNil(progress.nextHintSource)
        XCTAssertEqual(progress.availableHints, 3)
        for _ in 0..<3 { XCTAssertTrue(progress.consumeHint()) }
        XCTAssertEqual(progress.availableHints, 0)
    }

    func testMalformedAndOverflowingAttributionCannotRejectAnOtherwiseValidSave() throws {
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle(), config: try configuration())
        progress.bonusHints = 2
        let invalidQueues: [Any] = [
            "not a ledger",
            ["hints": ["batches": [["source": "rewarded_ad", "count": -1]]], "direct": ["batches": []]],
            ["hints": ["batches": [["source": "rewarded_ad", "count": Int.max], ["source": "initial_free", "count": 1]]], "direct": ["batches": []]],
            ["hints": ["batches": [["source": "invented_enum", "count": 2]]], "direct": ["batches": []]]
        ]
        for invalid in invalidQueues {
            var restored = try modified(progress) { $0["bonusToolSources"] = invalid }
            let persistence = store()
            try persistence.save(restored)
            restored = persistence.load().progress
            XCTAssertEqual(restored.availableHints, 2)
            XCTAssertNil(restored.nextHintSource)
            XCTAssertTrue(restored.consumeHint())
            XCTAssertNil(restored.nextHintSource)
            XCTAssertEqual(restored.availableHints, 1)
        }
    }
}
