import XCTest
@testable import CapydokuCore

final class RewardAnalyticsReceiptTests: XCTestCase {
    private var directory: URL!
    private var store: SaveStore!
    // The storage layer must preserve opaque bytes without interpreting application event JSON.
    private let offer = Data([0, 255, 21, 42])
    private let completion = Data([0, 254, 22, 43])

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RewardAnalyticsReceipt-\(UUID())")
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

    func testOfferAndFirstReceiptPersistBeforeEffectAndDuplicatesCannotReplaceThem() throws {
        var progress = try progress()
        XCTAssertTrue(try store.prepareReward(offerID: "direct", kind: .direct, progress: &progress,
                                              analyticsOffer: offer))
        XCTAssertEqual(try persistedProgress().rewardLedger["direct"]?.analyticsOffer, offer)
        XCTAssertNil(try persistedProgress().rewardLedger["direct"]?.completionEvent)
        XCTAssertFalse(try store.prepareReward(offerID: "direct", kind: .direct, progress: &progress,
                                               analyticsOffer: Data("replacement offer".utf8)))
        XCTAssertTrue(try store.markRewardReceived(offerID: "direct", progress: &progress,
                                                   completionEvent: completion))
        XCTAssertFalse(try store.markRewardReceived(offerID: "direct", progress: &progress,
                                                    completionEvent: Data("replacement receipt".utf8)))
        let received = try persistedProgress()
        XCTAssertEqual(received.rewardLedger["direct"]?.state, .rewarded)
        XCTAssertEqual(received.rewardLedger["direct"]?.analyticsOffer, offer)
        XCTAssertEqual(received.rewardLedger["direct"]?.completionEvent, completion)
        XCTAssertTrue(received.session?.found.isEmpty == true)
        guard case .directRevealed = try store.grantReward(offerID: "direct", progress: &progress,
                                                          completionEvent: Data("late receipt".utf8)) else {
            return XCTFail("Expected exactly one direct reward")
        }
        XCTAssertEqual(try store.grantReward(offerID: "direct", progress: &progress,
                                            completionEvent: Data("duplicate receipt".utf8)), .duplicate)
        let loaded = store.load().progress
        XCTAssertEqual(loaded.session?.found.count, 1)
        XCTAssertEqual(loaded.rewardLedger["direct"]?.analyticsOffer, offer)
        XCTAssertEqual(loaded.rewardLedger["direct"]?.completionEvent, completion)
    }

    func testEffectSaveFailureKeepsReceiptAndRetryCommitsFinalizeWithReward() throws {
        var progress = try progress()
        _ = try store.prepareReward(offerID: "direct", kind: .direct, progress: &progress, analyticsOffer: offer)
        XCTAssertThrowsError(try store.grantReward(offerID: "direct", progress: &progress,
                                                  completionEvent: completion) { candidate, outcome in
            guard case .directRevealed = outcome else { return XCTFail("Expected reward effect before failure") }
            // The effect transaction is invalid, while the preceding receipt is already durable.
            candidate.bonusHints = -1
        })
        XCTAssertEqual(progress.rewardLedger["direct"]?.state, .rewarded)
        XCTAssertEqual(progress.rewardLedger["direct"]?.completionEvent, completion)
        XCTAssertTrue(progress.session?.found.isEmpty == true)
        XCTAssertEqual(progress.bonusHints, 0)
        XCTAssertEqual(try persistedProgress(), progress)
        _ = try store.grantReward(offerID: "direct", progress: &progress,
                                 completionEvent: Data("retry must not replace receipt".utf8)) { candidate, _ in
            candidate.settings.musicEnabled = false
        }
        let saved = try persistedProgress()
        XCTAssertEqual(saved.rewardLedger["direct"]?.state, .executed)
        XCTAssertEqual(saved.rewardLedger["direct"]?.completionEvent, completion)
        XCTAssertEqual(saved.session?.found.count, 1)
        XCTAssertFalse(saved.settings.musicEnabled)
    }

    func testColdToolCompensationPreservesOriginalEventAndNeverPaysTwice() throws {
        for kind in [RewardKind.direct, .hint] {
            var progress = try progress()
            let id = kind.rawValue
            _ = try store.prepareReward(offerID: id, kind: kind, progress: &progress, analyticsOffer: offer)
            _ = try store.markRewardReceived(offerID: id, progress: &progress, completionEvent: completion)
            let first = SaveStore(directory: directory).load()
            XCTAssertEqual(first.recoveredRewardCount, 1)
            XCTAssertEqual(first.progress.rewardLedger[id]?.state, .compensated)
            XCTAssertEqual(first.progress.rewardLedger[id]?.analyticsOffer, offer)
            XCTAssertEqual(first.progress.rewardLedger[id]?.completionEvent, completion)
            XCTAssertEqual(first.progress.bonusDirect, kind == .direct ? 1 : 0)
            XCTAssertEqual(first.progress.bonusHints, kind == .hint ? 1 : 0)
            XCTAssertTrue(first.progress.session?.found.isEmpty == true)
            XCTAssertTrue(first.progress.session?.marks.isEmpty == true)
            let second = SaveStore(directory: directory).load()
            XCTAssertEqual(second.recoveredRewardCount, 0)
            XCTAssertEqual(second.progress, first.progress)
            var recovered = second.progress
            XCTAssertEqual(try store.grantReward(offerID: id, progress: &recovered,
                                                completionEvent: Data("late duplicate".utf8)), .duplicate)
            XCTAssertEqual(recovered.rewardLedger[id]?.completionEvent, completion)
        }
    }

