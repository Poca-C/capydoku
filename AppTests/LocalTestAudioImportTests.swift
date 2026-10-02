import XCTest
import AVFoundation
import CryptoKit
@testable import Capydoku

final class LocalTestAudioImportTests: XCTestCase {
    @MainActor func testActualAudioSessionStartsAndAdvancesBundledOriginalEffect() async throws {
        guard LocalTestAudioImport.load() != nil else { throw XCTSkip("Local internal-test audio required") }
        var handles: [AVAudioPlayer] = []
        let player = FeedbackPlayer(playerFactory: { url in
            guard let handle = try? AVAudioPlayer(contentsOf: url) else { return nil }
            handles.append(handle); return handle
        }, observeSystem: false)
        defer { player.setBlocked(.background, active: true) }
        player.apply(settings: .init(sound: true, haptic: false, voice: false, music: false))
        player.setContext(page: .game, level: 2)
        player.play(.correct)
        let handle = try XCTUnwrap(handles.first)
        XCTAssertTrue(handle.isPlaying, "Use the real AVAudioSession and AVAudioPlayer, not a success-returning mock")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(handle.currentTime, 0.02)
        XCTAssertGreaterThan(handle.volume, 0)
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback, "Explicit local listening follows the in-game switch, including silent-ring mode")
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
        print("REAL_AUDIO category=\(session.category.rawValue) options=\(session.categoryOptions.rawValue) outputVolume=\(session.outputVolume) time=\(handle.currentTime) playing=\(handle.isPlaying)")
    }

    @MainActor func testFormalAmbientPolicyUsesAValidCategoryWithoutExplicitMixOption() throws {
        let policy = GameAudioSessionPolicy(localReferenceAudio: false)
        XCTAssertTrue(policy.options.isEmpty)
        try policy.configure()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
    }

    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture() throws -> LocalTestAudioImport.Envelope {
        let name = "meow-test-fixture.wav", data = Data("test fixture".utf8)
        try data.write(to: directory.appendingPathComponent(name))
        let clip = AudioClipPolicy(file: name, group: .sound, volume: 0.7, delay: 0, minimumInterval: 0,
            maximumConcurrent: 1, overflow: .dropNewest, loops: 0, fadeIn: 0, fadeOut: 0,
            contextChange: .followCurrentScope, scope: .init(pages: [.game], overlays: [.none]))
        return .init(schemaVersion: 1, purpose: "local-user-authorized-audio-test", allowedEnvironment: "internal_demo",
            referenceVerified: false, files: [name: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()],
            playback: ReferenceAudioManifest(version: "local-test", referenceVerified: false, clips: ["mark_x": clip]))
    }
    private func write(_ envelope: LocalTestAudioImport.Envelope) throws {
        try JSONEncoder().encode(envelope).write(to: directory.appendingPathComponent("local-test-audio.json"))
    }
    func testValidLocalImportDoesNotClaimReferenceVerified() throws {
        try write(fixture())
        let result = try XCTUnwrap(LocalTestAudioImport.load(directory: directory, environment: .demo))
        XCTAssertFalse(result.manifest.referenceVerified)
        XCTAssertNotNil(result.resource("meow-test-fixture.wav"))
        XCTAssertNil(result.resource("../outside.wav"))
    }
    func testEveryCandidateEnvironmentRejectsLocalAudio() throws {
        try write(fixture())
        for environment in AppEnvironment.allCases where environment != .demo {
            XCTAssertNil(LocalTestAudioImport.load(directory: directory, environment: environment))
        }
    }
    func testAcceptedMoveTuningPreservesSourceAndOtherLocalPolicies() throws {
        let source = try fixture()
        var playback = source.playback
        playback.clips["mark_x"]?.minimumInterval = 0.15
        playback.clips["double_tap_correct"] = playback.clips["mark_x"]
        playback.clips["double_tap_wrong"] = playback.clips["mark_x"]
        try write(.init(schemaVersion: source.schemaVersion, purpose: source.purpose,
                        allowedEnvironment: source.allowedEnvironment, referenceVerified: false,
                        files: source.files, playback: playback))
        let url = directory.appendingPathComponent("local-test-audio.json")
        let before = try Data(contentsOf: url)
        let imported = try XCTUnwrap(LocalTestAudioImport.load(directory: directory, environment: .demo))
        XCTAssertFalse(imported.manifest.referenceVerified)
        var expected = playback
        expected.clips["mark_x"]?.minimumInterval = 0
        expected.clips["erase_x"]?.minimumInterval = 0
        expected.clips["double_tap_correct"]?.minimumInterval = 0
        expected.clips["double_tap_wrong"]?.minimumInterval = 0
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(imported.manifest), try encoder.encode(expected))
        XCTAssertEqual(try Data(contentsOf: url), before)

        // Validate the imported data before applying tuning; bad input must
        // not become acceptable merely because this field would be reset.
        playback.clips["double_tap_wrong"]?.minimumInterval = -1
        try write(.init(schemaVersion: source.schemaVersion, purpose: source.purpose,
                        allowedEnvironment: source.allowedEnvironment, referenceVerified: false,
                        files: source.files, playback: playback))
        XCTAssertNil(LocalTestAudioImport.load(directory: directory, environment: .demo))
    }
    func testChecksumMismatchRejectsWholeImport() throws {
        try write(fixture())
        try Data("changed".utf8).write(to: directory.appendingPathComponent("meow-test-fixture.wav"))
        XCTAssertNil(LocalTestAudioImport.load(directory: directory, environment: .demo))
    }
    func testInvalidPlaybackPolicyIsValidatedEvenThoughUnverified() throws {
        let valid = try fixture(); var playback = valid.playback
        playback.clips["mark_x"]?.volume = 2
        try write(.init(schemaVersion: valid.schemaVersion, purpose: valid.purpose, allowedEnvironment: valid.allowedEnvironment,
                        referenceVerified: false, files: valid.files, playback: playback))
        XCTAssertNil(LocalTestAudioImport.load(directory: directory, environment: .demo))
    }
    func testNoImpersonationOfVerifiedReferenceImport() throws {
        let valid = try fixture(); var playback = valid.playback; playback.referenceVerified = true
        try write(.init(schemaVersion: valid.schemaVersion, purpose: valid.purpose, allowedEnvironment: valid.allowedEnvironment,
                        referenceVerified: false, files: valid.files, playback: playback))
        XCTAssertNil(LocalTestAudioImport.load(directory: directory, environment: .demo))
    }
    func testMissingAndExtraResourceInventoryRejectsImport() throws {
        let valid = try fixture()
        for files in [[:], valid.files.merging(["meow-test-extra.wav": String(repeating: "0", count: 64)], uniquingKeysWith: { a, _ in a })] {
            try write(.init(schemaVersion: valid.schemaVersion, purpose: valid.purpose, allowedEnvironment: valid.allowedEnvironment,
                            referenceVerified: false, files: files, playback: valid.playback))
            XCTAssertNil(LocalTestAudioImport.load(directory: directory, environment: .demo))
        }
    }
    @MainActor func testBundledLocalExperimentDecodesWhenPresentAndFormalManifestStaysUnverified() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "audio-manifest", withExtension: "json"))
        let formal = try JSONDecoder().decode(ReferenceAudioManifest.self, from: Data(contentsOf: url))
        XCTAssertFalse(formal.referenceVerified); XCTAssertTrue(formal.clips.isEmpty)
        let player = FeedbackPlayer(observeSystem: false)
        XCTAssertFalse(player.hasVerifiedComboConfiguration)
        if let local = LocalTestAudioImport.load() {
            XCTAssertTrue(player.usesLocalTestAudio); XCTAssertTrue(player.validationErrors.isEmpty)
            XCTAssertEqual(local.manifest.clips.count, 10)
            let files = Set(local.manifest.clips.values.map(\.file)); XCTAssertEqual(files.count, 9)
            for file in files {
                let audio = try AVAudioPlayer(contentsOf: XCTUnwrap(local.resource(file)))
                XCTAssertGreaterThan(audio.duration, 0.1); XCTAssertTrue(audio.prepareToPlay())
                XCTAssertGreaterThan(audio.numberOfChannels, 0)
            }
        } else { XCTAssertFalse(player.usesLocalTestAudio) } // Clean Git clones intentionally lack local files.
    }
}
