import XCTest
@testable import CapydokuCore

final class RewardAdEventPersistenceTests: XCTestCase {
    private var directory: URL!
    private var store: SaveStore!
    private let offer = Data([0, 255, 1])
    private let receipt = Data([0, 255, 2])
    private let started = Data([0, 255, 3])
    private let terminal = Data([0, 255, 4])

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RewardAdEvents-\(UUID())")
        store = SaveStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func progress() throws -> PlayerProgress {
        var progress = PlayerProgress()
        progress.begin(puzzle: try PuzzleGenerator.generate(level: 1),
                       config: DemoConfig(hintsPerLevel: 0, directPerLevel: 0))
        return progress
    }

    private func persistedProgress() throws -> PlayerProgress {
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.primaryURL)) as? [String: Any])
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        return try JSONDecoder().decode(PlayerProgress.self, from: payload)
    }

    private func blockBackupWrite() throws {
        if FileManager.default.fileExists(atPath: store.backupURL.path) {
            try FileManager.default.removeItem(at: store.backupURL)
        }
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: true)
    }

    func testLegacyDecoderPreservesEveryExistingFieldAndDerivesPendingOffer() throws {
        let original = RewardRecord(id: "legacy-full", kind: .levelStartFree, state: .rewarded,
            sessionID: UUID(), createdAt: Date(timeIntervalSince1970: 123_456), inventoryTool: .hint,
            inventoryCount: 4, inventoryCarry: .retain, quotaKey: "original-quota", levelID: 12,
            analyticsOffer: offer, completionEvent: receipt)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "analyticsOfferPending")
        json.removeValue(forKey: "pendingAdEvents")
        let restored = try JSONDecoder().decode(RewardRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored, original)
        XCTAssertTrue(restored.analyticsOfferPending)
        XCTAssertTrue(restored.pendingAdEvents.isEmpty)

        let minimal = Data(#"{"id":"old","kind":"direct","state":"cancelled","createdAt":0}"#.utf8)
        let old = try JSONDecoder().decode(RewardRecord.self, from: minimal)
        XCTAssertNil(old.sessionID)
        XCTAssertNil(old.inventoryTool)
        XCTAssertNil(old.inventoryCount)
        XCTAssertNil(old.inventoryCarry)
        XCTAssertNil(old.quotaKey)
        XCTAssertNil(old.levelID)
        XCTAssertNil(old.analyticsOffer)
        XCTAssertNil(old.completionEvent)
        XCTAssertFalse(old.analyticsOfferPending)
        XCTAssertTrue(old.pendingAdEvents.isEmpty)
    }

    func testOfferAcknowledgementPersistsFlagButRetainsAttributionSnapshot() throws {
        var progress = try progress()
        XCTAssertFalse(RewardRecord(id: "no-context", kind: .direct, sessionID: nil).analyticsOfferPending)
        _ = try store.prepareReward(offerID: "offer", kind: .direct, progress: &progress, analyticsOffer: offer)
        XCTAssertTrue(try XCTUnwrap(persistedProgress().rewardLedger["offer"]).analyticsOfferPending)
        try store.transaction(progress: &progress) { $0.rewardLedger["offer"]?.analyticsOfferPending = false }
        let acknowledged = try XCTUnwrap(persistedProgress().rewardLedger["offer"])
        XCTAssertFalse(acknowledged.analyticsOfferPending)
        XCTAssertEqual(acknowledged.analyticsOffer, offer)
        let restored = store.load().progress
        XCTAssertFalse(try XCTUnwrap(restored.rewardLedger["offer"]).analyticsOfferPending)
        XCTAssertEqual(restored.rewardLedger["offer"]?.analyticsOffer, offer)
        XCTAssertEqual(restored.rewardLedger["offer"]?.state, .cancelled)
    }

    func testStartedEventTransactionWriteFailureRollsBackMemoryAndPreservesPrimary() throws {
        var progress = try progress()
        _ = try store.prepareReward(offerID: "offer", kind: .direct, progress: &progress, analyticsOffer: offer)
        let id = UUID().uuidString
        let before = progress
        let primary = try Data(contentsOf: store.primaryURL)
        try blockBackupWrite()
        XCTAssertThrowsError(try store.transaction(progress: &progress) { $0.rewardLedger["offer"]?.pendingAdEvents[id] = started })
        XCTAssertEqual(progress, before)
        XCTAssertEqual(try Data(contentsOf: store.primaryURL), primary)
        try FileManager.default.removeItem(at: store.backupURL)
        try store.transaction(progress: &progress) { $0.rewardLedger["offer"]?.pendingAdEvents[id] = started }
        XCTAssertEqual(try persistedProgress().rewardLedger["offer"]?.pendingAdEvents, [id: started])
        XCTAssertEqual(progress.rewardLedger["offer"]?.state, .offered)
        XCTAssertEqual(progress.availableDirect, 0)
    }

    func testCancelAndEventsCommitTogetherAfterWriteRetryWithoutReplacingStartedOrPayingReward() throws {
        var progress = try progress()
        let startID = UUID().uuidString, endID = UUID().uuidString
        _ = try store.prepareReward(offerID: "offer", kind: .direct, progress: &progress, analyticsOffer: offer)
        try store.transaction(progress: &progress) { $0.rewardLedger["offer"]?.pendingAdEvents[startID] = started }
        let before = progress
        try blockBackupWrite()
        XCTAssertThrowsError(try store.cancelReward(offerID: "offer", progress: &progress,
                                                   pendingEvents: [endID: terminal]))
        XCTAssertEqual(progress, before)
        XCTAssertEqual(try persistedProgress(), before)
        try FileManager.default.removeItem(at: store.backupURL)
        XCTAssertTrue(try store.cancelReward(offerID: "offer", progress: &progress,
            pendingEvents: [startID: Data("do not overwrite the first occurrence".utf8), endID: terminal]))
        XCTAssertEqual(progress.rewardLedger["offer"]?.pendingAdEvents, [startID: started, endID: terminal])
        XCTAssertEqual(progress.rewardLedger["offer"]?.state, .cancelled)
        XCTAssertFalse(try store.cancelReward(offerID: "offer", progress: &progress,
                                              pendingEvents: [UUID().uuidString: Data("late duplicate".utf8)]))
        XCTAssertEqual(try store.grantReward(offerID: "offer", progress: &progress), .ignored)
        let restored = store.load()
        XCTAssertEqual(restored.recoveredRewardCount, 0)
        XCTAssertEqual(restored.progress, progress)
        XCTAssertEqual(restored.progress.availableDirect, 0)
        XCTAssertEqual(restored.progress.availableHints, 0)
        XCTAssertTrue(restored.progress.session?.found.isEmpty == true)
    }

    func testColdOfferedCancellationKeepsOnlyKnownEventsAndDoesNotInventTerminalOrReward() throws {
        var progress = try progress()
        let startID = UUID().uuidString
        _ = try store.prepareReward(offerID: "offer", kind: .hint, progress: &progress, analyticsOffer: offer)
        try store.transaction(progress: &progress) { $0.rewardLedger["offer"]?.pendingAdEvents[startID] = started }
        let restored = SaveStore(directory: directory).load()
        XCTAssertEqual(restored.recoveredRewardCount, 0)
        let record = try XCTUnwrap(restored.progress.rewardLedger["offer"])
        XCTAssertEqual(record.state, .cancelled)
        XCTAssertEqual(record.pendingAdEvents, [startID: started])
        XCTAssertTrue(record.analyticsOfferPending)
        XCTAssertEqual(record.analyticsOffer, offer)
        XCTAssertNil(record.completionEvent)
        XCTAssertEqual(restored.progress.availableHints, 0)
        XCTAssertTrue(restored.progress.session?.marks.isEmpty == true)
        XCTAssertEqual(SaveStore(directory: directory).load().progress, restored.progress)
    }

    func testPendingStartedAndReceiptAreDurableTogetherEvenIfEffectCannotBeSaved() throws {
        var progress = try progress()
        let startID = UUID().uuidString
        _ = try store.prepareReward(offerID: "offer", kind: .direct, progress: &progress, analyticsOffer: offer)
        XCTAssertThrowsError(try store.grantReward(offerID: "offer", progress: &progress,
            completionEvent: receipt, pendingEvents: [startID: started]) { candidate, _ in
                candidate.bonusHints = -1
            })
        XCTAssertEqual(progress.rewardLedger["offer"]?.state, .rewarded)
        XCTAssertEqual(progress.rewardLedger["offer"]?.pendingAdEvents, [startID: started])
        XCTAssertEqual(progress.rewardLedger["offer"]?.completionEvent, receipt)
        XCTAssertEqual(try persistedProgress(), progress)
        XCTAssertTrue(progress.session?.found.isEmpty == true)
        let recovered = SaveStore(directory: directory).load()
        XCTAssertEqual(recovered.recoveredRewardCount, 1)
        XCTAssertEqual(recovered.progress.rewardLedger["offer"]?.state, .compensated)
        XCTAssertEqual(recovered.progress.rewardLedger["offer"]?.pendingAdEvents, [startID: started])
        XCTAssertEqual(recovered.progress.rewardLedger["offer"]?.completionEvent, receipt)
        XCTAssertEqual(recovered.progress.availableDirect, 1)
        XCTAssertEqual(SaveStore(directory: directory).load().progress.availableDirect, 1)
    }

    func testRewardedRetryMergesPendingEventsWithEffectAndKeepsFirstFrozenValues() throws {
        var progress = try progress()
        let firstID = UUID().uuidString, secondID = UUID().uuidString
        _ = try store.prepareReward(offerID: "offer", kind: .direct, progress: &progress, analyticsOffer: offer)
        XCTAssertTrue(try store.markRewardReceived(offerID: "offer", progress: &progress,
                                                   completionEvent: receipt, pendingEvents: [firstID: started]))
        XCTAssertFalse(try store.markRewardReceived(offerID: "offer", progress: &progress,
            completionEvent: Data("late receipt".utf8), pendingEvents: [secondID: terminal]))
        XCTAssertEqual(progress.rewardLedger["offer"]?.pendingAdEvents, [firstID: started])
        guard case .directRevealed = try store.grantReward(offerID: "offer", progress: &progress,
            completionEvent: Data("late receipt".utf8),
            pendingEvents: [firstID: Data("late started".utf8), secondID: terminal]) else {
            return XCTFail("Expected one direct effect")
        }
        XCTAssertEqual(progress.rewardLedger["offer"]?.completionEvent, receipt)
        XCTAssertEqual(progress.rewardLedger["offer"]?.pendingAdEvents, [firstID: started, secondID: terminal])
        XCTAssertEqual(progress.session?.found.count, 1)
        XCTAssertEqual(try store.grantReward(offerID: "offer", progress: &progress,
                                            pendingEvents: [UUID().uuidString: Data("late".utf8)]), .duplicate)
        XCTAssertEqual(try persistedProgress(), progress)
    }

    func testReceiptWriteFailureCannotSeparateStartedEventFromRewardConfirmation() throws {
        var progress = try progress()
        _ = try store.prepareReward(offerID: "offer", kind: .hint, progress: &progress, analyticsOffer: offer)
        let before = progress
        let startID = UUID().uuidString
        try blockBackupWrite()
        XCTAssertThrowsError(try store.markRewardReceived(offerID: "offer", progress: &progress,
                                                         completionEvent: receipt, pendingEvents: [startID: started]))
        XCTAssertEqual(progress, before)
        XCTAssertEqual(try persistedProgress(), before)
        try FileManager.default.removeItem(at: store.backupURL)
        XCTAssertTrue(try store.markRewardReceived(offerID: "offer", progress: &progress,
                                                   completionEvent: receipt, pendingEvents: [startID: started]))
        XCTAssertEqual(try persistedProgress().rewardLedger["offer"]?.pendingAdEvents, [startID: started])
        XCTAssertEqual(try persistedProgress().rewardLedger["offer"]?.completionEvent, receipt)
    }

    func testPendingAdEventValidationRejectsInvalidKeysEmptyOversizedAndExcessiveRecords() throws {
        var progress = try progress()
        _ = try store.prepareReward(offerID: "offer", kind: .hint, progress: &progress)
        let before = progress
        let id = UUID().uuidString
        let excessive = Dictionary(uniqueKeysWithValues: (0..<4).map { _ in (UUID().uuidString, Data([1])) })
        for invalid in [["not-a-uuid": Data([1])], [id: Data()], [id: Data(repeating: 1, count: 32_769)], excessive] {
            XCTAssertThrowsError(try store.cancelReward(offerID: "offer", progress: &progress, pendingEvents: invalid))
            XCTAssertEqual(progress, before)
            XCTAssertEqual(try persistedProgress(), before)
        }
        let maximum = Dictionary(uniqueKeysWithValues: (0..<3).map { _ in (UUID().uuidString, Data(repeating: 255, count: 32_768)) })
        XCTAssertTrue(try store.cancelReward(offerID: "offer", progress: &progress, pendingEvents: maximum))
        XCTAssertEqual(store.load().progress.rewardLedger["offer"]?.pendingAdEvents, maximum)
    }
}
