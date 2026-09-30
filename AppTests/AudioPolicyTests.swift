import XCTest
@testable import Capydoku

@MainActor
private final class AudioTestClock {
    final class Job { let at: Double; let action: () -> Void; var cancelled = false
        init(at: Double, action: @escaping () -> Void) { self.at = at; self.action = action }
    }
    var now = 0.0
    var jobs: [Job] = []
    func schedule(_ delay: Double, _ action: @escaping () -> Void) -> AudioScheduledTask {
        let job = Job(at: now + delay, action: action); jobs.append(job)
        return AudioScheduledTask { job.cancelled = true }
    }
    func advance(_ amount: Double) {
        let target = now + amount
        while let index = jobs.indices.filter({ jobs[$0].at <= target }).min(by: { jobs[$0].at < jobs[$1].at }) {
            let job = jobs.remove(at: index); now = job.at
            if !job.cancelled { job.action() }
        }
        now = target
    }
}
@MainActor
private final class AudioTestHandle: AudioPlaybackHandle {
    let clock: AudioTestClock
    var isPlaying = false
    var duration = 10.0
    private var position = 0.0
    private var started = 0.0
    var currentTime: TimeInterval {
        get { position + (isPlaying ? clock.now - started : 0) }
        set { position = newValue; started = clock.now }
    }
    var volume: Float = 1
    var numberOfLoops = 0
    var playCount = 0, pauseCount = 0, stopCount = 0
    var fades: [(Float, TimeInterval)] = []
    init(_ clock: AudioTestClock) { self.clock = clock }
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { if !isPlaying { started = clock.now }; isPlaying = true; playCount += 1; return true }
    func pause() { position = currentTime; isPlaying = false; pauseCount += 1 }
    func stop() { isPlaying = false; position = 0; stopCount += 1 }
    func setVolume(_ volume: Float, fadeDuration: TimeInterval) { self.volume = volume; fades.append((volume, fadeDuration)) }
}
@MainActor
private final class AudioTestRig {
    let clock = AudioTestClock()
    var handles: [AudioTestHandle] = []
    var sessionChanges: [Bool] = []
    func player(_ manifest: ReferenceAudioManifest, resourcesExist: Bool = true) -> FeedbackPlayer {
        FeedbackPlayer(manifest: manifest,
            resourceResolver: { resourcesExist ? URL(fileURLWithPath: "/contract-test-only/" + $0) : nil },
            playerFactory: { [unowned self] _ in let handle = AudioTestHandle(clock); handles.append(handle); return handle },
            scheduler: clock.schedule, clock: { [unowned self] in clock.now },
            sessionControl: { [unowned self] value in sessionChanges.append(value); return true }, observeSystem: false)
    }
}

