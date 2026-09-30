import XCTest
import CryptoKit
@testable import CapydokuCore

final class HintUsePersistenceTests: XCTestCase {
    private var directory: URL!
    private var store: SaveStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HintUsePersistence-\(UUID())")
        store = SaveStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func progress(hints: Int = 1) throws -> PlayerProgress {
        var progress = PlayerProgress()
        progress.begin(puzzle: try PuzzleGenerator.generate(level: 1),
                       config: DemoConfig(hintsPerLevel: hints, directPerLevel: 0))
        return progress
    }

    private func consumePreview(_ progress: inout PlayerProgress) throws -> HintUseState {
        let session = try XCTUnwrap(progress.session)
        let hint = try XCTUnwrap(PuzzleHints.next(puzzle: session.puzzle, found: session.found, marks: session.marks))
        let source = progress.nextHintSource
        let before = progress.availableHints
        return try store.transaction(progress: &progress) { candidate in
            XCTAssertTrue(candidate.consumeHint())
            let use = HintUseState(sessionID: session.id, hint: hint, source: source,
                                   inventoryBefore: before, inventoryAfter: candidate.availableHints)
            candidate.activeHintUse = use
            return use
        }
    }

    func testConsumedUnshownAndShownPreviewsRestoreExactlyWithoutConsumingAgain() throws {
        var progress = try progress(hints: 2)
        let use = try consumePreview(&progress)
        XCTAssertFalse(use.previewPresented)
        XCTAssertEqual(use.source, .levelConfigFree)
        XCTAssertEqual(use.inventoryBefore, 2)
        XCTAssertEqual(use.inventoryAfter, 1)
        let eventID = UUID().uuidString
        let event = Data([0, 255, 11])
        let first = SaveStore(directory: directory).load()
        XCTAssertEqual(first.source, .primary)
        XCTAssertEqual(first.recoveredRewardCount, 0)
        XCTAssertEqual(first.progress, progress)
        XCTAssertEqual(first.progress.activeHintUse?.hint, use.hint)
        XCTAssertEqual(first.progress.availableHints, 1)
        XCTAssertTrue(first.progress.session?.marks.isEmpty == true)
        progress = first.progress
        try store.transaction(progress: &progress) { candidate in
            candidate.activeHintUse?.previewPresented = true
            candidate.pendingBuffEvents[eventID] = event
        }
        let shown = SaveStore(directory: directory).load()
        XCTAssertEqual(shown.progress.activeHintUse?.id, use.id)
        XCTAssertEqual(shown.progress.activeHintUse?.previewPresented, true)
        XCTAssertEqual(shown.progress.activeHintUse?.hint, use.hint)
        XCTAssertEqual(shown.progress.availableHints, 1)
        XCTAssertEqual(shown.progress.pendingBuffEvents, [eventID: event])
        XCTAssertEqual(SaveStore(directory: directory).load().progress, shown.progress)
    }

    func testConsumedAdHintIsRestoredAsSamePreviewRatherThanCompensatedInventory() throws {
        var progress = try progress(hints: 0)
        _ = try store.prepareReward(offerID: "hint-offer", kind: .hint, progress: &progress)
        XCTAssertEqual(try store.grantReward(offerID: "hint-offer", progress: &progress), .hintReady)
        XCTAssertEqual(progress.session?.pendingRewardHint, true)
        let use = try consumePreview(&progress)
        XCTAssertEqual(use.source, .rewardedAd)
        XCTAssertEqual(progress.session?.pendingRewardHint, false)
        XCTAssertEqual(progress.availableHints, 0)
        for _ in 0..<3 {
            let restored = SaveStore(directory: directory).load()
            XCTAssertEqual(restored.recoveredRewardCount, 0)
            XCTAssertEqual(restored.progress.activeHintUse, use)
            XCTAssertEqual(restored.progress.availableHints, 0)
            XCTAssertEqual(restored.progress.bonusHints, 0)
            XCTAssertEqual(restored.progress.rewardLedger["hint-offer"]?.state, .executed)
            XCTAssertEqual(restored.progress.session?.pendingRewardHint, false)
            XCTAssertTrue(restored.progress.session?.marks.isEmpty == true)
        }
    }

    func testInitialFreeAndUnknownLegacySourcesAreFrozenWithoutReclassification() throws {
        for source in [ToolInventorySource.initialFree, nil] {
            var progress = try progress(hints: 0)
            if source == .initialFree {
                _ = progress.claimCheckIn(on: Date(timeIntervalSince1970: 20_000 * 86_400))
            } else {
                progress.bonusHints = 1 // A legacy balance without provenance.
            }
            XCTAssertEqual(progress.nextHintSource, source)
            let use = try consumePreview(&progress)
            let restored = SaveStore(directory: directory).load().progress
            XCTAssertEqual(restored.activeHintUse?.source, source)
            XCTAssertEqual(restored.activeHintUse, use)
            XCTAssertEqual(restored.availableHints, 0)
        }
    }

