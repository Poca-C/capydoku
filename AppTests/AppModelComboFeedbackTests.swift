import XCTest
import CapydokuCore
@testable import Capydoku

@MainActor private final class ComboTestClock {
    final class Job {
        let at: Double; let action: () -> Void; var cancelled = false
        init(at: Double, action: @escaping () -> Void) { self.at = at; self.action = action }
    }
    var now = 0.0
    var jobs: [Job] = []
    func schedule(_ delay: Double, _ action: @escaping () -> Void) -> AudioScheduledTask {
        let job = Job(at: now + delay, action: action); jobs.append(job)
        return AudioScheduledTask { job.cancelled = true }
    }
    func advance(_ duration: Double) {
        let end = now + duration
        while let index = jobs.indices.filter({ jobs[$0].at <= end }).min(by: { jobs[$0].at < jobs[$1].at }) {
            let job = jobs.remove(at: index); now = job.at
            if !job.cancelled { job.action() }
        }
        now = end
    }
}

@MainActor private final class ComboTestHandle: AudioPlaybackHandle {
    var isPlaying = false
    var duration: TimeInterval = 10
    var currentTime: TimeInterval = 0
    var volume: Float = 1
    var numberOfLoops = 0
    private let didPlay: () -> Void
    init(didPlay: @escaping () -> Void) { self.didPlay = didPlay }
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { isPlaying = true; didPlay(); return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func setVolume(_ volume: Float, fadeDuration: TimeInterval) { self.volume = volume }
}

@MainActor private final class ComboTestRig {
    let clock = ComboTestClock()
    var played: [String] = []
    var haptics: [FeedbackEvent] = []
    func player(_ manifest: ReferenceAudioManifest) -> FeedbackPlayer {
        FeedbackPlayer(manifest: manifest,
            resourceResolver: { URL(fileURLWithPath: "/synthetic-combo-contract/" + $0) },
            playerFactory: { [unowned self] url in ComboTestHandle { [unowned self] in played.append(url.lastPathComponent) } },
            scheduler: clock.schedule, clock: { [unowned self] in clock.now }, sessionControl: { _ in true },
            observeSystem: false, hapticEmitter: { [unowned self] in haptics.append($0) })
    }
}

private final class ComboRewards: RewardProvider {
    var completion: ((RewardSignal) -> Void)?
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) { self.completion = completion }
}

