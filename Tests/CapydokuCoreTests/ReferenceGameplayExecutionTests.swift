import XCTest
@testable import CapydokuCore

final class ReferenceGameplayExecutionTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func row() throws -> ReferenceLevelGameplay {
        try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/reference-gameplay-synthetic-row.json")))
    }
    private func puzzle(_ level: Int = 1) throws -> Puzzle {
        try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent("Resources/levels.json"))).first { $0.id == level }!
    }
    private func store() -> SaveStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capy-reference-execution-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return SaveStore(directory: folder)
    }
    private func freeConfig(policy: ReferenceGrantPolicy = .oncePerLevel, carry: ReferenceInventoryCarry = .retain) throws -> DemoConfig {
        var reference = try row()
        reference.adsEnabled = true
        reference.hint.initialFreeCount = 0
        reference.hint.regrantPolicy = .never
        reference.directFind.initialFreeCount = 0
        reference.directFind.regrantPolicy = .never
        reference.levelStartFreeAd.enabled = true
        reference.levelStartFreeAd.visible = true
        reference.levelStartFreeAd.buttonState = .enabled
        reference.levelStartFreeAd.freeCount = 2
        reference.levelStartFreeAd.reward = .hint
        reference.levelStartFreeAd.rewardCount = 3
        reference.levelStartFreeAd.resetPolicy = policy
        reference.levelStartFreeAd.inventoryAcrossLevels = carry
        return DemoConfig(referenceGameplay: reference)
    }

    func testImportedGrantsUnlockBonusCarryAndRestartPolicies() throws {
        var reference = try row()
        reference.directFind.firstUnlockBonusCount = 3
        reference.hint.firstUnlockBonusCount = 2
        let config = DemoConfig(hintsPerLevel: 99, directPerLevel: 99, referenceGameplay: reference)
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle(), config: config)
        XCTAssertEqual(progress.availableDirect, 5)
        XCTAssertEqual(progress.availableHints, 3)
        progress.restart()
        XCTAssertEqual(progress.availableDirect, 5, "once-per-level does not regrant on restart")
        XCTAssertEqual(progress.availableHints, 4, "every-attempt grants one new use; unlock bonus is once")
        progress.begin(puzzle: try puzzle(2), config: config)
        XCTAssertEqual(progress.availableDirect, 7, "retain carries five and level two grants two")
        XCTAssertEqual(progress.availableHints, 1, "reset discards previous level inventory")
        progress.begin(puzzle: try puzzle(), config: config)
        XCTAssertEqual(progress.availableDirect, 7, "returning to a level must not clone its archived balance")
        XCTAssertEqual(progress.availableHints, 1)
        var never = reference
        never.directFind.regrantPolicy = .never
        never.directFind.firstUnlockBonusCount = 0
        never.hint.regrantPolicy = .never
        never.hint.firstUnlockBonusCount = 0
        var fresh = PlayerProgress()
        fresh.begin(puzzle: try puzzle(), config: DemoConfig(hintsPerLevel: 99, directPerLevel: 99, referenceGameplay: never))
        XCTAssertEqual(fresh.availableDirect, 0)
        XCTAssertEqual(fresh.availableHints, 0)
    }

    func testLockedToolAndDisabledAdsCannotBeUsedThroughCore() throws {
        var reference = try row()
        reference.directFind.enabled = false
        reference.directFind.buttonState = .locked
        reference.directFind.initialFreeCount = 0
        var progress = PlayerProgress()
        progress.bonusDirect = 4
        progress.begin(puzzle: try puzzle(), config: DemoConfig(referenceGameplay: reference))
        XCTAssertNil(progress.directFind())
        XCTAssertEqual(progress.bonusDirect, 4)
        XCTAssertFalse(progress.canReceiveReward(.direct))
        XCTAssertFalse(progress.canReceiveReward(.levelStartFree))
    }

    func testFreeAdCreditsInventoryWithoutBoardActionAndCannotBeFarmed() throws {
        let persistence = store()
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle(), config: try freeConfig())
        let board = progress.session!
        XCTAssertEqual(progress.levelStartFreeRewardsRemaining, 2)
        XCTAssertTrue(try persistence.prepareReward(offerID: "cancelled", kind: .levelStartFree, progress: &progress))
        XCTAssertTrue(try persistence.cancelReward(offerID: "cancelled", progress: &progress))
        XCTAssertEqual(progress.levelStartFreeRewardsRemaining, 2)
        for id in ["first", "second"] {
            XCTAssertTrue(try persistence.prepareReward(offerID: id, kind: .levelStartFree, progress: &progress))
            XCTAssertEqual(try persistence.grantReward(offerID: id, progress: &progress), .inventoryGranted)
            XCTAssertEqual(try persistence.grantReward(offerID: id, progress: &progress), .duplicate)
        }
        XCTAssertEqual(progress.availableHints, 6)
        XCTAssertEqual(progress.session?.found, board.found)
        XCTAssertEqual(progress.session?.marks, board.marks)
        XCTAssertEqual(progress.session?.score, board.score)
        XCTAssertEqual(progress.levelStartFreeRewardsRemaining, 0)
        XCTAssertFalse(try persistence.prepareReward(offerID: "third", kind: .levelStartFree, progress: &progress))
        progress.restart()
        XCTAssertEqual(progress.levelStartFreeRewardsRemaining, 0)
        XCTAssertEqual(progress.availableHints, 6)
        progress.begin(puzzle: try puzzle(2), config: try freeConfig())
        XCTAssertEqual(progress.levelStartFreeRewardsRemaining, 2)
        XCTAssertEqual(progress.availableHints, 6, "retained ad reward survives even when the normal hint inventory resets")
    }

    func testFreeAdResetInventoryIsSeparateFromRetainedOrdinaryInventory() throws {
        var config = try freeConfig(carry: .reset)
        config.referenceGameplay?.hint.inventoryAcrossLevels = .retain
        config.referenceGameplay?.hint.initialFreeCount = 2
        config.referenceGameplay?.hint.regrantPolicy = .oncePerLevel
        let persistence = store()
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle(), config: config)
        XCTAssertTrue(try persistence.prepareReward(offerID: "scoped", kind: .levelStartFree, progress: &progress))
        XCTAssertEqual(try persistence.grantReward(offerID: "scoped", progress: &progress), .inventoryGranted)
        XCTAssertEqual(progress.availableHints, 5)
        XCTAssertTrue(progress.consumeHint())
        XCTAssertEqual(progress.availableHints, 4)
        XCTAssertEqual(progress.session?.hintsRemaining, 2, "expiring reward pool is consumed first")
        progress.restart()
        XCTAssertEqual(progress.availableHints, 4)
        progress.begin(puzzle: try puzzle(2), config: config)
        XCTAssertEqual(progress.availableHints, 4, "two remaining ad uses expire; normal retained two plus new two remain")
    }

    func testEveryAttemptAndNeverResetAdQuotas() throws {
        for policy in [ReferenceGrantPolicy.everyAttempt, .never] {
            let persistence = store()
            var progress = PlayerProgress()
            let config = try freeConfig(policy: policy)
            progress.begin(puzzle: try puzzle(), config: config)
            for id in ["a", "b"] {
                XCTAssertTrue(try persistence.prepareReward(offerID: id, kind: .levelStartFree, progress: &progress))
                _ = try persistence.grantReward(offerID: id, progress: &progress)
            }
            progress.restart()
            XCTAssertEqual(progress.levelStartFreeRewardsRemaining, policy == .everyAttempt ? 2 : 0)
            progress.begin(puzzle: try puzzle(2), config: config)
            XCTAssertEqual(progress.levelStartFreeRewardsRemaining, policy == .everyAttempt ? 2 : 0)
        }
    }

    func testInterruptedFreeAdRecoversSnapshotExactlyOnceAndPersistsConfiguration() throws {
        for carry in [ReferenceInventoryCarry.retain, .reset] {
            let persistence = store()
            let config = try freeConfig(carry: carry)
            var progress = PlayerProgress()
            progress.begin(puzzle: try puzzle(), config: config)
            XCTAssertTrue(try persistence.prepareReward(offerID: "interrupted", kind: .levelStartFree, progress: &progress))
            XCTAssertTrue(try persistence.markRewardReceived(offerID: "interrupted", progress: &progress))
            let loaded = persistence.load()
            XCTAssertEqual(loaded.recoveredRewardCount, 1)
            XCTAssertEqual(loaded.progress.availableHints, 3)
            XCTAssertEqual(loaded.progress.session?.found.count, 0)
            XCTAssertEqual(loaded.progress.session?.config.referenceGameplay, config.referenceGameplay)
            XCTAssertEqual(loaded.progress.levelStartFreeRewardsRemaining, 1)
            let again = persistence.load()
            XCTAssertEqual(again.recoveredRewardCount, 0)
            XCTAssertEqual(again.progress.availableHints, 3)
            var resumed = again.progress
            XCTAssertEqual(try persistence.grantReward(offerID: "interrupted", progress: &resumed), .duplicate)
        }
    }

    func testFreeRevivePreservesBoardAndQuotaSurvivesSaveRestartAndLevelChange() throws {
        for policy in [ReferenceGrantPolicy.oncePerLevel, .everyAttempt, .never] {
            var reference = try row()
            reference.revive.freeCount = 1
            reference.revive.resetPolicy = policy
            let config = DemoConfig(referenceGameplay: reference)
            let persistence = store()
            var progress = PlayerProgress()
            progress.begin(puzzle: try puzzle(), config: config)
            let firstAnimal = progress.session!.puzzle.solution[0]
            _ = progress.session?.submit(cell: firstAnimal)
            let wrong = progress.session!.puzzle.regions.indices.first { !progress.session!.puzzle.solution.contains($0) }!
            for _ in 0..<3 { _ = progress.session?.submit(cell: wrong) }
            let before = progress.session!
            XCTAssertEqual(before.status, .lost)
            XCTAssertEqual(progress.freeRevivesRemaining, 1)
            XCTAssertTrue(try persistence.transaction(progress: &progress) { $0.useFreeRevive() })
            XCTAssertEqual(progress.session?.lives, reference.startingLives)
            XCTAssertEqual(progress.session?.found, before.found)
            XCTAssertEqual(progress.session?.marks, before.marks)
            XCTAssertEqual(progress.session?.errors, before.errors)
            XCTAssertEqual(progress.session?.score, before.score)
            XCTAssertEqual(progress.freeRevivesRemaining, 0)
            XCTAssertFalse(progress.useFreeRevive())
            progress = persistence.load().progress
            XCTAssertEqual(progress.freeRevivesRemaining, 0)
            progress.restart()
            XCTAssertEqual(progress.freeRevivesRemaining, policy == .everyAttempt ? 1 : 0)
            progress.begin(puzzle: try puzzle(2), config: config)
            XCTAssertEqual(progress.freeRevivesRemaining, policy == .never ? 0 : 1)
        }
    }

    func testOlderSavesDecodeWithoutReferenceFields() throws {
        var progress = PlayerProgress()
        progress.begin(puzzle: try puzzle())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as! [String: Any]
        json.removeValue(forKey: "referenceToolGrantKeys")
        json.removeValue(forKey: "carriedToolBalance")
        json.removeValue(forKey: "levelStartLocalBalances")
        json.removeValue(forKey: "freeReviveUsage")
        var session = json["session"] as! [String: Any]
        var config = session["config"] as! [String: Any]
        config.removeValue(forKey: "referenceGameplay")
        session["config"] = config
        json["session"] = session
        let restored = try JSONDecoder().decode(PlayerProgress.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.availableHints, 1)
        XCTAssertNil(restored.session?.config.referenceGameplay)
        XCTAssertTrue(restored.referenceToolGrantKeys.isEmpty)
        XCTAssertEqual(restored.levelStartFreeRewardsRemaining, 0)
        XCTAssertNoThrow(try store().save(restored))
    }
}
