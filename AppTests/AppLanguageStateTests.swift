import XCTest
import CapydokuCore
@testable import Capydoku

private final class LanguageStateIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}

final class AppLanguageStateTests: XCTestCase {
    private func directory() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("app-language-state-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }

    private func puzzle() throws -> Puzzle {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "levels", withExtension: "json"))
        return try XCTUnwrap(JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url)).first { $0.id == 1 })
    }

    private func store(_ directory: URL, puzzle: Puzzle) -> SaveStore {
        SaveStore(directory: directory, packagedPuzzle: { $0 == puzzle.id ? puzzle : nil })
    }

    @MainActor private func model(_ directory: URL, puzzle: Puzzle, asyncSaves: Bool = false,
                                  identity: LanguageStateIdentity = LanguageStateIdentity()) -> AppModel {
        let feedback = FeedbackPlayer(manifest: .silent, resourceResolver: { _ in nil },
                                      playerFactory: { _ in nil }, sessionControl: { _ in true }, observeSystem: false)
        return AppModel(saveDirectory: directory, runsTimer: asyncSaves, feedbackEnabled: false,
                        bundledPuzzles: [puzzle], analyticsIdentityStore: identity, feedbackPlayer: feedback)
    }

    private func seedCompleteState(_ directory: URL, puzzle: Puzzle, presented: Bool = false) throws -> PlayerProgress {
        let persistence = store(directory, puzzle: puzzle)
        var progress = PlayerProgress()
        progress.begin(puzzle: puzzle, config: DemoConfig(hintsPerLevel: 3, directPerLevel: 0))
        progress.tutorialCompleted = true
        XCTAssertTrue(try persistence.prepareReward(offerID: "before-language-switch", kind: .direct, progress: &progress))
        let outcome = try persistence.grantReward(offerID: "before-language-switch", progress: &progress)
        guard case .directRevealed = outcome else {
            XCTFail("The state fixture must contain an actual executed reward")
            throw CocoaError(.fileReadCorruptFile)
        }
        let next = try XCTUnwrap(puzzle.solution.first { !progress.session!.found.contains($0) })
        _ = progress.session?.submit(cell: next)
        let wrong = try XCTUnwrap(puzzle.regions.indices.first { !puzzle.solution.contains($0) })
        _ = progress.session?.submit(cell: wrong)
        progress.session?.advanceTime(by: 47)
        progress.bonusDirect = 4
        _ = progress.claimCheckIn(on: Date(timeIntervalSince1970: 20_000 * 86_400))
        _ = progress.claimCheckIn(on: Date(timeIntervalSince1970: 20_001 * 86_400))
        progress.settings = GameSettings(musicEnabled: false, soundEnabled: true,
                                         voiceEnabled: false, hapticsEnabled: true)
        let session = try XCTUnwrap(progress.session)
        let hint = try XCTUnwrap(PuzzleHints.next(puzzle: puzzle, found: session.found, marks: session.marks))
        let before = progress.availableHints, source = progress.nextHintSource
        XCTAssertTrue(progress.consumeHint())
        progress.activeHintUse = HintUseState(sessionID: session.id, hint: hint, source: source,
            inventoryBefore: before, inventoryAfter: progress.availableHints, previewPresented: presented)
        progress.captureSessionBalance()
        try persistence.save(progress)
        return progress
    }

    private func languageInSave(_ directory: URL) throws -> String {
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("progress.json"))) as? [String: Any])
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        let progress = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try XCTUnwrap(progress["settings"] as? [String: Any])
        return try XCTUnwrap(settings["language"] as? String)
    }

    @MainActor func testSetLanguageIsPersistedBeforeReturningAndRestoresOnColdStart() throws {
        let directory = directory(), puzzle = try puzzle()
        let app = model(directory, puzzle: puzzle)
        XCTAssertEqual(app.progress.settings.language, .simplifiedChinese)
        app.setLanguage(.english)
        XCTAssertEqual(app.progress.settings.language, .english)
        XCTAssertEqual(try languageInSave(directory), "en")
        XCTAssertNil(app.errorMessage)
        let restored = model(directory, puzzle: puzzle)
        XCTAssertEqual(restored.progress.settings.language, .english)
        XCTAssertNil(restored.session)
        restored.setLanguage(.simplifiedChinese)
        XCTAssertEqual(try languageInSave(directory), "zh-Hans")
        XCTAssertEqual(model(directory, puzzle: puzzle).progress.settings.language, .simplifiedChinese)
    }

    @MainActor func testLanguageRoundTripKeepsCompleteSessionInventoryCheckInReceiptAndUnshownPreview() throws {
        let directory = directory(), puzzle = try puzzle()
        let original = try seedCompleteState(directory, puzzle: puzzle)
        let app = model(directory, puzzle: puzzle)
        app.startOrContinue()
        let originalHint = try XCTUnwrap(app.hint)
        XCTAssertEqual(app.progress, original)
        for language in [AppLanguage.english, .simplifiedChinese, .english] {
            var expected = original
            expected.settings.language = language
            app.setLanguage(language)
            XCTAssertEqual(app.progress, expected)
            XCTAssertEqual(app.hint, originalHint)
            XCTAssertEqual(app.screen, .game)
            XCTAssertFalse(try XCTUnwrap(app.progress.activeHintUse).previewPresented)
            XCTAssertEqual(try languageInSave(directory), language.rawValue)
            let restored = model(directory, puzzle: puzzle)
            XCTAssertEqual(restored.progress, expected)
            XCTAssertNil(restored.hint, "A language preference must not make a saved preview appear on Home")
            restored.startOrContinue()
            XCTAssertEqual(restored.hint, originalHint)
            XCTAssertEqual(restored.progress, expected)
            XCTAssertEqual(restored.progress.availableHints, original.availableHints)
            XCTAssertEqual(restored.progress.rewardLedger, original.rewardLedger)
            XCTAssertEqual(restored.session?.puzzle.seed, puzzle.seed)
        }
    }

    @MainActor func testSwitchingLanguageDoesNotReopenOrConsumeAnAlreadyPresentedHint() throws {
        let directory = directory(), puzzle = try puzzle()
        let original = try seedCompleteState(directory, puzzle: puzzle, presented: true)
        let app = model(directory, puzzle: puzzle)
        app.startOrContinue()
        let hint = app.hint
        app.setLanguage(.english)
        app.setLanguage(.simplifiedChinese)
        XCTAssertEqual(app.progress, original)
        XCTAssertEqual(app.hint, hint)
        XCTAssertEqual(app.progress.activeHintUse?.id, original.activeHintUse?.id)
        XCTAssertEqual(app.progress.activeHintUse?.previewPresented, true)
        XCTAssertTrue(app.analytics.events.isEmpty, "Switching a preference is neither a new preview nor an Apply")
        let restored = model(directory, puzzle: puzzle)
        XCTAssertEqual(restored.progress, original)
        XCTAssertEqual(restored.progress.availableHints, original.availableHints)
    }

    @MainActor func testLanguageWriteFailureRollsBackPreferenceAndAllGameplayUntilExplicitRetry() throws {
        let directory = directory(), puzzle = try puzzle()
        let original = try seedCompleteState(directory, puzzle: puzzle)
        let app = model(directory, puzzle: puzzle)
        app.startOrContinue()
        let hint = app.hint
        let primary = directory.appendingPathComponent("progress.json")
        let saved = try Data(contentsOf: primary)
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        app.setLanguage(.english)
        XCTAssertNotNil(app.errorMessage)
        XCTAssertEqual(app.progress, original)
        XCTAssertEqual(app.hint, hint)
        XCTAssertEqual(app.screen, .game)
        try FileManager.default.removeItem(at: primary)
        try saved.write(to: primary, options: .atomic)
        XCTAssertEqual(try languageInSave(directory), "zh-Hans")
        XCTAssertEqual(store(directory, puzzle: puzzle).load().progress, original)
        app.errorMessage = nil
        app.setLanguage(.english)
        var expected = original
        expected.settings.language = .english
        XCTAssertEqual(app.progress, expected)
        XCTAssertEqual(store(directory, puzzle: puzzle).load().progress, expected)
    }

    @MainActor func testSelectingCurrentLanguageDoesNotRewriteOrFailWhenStorageIsUnavailable() throws {
        let directory = directory(), puzzle = try puzzle()
        let original = try seedCompleteState(directory, puzzle: puzzle)
        let app = model(directory, puzzle: puzzle)
        let primary = directory.appendingPathComponent("progress.json")
        let saved = try Data(contentsOf: primary)
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        app.setLanguage(.simplifiedChinese)
        XCTAssertNil(app.errorMessage)
        XCTAssertEqual(app.progress, original)
        try FileManager.default.removeItem(at: primary)
        try saved.write(to: primary, options: .atomic)
        XCTAssertEqual(store(directory, puzzle: puzzle).load().progress, original)
    }

    @MainActor func testQueuedProductionSnapshotsAndOldCallbacksCannotRollBackLatestLanguage() async throws {
        let directory = directory(), puzzle = try puzzle(), identity = LanguageStateIdentity()
        let app = model(directory, puzzle: puzzle, asyncSaves: true, identity: identity)
        app.consentAccepted()
        app.progress.tutorialCompleted = true
        app.config = DemoConfig(hintsPerLevel: 2, directPerLevel: 2)
        app.start(level: puzzle.id)
        let wrong = try XCTUnwrap(puzzle.regions.indices.first { !puzzle.solution.contains($0) })
        for _ in 0..<16 { app.toggle(wrong); app.toggle(wrong) }
        app.direct()
        // The direct-use event acknowledgement also enqueues a save callback.
        // Those older snapshots must finish before this synchronous preference transaction.
        app.setLanguage(.english)
        XCTAssertEqual(try languageInSave(directory), "en")
        XCTAssertEqual(app.session?.found.count, 1)
        for _ in 0..<16 { app.toggle(wrong); app.toggle(wrong) }
        app.setLanguage(.simplifiedChinese)
        app.setLanguage(.english)
        XCTAssertEqual(try languageInSave(directory), "en")
        app.setActive(false)
        let expected = app.progress
        try await Task.sleep(nanoseconds: 70_000_000)
        app.flushPendingSaves()
        XCTAssertEqual(app.progress.settings.language, .english)
        XCTAssertEqual(try languageInSave(directory), "en")
        XCTAssertEqual(app.progress, expected)
        let restored = model(directory, puzzle: puzzle, identity: identity)
        XCTAssertEqual(restored.progress, expected)
        XCTAssertEqual(restored.progress.settings.language, .english)
        XCTAssertEqual(restored.session?.found.count, 1)
        XCTAssertEqual(restored.analytics.events.filter { $0.eventName == "buff_use" }.count, 1)
        XCTAssertNil(app.errorMessage)
    }
}
