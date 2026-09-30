import XCTest
import CryptoKit
@testable import CapydokuCore

final class AppLanguagePersistenceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func directory() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppLanguagePersistence-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func puzzle() throws -> Puzzle {
        let catalog = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent("Resources/levels.json")))
        return try XCTUnwrap(catalog.first { $0.id == 3 })
    }

    private func store(_ directory: URL, puzzle: Puzzle) -> SaveStore {
        SaveStore(directory: directory, packagedPuzzle: { $0 == puzzle.id ? puzzle : nil })
    }

    private func fullProgress(_ store: SaveStore, puzzle: Puzzle) throws -> PlayerProgress {
        var progress = PlayerProgress()
        progress.begin(puzzle: puzzle, config: DemoConfig(hintsPerLevel: 2, directPerLevel: 0))
        progress.restart()
        let startedID = UUID().uuidString
        XCTAssertTrue(try store.prepareReward(offerID: "language-test-reward", kind: .direct, progress: &progress,
                                              analyticsOffer: Data("frozen original offer".utf8)))
        guard case .directRevealed = try store.grantReward(offerID: "language-test-reward", progress: &progress,
            completionEvent: Data("frozen original receipt".utf8), pendingEvents: [startedID: Data("frozen started".utf8)]) else {
            throw XCTUnwrapError.expectedReward
        }
        let anotherAnswer = try XCTUnwrap(puzzle.solution.first { !progress.session!.found.contains($0) })
        _ = progress.session?.submit(cell: anotherAnswer)
        let wrong = (0..<(puzzle.size * puzzle.size)).filter { !puzzle.solution.contains($0) }
        _ = progress.session?.submit(cell: try XCTUnwrap(wrong.first))
        _ = progress.session?.toggleMark(at: wrong[1])
        progress.session?.advanceTime(by: 73)
        progress.completedLevels = [1, 2]
        progress.unlockedLevel = 3
        progress.tutorialCompleted = true
        progress.bonusHints = 7
        progress.bonusDirect = 4
        _ = progress.claimCheckIn(on: Date(timeIntervalSince1970: 20_000 * 86_400))
        _ = progress.claimCheckIn(on: Date(timeIntervalSince1970: 20_001 * 86_400))
        progress.settings = GameSettings(musicEnabled: false, soundEnabled: true,
                                         voiceEnabled: false, hapticsEnabled: true)
        progress.captureSessionBalance()
        return progress
    }

    private enum XCTUnwrapError: Error { case expectedReward }

    private func payload(_ store: SaveStore) throws -> [String: Any] {
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.primaryURL)) as? [String: Any])
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func replaceSettingsLanguage(_ language: String?, in store: SaveStore) throws {
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.primaryURL)) as? [String: Any])
        var progress = try payload(store)
        var settings = try XCTUnwrap(progress["settings"] as? [String: Any])
        if let language { settings["language"] = language }
        else { settings.removeValue(forKey: "language") }
        progress["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: progress, options: [.sortedKeys])
        envelope["payload"] = data.base64EncodedString()
        envelope["checksum"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: store.primaryURL, options: .atomic)
    }

    func testLegacyFourPreferencesDefaultToSimplifiedChineseWithoutChangingTheirValues() throws {
        for values in [[false, false, false, false], [false, true, false, true], [true, false, true, false]] {
            let legacy: [String: Bool] = ["musicEnabled": values[0], "soundEnabled": values[1],
                                         "voiceEnabled": values[2], "hapticsEnabled": values[3]]
            let settings = try JSONDecoder().decode(GameSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertEqual(settings, GameSettings(musicEnabled: values[0], soundEnabled: values[1],
                                                  voiceEnabled: values[2], hapticsEnabled: values[3], language: .simplifiedChinese))
        }
        XCTAssertEqual(GameSettings().language, .simplifiedChinese)
        XCTAssertEqual(PlayerProgress().settings.language, .simplifiedChinese)
    }

    func testUnknownFutureLanguageFallsBackToChineseButKeepsAllOtherPreferences() throws {
        let future: [String: Any] = ["musicEnabled": false, "soundEnabled": true, "voiceEnabled": true,
                                     "hapticsEnabled": false, "language": "future-language-v2"]
        let settings = try JSONDecoder().decode(GameSettings.self, from: JSONSerialization.data(withJSONObject: future))
        XCTAssertEqual(settings, GameSettings(musicEnabled: false, soundEnabled: true,
                                              voiceEnabled: true, hapticsEnabled: false, language: .simplifiedChinese))
    }

    func testSwitchingBothLanguagesPersistsWholeGameAndOriginalPackReferenceUnchanged() throws {
        let directory = directory(), puzzle = try puzzle()
        let persistence = store(directory, puzzle: puzzle)
        var progress = try fullProgress(persistence, puzzle: puzzle)
        let original = progress
        for (language, raw) in [(AppLanguage.simplifiedChinese, "zh-Hans"), (.english, "en"), (.simplifiedChinese, "zh-Hans")] {
            try persistence.transaction(progress: &progress) { $0.settings.language = language }
            let saved = try payload(persistence)
            let settings = try XCTUnwrap(saved["settings"] as? [String: Any])
            XCTAssertEqual(settings["language"] as? String, raw)
            let session = try XCTUnwrap(saved["session"] as? [String: Any])
            XCTAssertNil(session["puzzle"], "Changing language must not inline a packaged board into player state")
            XCTAssertNotNil(session["puzzleReference"])
            let restored = store(directory, puzzle: puzzle).load()
            XCTAssertEqual(restored.source, .primary)
            XCTAssertEqual(restored.recoveredRewardCount, 0)
            XCTAssertTrue(restored.warnings.isEmpty)
            XCTAssertEqual(restored.progress, progress)
            var gameplayOnly = restored.progress
            gameplayOnly.settings.language = original.settings.language
            XCTAssertEqual(gameplayOnly, original, "A language switch must preserve board, inventory, check-in and reward events")
            XCTAssertEqual(restored.progress.session?.puzzle.seed, puzzle.seed)
            XCTAssertEqual(restored.progress.rewardLedger["language-test-reward"]?.state, .executed)
            progress = restored.progress
        }
    }

    func testMissingAndFutureLanguageInsideValidSaveDoNotTriggerBackupOrLoseProgress() throws {
        let directory = directory(), puzzle = try puzzle()
        let persistence = store(directory, puzzle: puzzle)
        var expected = try fullProgress(persistence, puzzle: puzzle)
        expected.settings.language = .simplifiedChinese
        for language in [nil, "future-language-v2"] as [String?] {
            var toWrite = expected
            toWrite.settings.language = .english
            try persistence.save(toWrite)
            try replaceSettingsLanguage(language, in: persistence)
            let restored = store(directory, puzzle: puzzle).load()
            XCTAssertEqual(restored.source, .primary)
            XCTAssertEqual(restored.recoveredRewardCount, 0)
            XCTAssertTrue(restored.warnings.isEmpty)
            XCTAssertEqual(restored.progress, expected)
            XCTAssertEqual(restored.progress.session?.puzzle, puzzle)
            XCTAssertEqual(restored.progress.rewardLedger, expected.rewardLedger)
        }
    }
}