final class AudioPolicyTests: XCTestCase {
    private func clip(_ file: String = "reference.wav", group: AudioGroup = .sound) -> AudioClipPolicy {
        AudioClipPolicy(file: file, group: group, volume: 0.6, delay: 0.2, minimumInterval: 0.1,
            maximumConcurrent: 4, overflow: .dropNewest, loops: 0, fadeIn: 0, fadeOut: 0, contextChange: .followCurrentScope,
            scope: AudioScope(pages: [.home, .game], overlays: FeedbackAudioOverlay.allCases))
    }
    private func musicManifest() -> ReferenceAudioManifest {
        var track = clip(group: .music); track.delay = 0; track.fadeIn = 0.3; track.fadeOut = 0.4; track.loops = -1
        var transitions = Dictionary(uniqueKeysWithValues: AudioFlowEvent.allCases.map { ($0.rawValue, AudioMusicAction.unchanged) })
        for event in [AudioFlowEvent.pause, .adStarted, .background, .interruptionBegan, .musicDisabled] { transitions[event.rawValue] = .pause }
        for event in [AudioFlowEvent.contextChanged, .musicEnabled, .resume, .adEnded, .foreground, .interruptionEnded] { transitions[event.rawValue] = .resume }
        transitions[AudioFlowEvent.mediaReset.rawValue] = .restart
        return ReferenceAudioManifest(version: "synthetic-contract-only", referenceVerified: true, clips: ["background_music": track], musicTransitions: transitions)
    }
    @MainActor func testUnverifiedEmptyOrMissingResourceManifestNeverCreatesPlayerOrAudioSession() {
        let rig = AudioTestRig(), player = rig.player(.silent)
        player.setContext(page: .game, level: 1); player.apply(settings: .init(sound: true, haptic: false, voice: true, music: true))
        player.play(.mark); player.play(.win); player.play(.combo(4)); player.playMarks(count: 20)
        rig.clock.advance(20)
        XCTAssertTrue(rig.handles.isEmpty); XCTAssertTrue(rig.sessionChanges.isEmpty)
        let missing = rig.player(musicManifest(), resourcesExist: false)
        XCTAssertTrue(missing.validationErrors.contains("missing resource: background_music"))
        missing.setContext(page: .home); missing.apply(settings: .init(music: true)); rig.clock.advance(20)
        XCTAssertTrue(rig.handles.isEmpty); XCTAssertTrue(rig.sessionChanges.isEmpty)
    }
    func testManifestRejectsUnsafeFilesUnknownGroupsInvalidValuesAndIncompletePolicies() throws {
        var bad = clip("../other.wav", group: .voice)
        bad.volume = .infinity; bad.delay = -1; bad.maximumConcurrent = 0; bad.loops = -2
        bad.scope.pages = []; bad.loopRange = AudioLoopRange(start: 3, end: 2)
        let manifest = ReferenceAudioManifest(version: "test", referenceVerified: true, clips: ["mark_x": bad, "victory": clip()])
        let errors = manifest.validationErrors { _ in true }
        for prefix in ["unsafe", "invalid group", "invalid volume", "invalid delay", "unsupported concurrency", "invalid loop", "invalid scope", "unsupported event"] {
            XCTAssertTrue(errors.contains { $0.hasPrefix(prefix) }, prefix)
        }
        let valid = ReferenceAudioManifest(version: "test", referenceVerified: true, clips: ["mark_x": clip()])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        var clips = try XCTUnwrap(object["clips"] as? [String: [String: Any]])
        clips["mark_x"]?["group"] = "guess"; object["clips"] = clips
        XCTAssertThrowsError(try JSONDecoder().decode(ReferenceAudioManifest.self, from: JSONSerialization.data(withJSONObject: object)))
        var missing = musicManifest(); missing.musicTransitions = [:]
        XCTAssertFalse(missing.validationErrors { _ in true }.isEmpty)
    }
    @MainActor func testPageLevelOverlayScopeAndSettingsCancelPendingClip() {
        var mark = clip(); mark.scope = AudioScope(pages: [.game], overlays: [.none], levels: [2])
        let rig = AudioTestRig(), player = rig.player(ReferenceAudioManifest(version: "test", referenceVerified: true, clips: ["mark_x": mark]))
        player.setContext(page: .home); player.play(.mark)
        player.setContext(page: .game, level: 1); player.play(.mark)
        player.setContext(page: .game, level: 2, overlay: .hint); player.play(.mark)
        rig.clock.advance(1); XCTAssertTrue(rig.handles.isEmpty)
        player.setContext(page: .game, level: 2); player.play(.mark)
        player.apply(settings: .init(sound: false)); rig.clock.advance(1)
        XCTAssertTrue(rig.handles.isEmpty, "Muting must cancel queued work, not merely silence the current player")
        player.apply(settings: .init(sound: true)); player.play(.mark); rig.clock.advance(0.2)
        XCTAssertEqual(rig.handles.count, 1)
    }
    @MainActor func testButtonsComboGroupingIntervalsAndConcurrencyFollowExplicitMappings() {
        var effect = clip(); effect.maximumConcurrent = 1
        let manifest = ReferenceAudioManifest(version: "test", referenceVerified: true,
            clips: ["button_tap": effect, "nice": clip(group: .voice)],
            buttons: ["confirm": AudioButtonPolicy(playWhenDisabled: false)],
            combo: AudioComboPolicy(cues: [AudioComboCue(count: 7, event: "nice")], repeatLast: false))
        let rig = AudioTestRig(), player = rig.player(manifest); player.setContext(page: .game, level: 1)
        player.playButton(id: "unknown"); player.playButton(id: "confirm", enabled: false)
        player.play(.combo(2)); player.play(.combo(7)); rig.clock.advance(1)
        XCTAssertTrue(rig.handles.isEmpty)
        player.playButton(id: "confirm"); player.playButton(id: "confirm"); rig.clock.advance(0.2)
        XCTAssertEqual(rig.handles.count, 1)
        player.playButton(id: "confirm"); rig.clock.advance(0.2)
        XCTAssertEqual(rig.handles.count, 1, "Configured dropNewest limits overlap")
        player.apply(settings: .init(voice: true)); player.play(.combo(7)); rig.clock.advance(0.2)
        XCTAssertEqual(rig.handles.count, 2)
        player.play(.combo(8)); rig.clock.advance(1); XCTAssertEqual(rig.handles.count, 2)
    }
    @MainActor func testAcceptedNavigationClickAndFinalGameplayFeedbackSurviveConfiguredContextChange() {
        var button = clip(); button.contextChange = .completeInTriggerScope
        button.scope = AudioScope(pages: [.home], overlays: [.none])
        var correct = clip(); correct.contextChange = .completeInTriggerScope
        correct.scope = AudioScope(pages: [.game], overlays: [.none])
        let manifest = ReferenceAudioManifest(version: "test", referenceVerified: true,
            clips: ["button_tap": button, "double_tap_correct": correct, "double_tap_wrong": correct],
            buttons: ["start": AudioButtonPolicy(playWhenDisabled: false)])
        let rig = AudioTestRig(), player = rig.player(manifest)
        player.setContext(page: .home); player.playButton(id: "start")
        player.setContext(page: .game, level: 1); rig.clock.advance(0.2)
        XCTAssertEqual(rig.handles.count, 1, "A valid delayed click must not be cancelled merely because it navigates")
        player.play(.correct)
        player.setEnvironment(FeedbackEnvironment(page: .game, level: 1, overlay: .won, blocks: [.inputLocked]))
        rig.clock.advance(0.2); XCTAssertEqual(rig.handles.count, 2)
        player.setEnvironment(FeedbackEnvironment(page: .game, level: 1))
        player.play(.wrong)
        player.setEnvironment(FeedbackEnvironment(page: .game, level: 1, overlay: .lost, blocks: [.inputLocked]))
        rig.clock.advance(0.2); XCTAssertEqual(rig.handles.count, 3)
    }
    @MainActor func testBoardLockDoesNotSilenceMappedOverlayButtonsOrPermitNewBoardEffects() {
        let manifest = ReferenceAudioManifest(version: "test", referenceVerified: true,
            clips: ["button_tap": clip(), "mark_x": clip()],
            buttons: ["close": AudioButtonPolicy(playWhenDisabled: false)])
        let rig = AudioTestRig(), player = rig.player(manifest)
        player.setEnvironment(FeedbackEnvironment(page: .game, level: 1, overlay: .settings, blocks: [.inputLocked]))
        player.playButton(id: "close"); player.play(.mark); rig.clock.advance(0.2)
        XCTAssertEqual(rig.handles.count, 1)
    }
    @MainActor func testSwipeQueuesEveryNewCellAtCadenceAndCancelsOnLiftOrLock() {
        var swipeClip = clip(); swipeClip.minimumInterval = 0.25
        let manifest = ReferenceAudioManifest(version: "test", referenceVerified: true, clips: ["swipe_x": swipeClip],
            swipe: AudioSwipePolicy(mode: .perCell, cadenceSeconds: 0.3, maximumQueued: 3, end: .immediately, cancel: .immediately))
        let rig = AudioTestRig(), player = rig.player(manifest); player.setContext(page: .game, level: 1)
        player.beginSwipe(); player.playMarks(count: 0); player.playMarks(count: 10)
        rig.clock.advance(0.2); XCTAssertEqual(rig.handles.count, 1)
        rig.clock.advance(0.3); XCTAssertEqual(rig.handles.count, 2)
        player.endSwipe(); rig.clock.advance(2)
        XCTAssertEqual(rig.handles.count, 2); XCTAssertTrue(rig.handles.allSatisfy { !$0.isPlaying })
        player.beginSwipe(); player.playMarks(count: 2); player.setBlocked(.inputLocked, active: true)
        rig.clock.advance(2); XCTAssertEqual(rig.handles.count, 2)
    }
    @MainActor func testContinuousSwipeStartsOnceAndFinishCurrentRemovesLooping() {
        var swipeClip = clip(); swipeClip.loops = -1
        let manifest = ReferenceAudioManifest(version: "test", referenceVerified: true, clips: ["swipe_x": swipeClip],
            swipe: AudioSwipePolicy(mode: .continuous, cadenceSeconds: 0, maximumQueued: 1, end: .finishCurrent, cancel: .immediately))
        let rig = AudioTestRig(), player = rig.player(manifest); player.setContext(page: .game, level: 1)
        player.beginSwipe(); player.playMarks(count: 10); player.playMarks(count: 4); rig.clock.advance(0.2)
        XCTAssertEqual(rig.handles.count, 1); XCTAssertEqual(rig.handles[0].numberOfLoops, -1)
        player.endSwipe(); XCTAssertEqual(rig.handles[0].numberOfLoops, 0)
        player.beginSwipe(); XCTAssertFalse(rig.handles[0].isPlaying)
    }
    @MainActor func testEffectFadeOutUsesFinitePlaybackEndAndMuteCancelsDelayedFade() {
        var sound = clip(); sound.delay = 0; sound.fadeOut = 0.5
        let manifest = ReferenceAudioManifest(version: "test", referenceVerified: true, clips: ["mark_x": sound])
        let rig = AudioTestRig(), player = rig.player(manifest); player.setContext(page: .game, level: 1)
        player.play(.mark); rig.clock.advance(0)
        let first = rig.handles[0]
        rig.clock.advance(9.49); XCTAssertEqual(first.fades.count, 1)
        rig.clock.advance(0.01); XCTAssertEqual(first.fades.last?.0, 0); XCTAssertEqual(first.fades.last?.1, 0.5)
        XCTAssertTrue(first.isPlaying)
        rig.clock.advance(0.5); XCTAssertFalse(first.isPlaying)
        player.play(.mark); rig.clock.advance(0)
        let second = rig.handles[1]; player.apply(settings: .init(sound: false))
        rig.clock.advance(20)
        XCTAssertFalse(second.isPlaying); XCTAssertEqual(second.fades.count, 1, "Mute cancels the pending fade instead of replaying any audio")
    }
    @MainActor func testMusicUsesConfiguredResumeRestartFadeAndAtomicBlocking() {
        var manifest = musicManifest(); manifest.musicTransitions?[AudioFlowEvent.foreground.rawValue] = .restart
        let rig = AudioTestRig(), player = rig.player(manifest)
        player.setContext(page: .game, level: 1); player.apply(settings: .init(music: true)); rig.clock.advance(0)
        let music = rig.handles[0]
        XCTAssertEqual(music.fades.last?.0, 0.6); XCTAssertEqual(music.fades.last?.1, 0.3)
        music.currentTime = 3; player.setBlocked(.advertisement, active: true)
        XCTAssertEqual(music.fades.last?.1, 0.4); rig.clock.advance(0.4)
        XCTAssertFalse(music.isPlaying); let pausedAt = music.currentTime
        player.setBlocked(.advertisement, active: false); rig.clock.advance(0)
        XCTAssertEqual(music.currentTime, pausedAt); XCTAssertEqual(music.playCount, 2)
        player.setBlocked(.advertisement, active: true); rig.clock.advance(0.4)
        player.setEnvironment(FeedbackEnvironment(page: .game, level: 1, blocks: [.background]))
        rig.clock.advance(0.4); XCTAssertEqual(music.playCount, 2, "Ad ending during background must not resume")
        player.setBlocked(.background, active: false); rig.clock.advance(0)
        XCTAssertEqual(music.currentTime, 0); XCTAssertEqual(music.playCount, 3)
    }
    @MainActor func testOverlayAndInputLockDoNotInventMusicPausePolicy() {
        let rig = AudioTestRig(), player = rig.player(musicManifest())
        player.setContext(page: .game, level: 1); player.apply(settings: .init(music: true)); rig.clock.advance(0)
        let music = rig.handles[0]
        player.setEnvironment(FeedbackEnvironment(page: .game, level: 1, overlay: .hint, blocks: [.inputLocked]))
        rig.clock.advance(1)
        XCTAssertTrue(music.isPlaying); XCTAssertEqual(music.pauseCount, 0)
        XCTAssertEqual(music.playCount, 1)
    }
    @MainActor func testCustomLoopPointsAndRuntimeDurationValidation() {
        var manifest = musicManifest(); manifest.clips["background_music"]?.loops = 2
        manifest.clips["background_music"]?.loopRange = AudioLoopRange(start: 2, end: 6)
        let rig = AudioTestRig(), player = rig.player(manifest)
        player.setContext(page: .game, level: 1); player.apply(settings: .init(music: true)); rig.clock.advance(0)
        let music = rig.handles[0]; XCTAssertEqual(music.numberOfLoops, 0)
        rig.clock.advance(6); XCTAssertEqual(music.currentTime, 2)
        rig.clock.advance(4); XCTAssertEqual(music.currentTime, 2)
        rig.clock.advance(4); XCTAssertEqual(music.currentTime, 6, "Finite custom repeats must finish")
        manifest.clips["background_music"]?.loopRange = AudioLoopRange(start: 2, end: 20)
        let invalidRig = AudioTestRig(), invalid = invalidRig.player(manifest)
        invalid.setContext(page: .home); invalid.apply(settings: .init(music: true)); invalidRig.clock.advance(0)
        XCTAssertEqual(invalidRig.handles[0].playCount, 0, "A file shorter than the imported loop range must be rejected")
    }
    @MainActor func testSystemInterruptionHonorsResumePermissionSettingsAndMediaResetPolicy() {
        let rig = AudioTestRig(), player = rig.player(musicManifest())
        player.setContext(page: .game, level: 1); player.apply(settings: .init(music: true)); rig.clock.advance(0)
        let original = rig.handles[0]
        player.handleInterruption(began: true, shouldResume: false); rig.clock.advance(0.4)
        player.handleInterruption(began: false, shouldResume: false)
        player.apply(settings: .init(music: true)); rig.clock.advance(1)
        XCTAssertFalse(original.isPlaying); XCTAssertEqual(original.playCount, 1)
        player.handleInterruption(began: false, shouldResume: true); rig.clock.advance(0)
        XCTAssertTrue(original.isPlaying); XCTAssertEqual(original.playCount, 2)
        player.handleMediaServicesReset(); rig.clock.advance(0)
        XCTAssertFalse(original.isPlaying); XCTAssertEqual(rig.handles.count, 2)
        player.apply(settings: .init(music: false)); rig.clock.advance(0.4)
        player.handleInterruption(began: true, shouldResume: false)
        player.handleInterruption(began: false, shouldResume: true); rig.clock.advance(1)
        XCTAssertFalse(rig.handles[1].isPlaying)
    }
}
