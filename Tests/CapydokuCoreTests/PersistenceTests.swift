import XCTest
import CryptoKit
@testable import CapydokuCore

final class PersistenceTests: XCTestCase {
    private var directory: URL!
    private var store: SaveStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CapydokuTests-\(UUID())")
        store = SaveStore(directory: directory)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func progress(level: Int = 1, noFreeTools: Bool = false) throws -> PlayerProgress {
        var progress = PlayerProgress()
        progress.begin(puzzle: try PuzzleGenerator.generate(level: level),
                       config: DemoConfig(hintsPerLevel: noFreeTools ? 0 : 1,
                                          directPerLevel: noFreeTools ? 0 : 1))
        return progress
    }

    func testFreshInstallIsNotReportedAsCorruption() {
        let result = store.load()
        XCTAssertEqual(result.source, .fresh)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.progress, PlayerProgress())
    }

    func testGeneratedBoardAndEntireSessionRestoreUnchanged() throws {
        var progress = try progress(level: 151)
        let solution = progress.session!.puzzle.solution
        _ = progress.session?.submit(cell: solution[0])
        let wrong = (0..<36).first { !solution.contains($0) }!
        _ = progress.session?.submit(cell: wrong)
        progress.session?.advanceTime(by: 42)
        progress.settings.musicEnabled = false
        progress.bonusHints = 9
        _ = progress.claimCheckIn(on: Date(timeIntervalSince1970: 100 * 86_400))
        progress.captureSessionBalance()
        try store.save(progress)
        let restored = store.load()
        XCTAssertEqual(restored.source, .primary)
        XCTAssertEqual(restored.progress, progress)
        XCTAssertEqual(restored.progress.session?.puzzle.seed, progress.session?.puzzle.seed)
        XCTAssertEqual(restored.progress.session?.puzzle.regions, progress.session?.puzzle.regions)
    }

    func testCorruptPrimaryFallsBackWithoutReplacingGoodBackup() throws {
        var progress = try progress()
        try store.save(progress)
        let backupState = progress
        progress.bonusHints = 5
        try store.save(progress)
        let goodBackup = try Data(contentsOf: store.backupURL)
        try Data("broken primary".utf8).write(to: store.primaryURL)
        let result = store.load()
        XCTAssertEqual(result.source, .backup)
        XCTAssertEqual(result.progress, backupState)
        XCTAssertNotNil(result.warning)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), goodBackup)
        XCTAssertEqual(store.load().progress, backupState)
        let preserved = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("preserved") }
        XCTAssertEqual(preserved.count, 1)
    }

    func testBothCorruptFilesRemainUntilExplicitSaveAndArePreserved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let primary = Data("primary-corrupt".utf8)
        let backup = Data("backup-corrupt".utf8)
        try primary.write(to: store.primaryURL)
        try backup.write(to: store.backupURL)
        let result = store.load()
        XCTAssertEqual(result.source, .resetAfterCorruption)
        XCTAssertEqual(try Data(contentsOf: store.primaryURL), primary)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
        try store.save(result.progress)
        XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("preserved") }
        XCTAssertEqual(try Data(contentsOf: preserved[0]), primary)
    }

    func testChecksumRejectsOtherwiseValidJSON() throws {
        try store.save(try progress())
        var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: store.primaryURL)) as! [String: Any]
        envelope["checksum"] = "incorrect"
        try JSONSerialization.data(withJSONObject: envelope).write(to: store.primaryURL)
        XCTAssertEqual(store.load().source, .resetAfterCorruption)
    }

    func testMigrationPreservesLegacyInventoryAndCompletion() throws {
        var expected = try progress()
        expected.unlockedLevel = 42
        expected.completedLevels = [1, 3, 41]
        expected.bonusHints = 7
        expected.bonusDirect = 4
        expected.checkIn = CheckInState(lastClaimedDay: 500, streak: 6, cycleDay: 6)
        let payload = try JSONEncoder().encode(expected)
        try writeEnvelope(payload: payload, schema: 1)
        let result = store.load()
        XCTAssertTrue(result.didMigrate)
        XCTAssertEqual(result.progress, expected)
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: store.primaryURL)) as! [String: Any]
        XCTAssertEqual(envelope["schemaVersion"] as? Int, SaveStore.currentSchemaVersion)
    }

    func testMigrationMissingTrackingFieldsUsesDefaults() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["unlockedLevel": 12, "bonusHints": 3,
                                                                 "completedLevels": [1, 2, 3]])
        try writeEnvelope(payload: payload, schema: 1)
        let result = store.load()
        XCTAssertTrue(result.didMigrate)
        XCTAssertEqual(result.progress.unlockedLevel, 12)
        XCTAssertEqual(result.progress.bonusHints, 3)
        XCTAssertEqual(result.progress.completedLevels, [1, 2, 3])
    }

    func testUnsupportedSchemaRetainsOriginal() throws {
        try writeEnvelope(payload: JSONEncoder().encode(PlayerProgress()), schema: 999)
        let original = try Data(contentsOf: store.primaryURL)
        let result = store.load()
        XCTAssertEqual(result.source, .resetAfterCorruption)
        XCTAssertEqual(try Data(contentsOf: store.primaryURL), original)
        try store.save(PlayerProgress())
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("preserved") }
        XCTAssertEqual(try Data(contentsOf: preserved[0]), original)
    }

    func testTransactionWriteFailureDoesNotMutateMemory() throws {
        try Data("not a directory".utf8).write(to: directory)
        var progress = PlayerProgress()
        XCTAssertThrowsError(try store.transaction(progress: &progress) { $0.bonusHints += 1 })
        XCTAssertEqual(progress.bonusHints, 0)
    }

    func testDirectRewardDuplicateCallbackNeverRevealsTwice() throws {
        var progress = try progress(noFreeTools: true)
        XCTAssertTrue(try store.prepareReward(offerID: "one", kind: .direct, progress: &progress))
        XCTAssertFalse(try store.prepareReward(offerID: "two", kind: .direct, progress: &progress))
        let outcome = try store.grantReward(offerID: "one", progress: &progress)
        guard case .directRevealed = outcome else { return XCTFail("Expected direct reward") }
        XCTAssertEqual(progress.session?.found.count, 1)
        XCTAssertEqual(progress.bonusDirect, 0)
        XCTAssertEqual(try store.grantReward(offerID: "one", progress: &progress), .duplicate)
        XCTAssertEqual(progress.session?.found.count, 1)
        XCTAssertEqual(store.load().progress.session?.found.count, 1)
        XCTAssertFalse(try store.prepareReward(offerID: "one", kind: .direct, progress: &progress))
    }

    func testInterruptedRewardReceiptCompensatesOnlyOnceWithoutBoardMutation() throws {
        for kind in [RewardKind.direct, .hint] {
            var progress = try progress(noFreeTools: true)
            let id = "interrupted-\(kind)"
            XCTAssertTrue(try store.prepareReward(offerID: id, kind: kind, progress: &progress))
            XCTAssertTrue(try store.markRewardReceived(offerID: id, progress: &progress))
            let loaded = store.load()
            XCTAssertEqual(loaded.recoveredRewardCount, 1)
            XCTAssertEqual(loaded.progress.session?.found.count, 0)
            XCTAssertEqual(loaded.progress.bonusHints, kind == .hint ? 1 : 0)
            XCTAssertEqual(loaded.progress.bonusDirect, kind == .direct ? 1 : 0)
            XCTAssertEqual(loaded.progress.rewardLedger[id]?.state, .compensated)
            let loadedAgain = store.load()
            XCTAssertEqual(loadedAgain.recoveredRewardCount, 0)
            XCTAssertEqual(loadedAgain.progress, loaded.progress)
            var recovered = loadedAgain.progress
            XCTAssertEqual(try store.grantReward(offerID: id, progress: &recovered), .duplicate)
        }
    }

    func testHintRewardOpensCreditWithoutApplyingMarksThenConsumesExactlyOnce() throws {
        var progress = try progress(noFreeTools: true)
        _ = try store.prepareReward(offerID: "hint", kind: .hint, progress: &progress)
        XCTAssertEqual(try store.grantReward(offerID: "hint", progress: &progress), .hintReady)
        XCTAssertTrue(progress.session?.marks.isEmpty == true)
        XCTAssertEqual(progress.availableHints, 1)
        XCTAssertTrue(progress.consumeHint())
        XCTAssertFalse(progress.consumeHint())
        XCTAssertEqual(progress.availableHints, 0)
        XCTAssertTrue(progress.session?.marks.isEmpty == true)
        try store.save(progress)
        XCTAssertEqual(store.load().progress.bonusHints, 0)
    }

    func testUnpresentedHintRewardSurvivesRelaunchAsOneBonus() throws {
        var progress = try progress(noFreeTools: true)
        _ = try store.prepareReward(offerID: "hint-pending", kind: .hint, progress: &progress)
        _ = try store.grantReward(offerID: "hint-pending", progress: &progress)
        let loaded = store.load()
        XCTAssertEqual(loaded.progress.bonusHints, 1)
        XCTAssertEqual(loaded.progress.session?.pendingRewardHint, false)
        XCTAssertEqual(store.load().progress.bonusHints, 1)
    }

    func testRewardWithoutUsefulHintBecomesOnePersistentBonus() throws {
        var progress = try progress(noFreeTools: true)
        _ = try store.prepareReward(offerID: "no-hint-left", kind: .hint, progress: &progress)
        let solution = progress.session!.puzzle.solution
        _ = progress.session?.markMany((0..<16).filter { !solution.contains($0) })
        XCTAssertEqual(try store.grantReward(offerID: "no-hint-left", progress: &progress), .compensated)
        XCTAssertFalse(progress.session?.pendingRewardHint == true)
        XCTAssertEqual(progress.bonusHints, 1)
        XCTAssertEqual(try store.grantReward(offerID: "no-hint-left", progress: &progress), .duplicate)
        XCTAssertEqual(store.load().progress.bonusHints, 1)
    }

    func testCancelledAndUnreceivedRewardsNeverPayOut() throws {
        var progress = try progress(noFreeTools: true)
        _ = try store.prepareReward(offerID: "cancel", kind: .direct, progress: &progress)
        XCTAssertTrue(try store.cancelReward(offerID: "cancel", progress: &progress))
        XCTAssertEqual(try store.grantReward(offerID: "cancel", progress: &progress), .ignored)
        _ = try store.prepareReward(offerID: "kill-before-callback", kind: .direct, progress: &progress)
        let loaded = store.load()
        XCTAssertEqual(loaded.progress.bonusDirect, 0)
        XCTAssertEqual(loaded.progress.rewardLedger["kill-before-callback"]?.state, .cancelled)
    }

    func testReviveRepeatedAcrossDeathsIsExactlyOncePerOfferAndNeverReplayedOnLoad() throws {
        var progress = try progress(noFreeTools: true)
        let solution = progress.session!.puzzle.solution
        let wrong = (0..<16).filter { !solution.contains($0) }
        for round in 0..<2 {
            for cell in wrong.dropFirst(round * 3).prefix(3) { _ = progress.session?.submit(cell: cell) }
            XCTAssertEqual(progress.session?.status, .lost)
            let id = "revive-\(round)"
            _ = try store.prepareReward(offerID: id, kind: .revive, progress: &progress)
            XCTAssertEqual(try store.grantReward(offerID: id, progress: &progress), .revived)
            XCTAssertEqual(try store.grantReward(offerID: id, progress: &progress), .duplicate)
            XCTAssertEqual(progress.session?.lives, 3)
            XCTAssertEqual(progress.session?.errors.count, (round + 1) * 3)
        }
        for cell in wrong.dropFirst(6).prefix(3) { _ = progress.session?.submit(cell: cell) }
        _ = try store.prepareReward(offerID: "interrupted-revive", kind: .revive, progress: &progress)
        _ = try store.markRewardReceived(offerID: "interrupted-revive", progress: &progress)
        let loaded = store.load()
        XCTAssertEqual(loaded.progress.session?.status, .lost)
        XCTAssertEqual(loaded.progress.session?.lives, 0)
        XCTAssertEqual(loaded.progress.rewardLedger["interrupted-revive"]?.state, .cancelled)
        XCTAssertEqual(loaded.progress.bonusDirect, 0)
        XCTAssertEqual(loaded.progress.bonusHints, 0)
    }

    func testCheckInDuplicatePreventionSurvivesProcessRestartAndClockRollback() throws {
        var progress = PlayerProgress()
        let date = Date(timeIntervalSince1970: 1_000 * 86_400)
        _ = try store.transaction(progress: &progress) { $0.claimCheckIn(on: date) }
        progress = store.load().progress
        XCTAssertEqual(progress.claimCheckIn(on: date), .alreadyClaimed)
        XCTAssertEqual(progress.claimCheckIn(on: date.addingTimeInterval(-86_400)), .clockRollback)
        XCTAssertEqual(progress.bonusHints, 1)
    }

    private func writeEnvelope(payload: Data, schema: Int) throws {
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let envelope: [String: Any] = ["schemaVersion": schema,
                                       "payload": payload.base64EncodedString(), "checksum": checksum]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: envelope).write(to: store.primaryURL)
    }
}