final class AppModelComboFeedbackTests: XCTestCase {
    private func manifest(cues: [AudioComboCue] = [.init(count: 1, event: "nice"), .init(count: 3, event: "great"), .init(count: 4, event: "excellent")],
                          repeatLast: Bool = false, group: AudioGroup = .voice,
                          context: AudioContextChange = .completeInTriggerScope) -> ReferenceAudioManifest {
        let clips = Dictionary(uniqueKeysWithValues: Set(cues.map(\.event)).map { key in
            (key, AudioClipPolicy(file: key + ".wav", group: group, volume: 0.5, delay: 0.25,
                                 minimumInterval: 0, maximumConcurrent: 16, overflow: .dropNewest, loops: 0,
                                 fadeIn: 0, fadeOut: 0, contextChange: context,
                                 scope: AudioScope(pages: [.game], overlays: [.none])))
        })
        return ReferenceAudioManifest(version: "synthetic-combo-test-only", referenceVerified: true, clips: clips,
                                      combo: AudioComboPolicy(cues: cues, repeatLast: repeatLast))
    }
    @MainActor private func model(_ rig: ComboTestRig, manifest: ReferenceAudioManifest, config: DemoConfig = .default,
                                  rewards: ComboRewards? = nil) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capy-combo-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(saveDirectory: root, rewardProvider: rewards, runsTimer: false,
                           feedbackEnabled: true, feedbackPlayer: rig.player(manifest))
        app.progress.tutorialCompleted = true
        app.config = config; app.start(level: 1)
        return app
    }
    @MainActor private func drainRewardCallbacks() async {
        // The adapter routes signals onto this serial queue. Resume only after
        // all signals already sent by the test have actually reached AppModel.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor func testFirstCorrectAndWinningCorrectReachConfiguredPlayerAtConfiguredDelayWithoutComboHaptics() throws {
        let rig = ComboTestRig(), app = model(rig, manifest: manifest())
        let solution = try XCTUnwrap(app.session).puzzle.solution
        app.submit(solution[0])
        XCTAssertEqual(app.comboFeedbackPresentation(for: 1), ComboFeedbackPresentation(text: "Nice", delay: 0.25))
        rig.clock.advance(0.24)
        XCTAssertTrue(rig.played.isEmpty)
        rig.clock.advance(0.01)
        XCTAssertEqual(rig.played, ["nice.wav"])
        app.submit(solution[0]) // duplicate successful cell cannot create another Combo
        app.submit(solution[1])
        XCTAssertNil(app.comboFeedbackPresentation(for: 2), "An unmapped verified count must not use a Demo threshold")
        app.submit(solution[2]); app.submit(solution[3])
        XCTAssertEqual(app.session?.status, .won)
        XCTAssertEqual(app.currentAudioEnvironment.overlay, .won)
        rig.clock.advance(0.25)
        XCTAssertEqual(rig.played, ["nice.wav", "great.wav", "excellent.wav"])
        XCTAssertEqual(rig.haptics, [.correct, .correct, .correct, .correct, .win])
    }

    @MainActor func testRepeatLastIsControlledByManifestIncludingFinalMove() throws {
        for repeatLast in [false, true] {
            let rig = ComboTestRig(), app = model(rig, manifest: manifest(cues: [.init(count: 1, event: "nice")], repeatLast: repeatLast))
            for cell in try XCTUnwrap(app.session).puzzle.solution { app.submit(cell) }
            rig.clock.advance(0.25)
            XCTAssertEqual(rig.played.count, repeatLast ? 4 : 1)
            XCTAssertEqual(app.comboFeedbackPresentation(for: 4)?.text, repeatLast ? "Nice" : nil)
            XCTAssertFalse(rig.haptics.contains { if case .combo = $0 { return true }; return false })
        }
    }

    @MainActor func testVoiceAndSoundGroupsRespectSettingsWithoutSuppressingConfiguredText() throws {
        for group in [AudioGroup.voice, .sound] {
            let rig = ComboTestRig(), app = model(rig, manifest: manifest(group: group))
            app.progress.settings.voiceEnabled = false
            app.progress.settings.soundEnabled = true
            app.progress.settings.hapticsEnabled = false
            app.settingsChanged()
            app.submit(try XCTUnwrap(app.session).puzzle.solution[0]); rig.clock.advance(0.25)
            XCTAssertEqual(rig.played, group == .voice ? [] : ["nice.wav"])
            XCTAssertEqual(app.comboFeedbackPresentation(for: 1)?.text, "Nice")
            XCTAssertTrue(rig.haptics.isEmpty)
        }
    }

    @MainActor func testWrongMoveResetsCountAndIgnoredMovesCannotReplayCombo() throws {
        let rig = ComboTestRig(), app = model(rig, manifest: manifest(cues: [.init(count: 1, event: "nice")]))
        let puzzle = try XCTUnwrap(app.session).puzzle
        app.submit(puzzle.solution[0]); rig.clock.advance(0.25)
        let wrong = try XCTUnwrap(puzzle.regions.indices.first { !puzzle.solution.contains($0) })
        app.submit(wrong)
        XCTAssertNil(app.comboFeedbackPresentation(for: 0))
        app.submit(puzzle.solution[1]); rig.clock.advance(0.25)
        app.submit(puzzle.solution[0]); rig.clock.advance(1)
        XCTAssertEqual(rig.played, ["nice.wav", "nice.wav"])
        XCTAssertEqual(app.session?.combo, 1)
        XCTAssertEqual(rig.haptics, [.correct, .wrong, .correct])
    }

    @MainActor func testFreeDirectFindWinningMoveRoutesFinalComboThroughSamePlayer() throws {
        let rig = ComboTestRig(), app = model(rig, manifest: manifest(cues: [.init(count: 4, event: "excellent")]))
        for cell in try XCTUnwrap(app.session).puzzle.solution.prefix(3) { app.submit(cell) }
        app.direct(); rig.clock.advance(0.25)
        XCTAssertEqual(app.session?.status, .won)
        XCTAssertEqual(rig.played, ["excellent.wav"])
        XCTAssertEqual(rig.haptics, [.correct, .correct, .correct, .correct, .win])
    }

    @MainActor func testAdWinningRevealUsesAcceptedScopeButStillHonorsContextPolicyAndBackground() async throws {
        for (context, background) in [(AudioContextChange.completeInTriggerScope, false), (.followCurrentScope, false), (.completeInTriggerScope, true)] {
            let rig = ComboTestRig(), rewards = ComboRewards()
            let app = model(rig, manifest: manifest(cues: [.init(count: 4, event: "excellent")], context: context),
                            config: DemoConfig(directPerLevel: 0), rewards: rewards)
            let solution = try XCTUnwrap(app.session).puzzle.solution
            for cell in solution.prefix(3) { app.submit(cell) }
            XCTAssertEqual(rig.haptics, [.correct, .correct, .correct])
            rig.haptics.removeAll()
            app.direct()
            XCTAssertTrue(app.rewardBusy)
            let completion = try XCTUnwrap(rewards.completion)
            completion(.started)
            await drainRewardCallbacks()
            XCTAssertTrue(app.currentAudioEnvironment.blocks.contains(.advertisement))
            app.submit(solution[3])
            XCTAssertEqual(app.session?.found.count, 3, "An active ad still owns input until its terminal result.")
            XCTAssertTrue(rig.haptics.isEmpty)
            if background { app.setActive(false) }
            completion(.earned); completion(.earned)
            await drainRewardCallbacks()
            XCTAssertFalse(app.rewardBusy)
            XCTAssertEqual(app.session?.status, .won)
            XCTAssertEqual(app.currentAudioEnvironment.overlay, .won)
            XCTAssertFalse(app.currentAudioEnvironment.blocks.contains(.advertisement))
            XCTAssertEqual(app.currentAudioEnvironment.blocks.contains(.background), background)
            rig.clock.advance(0.25)
            let expectedAudio = context == .completeInTriggerScope && !background ? ["excellent.wav"] : []
            let expectedHaptics: [FeedbackEvent] = background ? [] : [.correct, .win]
            XCTAssertEqual(rig.played, expectedAudio)
            XCTAssertEqual(rig.haptics, expectedHaptics, "The committed final reveal emits one correct and one win; Combo adds no extra haptic.")

            let won = app.session
            app.setActive(true)
            app.loadProgress(); app.startOrContinue()
            completion(.earned)
            await drainRewardCallbacks()
            rig.clock.advance(1)
            XCTAssertEqual(app.session, won)
            XCTAssertEqual(rig.played, expectedAudio, "Foreground/save restoration cannot replay a reward's audio.")
            XCTAssertEqual(rig.haptics, expectedHaptics, "Neither restoration nor a later duplicate may replay success.")
        }
    }

    @MainActor func testCancelledOldAdCannotPlayWinningRevealOnReplacementBoard() async throws {
        // A replacement attempt at the same level is also a different session.
        for replacementLevel in [1, 2] {
            let rig = ComboTestRig(), rewards = ComboRewards()
            let app = model(rig, manifest: manifest(cues: [.init(count: 4, event: "excellent")]),
                            config: DemoConfig(directPerLevel: 0), rewards: rewards)
            let oldSession = try XCTUnwrap(app.session)
            for cell in oldSession.puzzle.solution.prefix(3) { app.submit(cell) }
            app.direct()
            let completion = try XCTUnwrap(rewards.completion)
            XCTAssertTrue(app.rewardBusy)
            let offer = try XCTUnwrap(app.progress.rewardLedger.values.first)
            XCTAssertEqual(offer.sessionID, oldSession.id)
            rig.haptics.removeAll()

            app.start(level: replacementLevel)
            // Abandoning an offered (not yet rewarded) transaction cancels it;
            // only a durable rewarded receipt is eligible for compensation.
            XCTAssertEqual(app.progress.rewardLedger[offer.id]?.state, .cancelled)
            XCTAssertEqual(app.progress.rewardLedger.count, 1, "No replacement ad was requested by starting this board.")
            // start does not tear down the in-memory adapter. Restore through
            // the actual recovery boundary before accepting input on this board.
            app.loadProgress(); app.startOrContinue()
            let replacement = try XCTUnwrap(app.session)
            XCTAssertNotEqual(replacement.id, oldSession.id)
            XCTAssertFalse(app.rewardBusy)
            completion(.earned); completion(.earned)
            await drainRewardCallbacks()
            rig.clock.advance(1)
            XCTAssertFalse(app.rewardBusy)
            XCTAssertEqual(app.session, replacement, "A stale reward cannot reveal or finish the replacement board.")
            XCTAssertEqual(app.progress.rewardLedger[offer.id]?.state, .cancelled)
            XCTAssertEqual(app.progress.bonusDirect, 0)
            XCTAssertNil(app.directRevealFeedback)
            XCTAssertTrue(rig.played.isEmpty)
            XCTAssertTrue(rig.haptics.isEmpty)

            app.loadProgress(); app.startOrContinue()
            completion(.earned)
            await drainRewardCallbacks()
            rig.clock.advance(1)
            XCTAssertEqual(app.session, replacement)
            XCTAssertEqual(app.progress.bonusDirect, 0)
            XCTAssertTrue(rig.played.isEmpty)
            XCTAssertTrue(rig.haptics.isEmpty, "Restoring the cancelled offer cannot replay the old board's win.")
        }
    }

    @MainActor func testUnverifiedManifestKeepsExplicitDemoThresholdsAndDoesNotInventAudio() throws {
        let rig = ComboTestRig(), app = model(rig, manifest: .silent, config: DemoConfig(comboThresholds: [1, 2, 3]))
        app.submit(try XCTUnwrap(app.session).puzzle.solution[0]); rig.clock.advance(1)
        XCTAssertEqual(app.comboFeedbackPresentation(for: 1), ComboFeedbackPresentation(text: "Nice", delay: 0))
        XCTAssertTrue(rig.played.isEmpty)
        XCTAssertEqual(rig.haptics, [.correct])
    }

    @MainActor func testFailedRewardPersistenceDoesNotEmitCorrectOrComboUntilRetryCommits() async throws {
        let rig = ComboTestRig(), rewards = ComboRewards()
        let app = model(rig, manifest: manifest(cues: [.init(count: 4, event: "excellent")]),
                        config: DemoConfig(directPerLevel: 0), rewards: rewards)
        for cell in try XCTUnwrap(app.session).puzzle.solution.prefix(3) { app.submit(cell) }
        app.direct()
        let before = try XCTUnwrap(app.session)
        // Fail the receipt transaction using the same real file boundary that the
        // app uses; no mocked success or player method bypass is involved.
        try FileManager.default.removeItem(at: app.saveDirectory)
        try Data("blocked-directory".utf8).write(to: app.saveDirectory)
        try XCTUnwrap(rewards.completion)(.earned)
        let end = ProcessInfo.processInfo.systemUptime + 2
        while app.rewardBusy && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(app.rewardRetryPending)
        XCTAssertNotNil(app.errorMessage)
        XCTAssertEqual(app.session, before)
        rig.clock.advance(0.25)
        XCTAssertTrue(rig.played.isEmpty)
        XCTAssertEqual(rig.haptics, [.correct, .correct, .correct])

        try FileManager.default.removeItem(at: app.saveDirectory)
        try FileManager.default.createDirectory(at: app.saveDirectory, withIntermediateDirectories: true)
        app.runReward() // Retries the retained final signal and commits before feedback.
        XCTAssertFalse(app.rewardRetryPending)
        XCTAssertEqual(app.session?.status, .won)
        rig.clock.advance(0.25)
        XCTAssertEqual(rig.played, ["excellent.wav"])
        XCTAssertEqual(rig.haptics, [.correct, .correct, .correct, .correct, .win])
    }
}