    func testColdReviveCancellationRetainsReceiptWithoutReplayingRevive() throws {
        var progress = try progress()
        let puzzle = try XCTUnwrap(progress.session?.puzzle)
        let wrong = try XCTUnwrap((0..<(puzzle.size * puzzle.size)).first { !puzzle.solution.contains($0) })
        for _ in 0..<progress.session!.config.initialLives { _ = progress.session?.submit(cell: wrong) }
        XCTAssertEqual(progress.session?.status, .lost)
        _ = try store.prepareReward(offerID: "revive", kind: .revive, progress: &progress, analyticsOffer: offer)
        _ = try store.markRewardReceived(offerID: "revive", progress: &progress, completionEvent: completion)
        let first = SaveStore(directory: directory).load()
        XCTAssertEqual(first.recoveredRewardCount, 0)
        XCTAssertEqual(first.progress.rewardLedger["revive"]?.state, .cancelled)
        XCTAssertEqual(first.progress.rewardLedger["revive"]?.analyticsOffer, offer)
        XCTAssertEqual(first.progress.rewardLedger["revive"]?.completionEvent, completion)
        XCTAssertEqual(first.progress.session?.status, .lost)
        XCTAssertEqual(first.progress.session?.lives, 0)
        XCTAssertEqual(first.progress.bonusHints, 0)
        XCTAssertEqual(first.progress.bonusDirect, 0)
        XCTAssertEqual(SaveStore(directory: directory).load().progress, first.progress)
        var recovered = first.progress
        XCTAssertEqual(try store.grantReward(offerID: "revive", progress: &recovered,
                                            completionEvent: Data("duplicate".utf8)), .ignored)
        XCTAssertEqual(recovered.rewardLedger["revive"]?.completionEvent, completion)
    }

    func testLegacyRecordWithoutAnalyticsFieldsDecodesAndReceiptIsNotBackfilled() throws {
        let legacy = Data(#"{"id":"legacy","kind":"direct","state":"rewarded","createdAt":0}"#.utf8)
        let record = try JSONDecoder().decode(RewardRecord.self, from: legacy)
        XCTAssertNil(record.analyticsOffer)
        XCTAssertNil(record.completionEvent)
        var progress = try progress()
        var attachedRecord = record
        attachedRecord.sessionID = progress.session?.id
        progress.rewardLedger[record.id] = attachedRecord
        try store.save(progress)
        _ = try store.grantReward(offerID: record.id, progress: &progress, completionEvent: completion)
        XCTAssertNil(progress.rewardLedger[record.id]?.completionEvent,
                     "A duplicate receipt cannot invent event context for a legacy confirmed reward")
        XCTAssertNil(store.load().progress.rewardLedger[record.id]?.analyticsOffer)
    }

    func testOpaqueEventSizeBoundsAreValidatedBeforeMutatingRewardState() throws {
        var progress = try progress()
        let maximum = Data(repeating: 0xFF, count: 32_768)
        let oversized = Data(repeating: 0xFF, count: 32_769)
        XCTAssertThrowsError(try store.prepareReward(offerID: "oversized", kind: .direct,
                                                    progress: &progress, analyticsOffer: oversized))
        XCTAssertNil(progress.rewardLedger["oversized"])
        XCTAssertTrue(try store.prepareReward(offerID: "maximum", kind: .direct,
                                              progress: &progress, analyticsOffer: maximum))
        XCTAssertThrowsError(try store.markRewardReceived(offerID: "maximum", progress: &progress,
                                                         completionEvent: oversized))
        XCTAssertEqual(progress.rewardLedger["maximum"]?.state, .offered)
        XCTAssertNil(progress.rewardLedger["maximum"]?.completionEvent)
        XCTAssertTrue(try store.markRewardReceived(offerID: "maximum", progress: &progress,
                                                   completionEvent: maximum))
        XCTAssertEqual(try persistedProgress().rewardLedger["maximum"]?.completionEvent, maximum)
        XCTAssertEqual(try persistedProgress().rewardLedger["maximum"]?.analyticsOffer, maximum)
    }
}