    func testNewAttemptAndNewLevelClearPreviewButRetainUnacknowledgedEvents() throws {
        var progress = try progress(hints: 2)
        _ = try consumePreview(&progress)
        let id = UUID().uuidString
        progress.pendingBuffEvents[id] = Data("original queued event".utf8)
        let expected = progress.pendingBuffEvents
        let previousSession = progress.session?.id
        progress.restart()
        XCTAssertNil(progress.activeHintUse)
        XCTAssertNotEqual(progress.session?.id, previousSession)
        XCTAssertEqual(progress.pendingBuffEvents, expected)
        _ = try consumePreview(&progress)
        progress.begin(puzzle: try PuzzleGenerator.generate(level: 2))
        XCTAssertNil(progress.activeHintUse)
        XCTAssertEqual(progress.pendingBuffEvents, expected)
        try store.save(progress)
        XCTAssertEqual(SaveStore(directory: directory).load().progress.pendingBuffEvents, expected)
    }

    func testLegacySaveMigrationDefaultsNewFieldsWithoutRegrantingConsumedInventory() throws {
        var progress = try progress(hints: 2)
        XCTAssertTrue(progress.consumeHint())
        progress.bonusDirect = 3
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as? [String: Any])
        payload.removeValue(forKey: "activeHintUse")
        payload.removeValue(forKey: "pendingBuffEvents")
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let envelope: [String: Any] = ["schemaVersion": 2, "checksum": checksum, "payload": data.base64EncodedString()]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: envelope).write(to: store.primaryURL)
        let restored = store.load()
        XCTAssertEqual(restored.source, .primary)
        XCTAssertTrue(restored.didMigrate)
        XCTAssertNil(restored.progress.activeHintUse)
        XCTAssertTrue(restored.progress.pendingBuffEvents.isEmpty)
        XCTAssertEqual(restored.progress.availableHints, 1)
        XCTAssertEqual(restored.progress.bonusDirect, 3)
        XCTAssertEqual(restored.progress, progress)
    }

    func testInvalidPreviewCannotReplaceLastValidSave() throws {
        var valid = try progress()
        _ = try consumePreview(&valid)
        let original = try Data(contentsOf: store.primaryURL)
        let mutations: [(String, (inout PlayerProgress) -> Void)] = [
            ("no session", { $0.session = nil }),
            ("wrong session", { $0.activeHintUse?.sessionID = UUID() }),
            ("pending reward already consumed", { $0.session?.pendingRewardHint = true }),
            ("empty cells", { $0.activeHintUse?.hint = PuzzleHint(cells: [], explanation: "same", rule: "same") }),
            ("duplicate cells", { p in let cell = p.activeHintUse!.hint.cells[0]; p.activeHintUse?.hint = PuzzleHint(cells: [cell, cell], explanation: "same", rule: "same") }),
            ("negative cell", { $0.activeHintUse?.hint = PuzzleHint(cells: [-1], explanation: "same", rule: "same") }),
            ("off board", { p in let size = p.session!.puzzle.size; p.activeHintUse?.hint = PuzzleHint(cells: [size * size], explanation: "same", rule: "same") }),
            ("answer cell", { p in let cell = p.session!.puzzle.solution[0]; p.activeHintUse?.hint = PuzzleHint(cells: [cell], explanation: "same", rule: "same") }),
            ("negative before", { $0.activeHintUse?.inventoryBefore = -1 }),
            ("negative after", { $0.activeHintUse?.inventoryAfter = -1 }),
            ("wrong deduction", { p in let before = p.activeHintUse!.inventoryBefore; p.activeHintUse?.inventoryAfter = before }),
            ("unsafe arithmetic", { $0.activeHintUse?.inventoryAfter = Int.max }),
            ("not playing", { p in let cell = (0..<(p.session!.puzzle.size * p.session!.puzzle.size)).first { !p.session!.puzzle.solution.contains($0) }!; for _ in 0..<p.session!.config.initialLives { _ = p.session?.submit(cell: cell) } })
        ]
        for (label, mutation) in mutations {
            var invalid = valid
            mutation(&invalid)
            XCTAssertThrowsError(try store.save(invalid), label)
            XCTAssertEqual(try Data(contentsOf: store.primaryURL), original, label)
        }
        XCTAssertEqual(store.load().progress, valid)
    }

    func testPendingBuffEventsRejectInvalidKeysAndDataButDoNotParseApplicationPayloads() throws {
        var progress = try progress()
        let id = UUID().uuidString
        for events in [["invalid-id": Data([1])], [id: Data()], [id: Data(repeating: 1, count: 32_769)]] {
            progress.pendingBuffEvents = events
            XCTAssertThrowsError(try store.save(progress))
        }
        progress.pendingBuffEvents = [id: Data(repeating: 255, count: 32_768)]
        try store.save(progress)
        XCTAssertEqual(store.load().progress.pendingBuffEvents, progress.pendingBuffEvents)
    }
}
