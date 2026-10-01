import XCTest
import AVFoundation
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

// Integration diagnostics for the user's local, unverified audio experiment.
// Pre-fix evidence: Validation/test-runs/original-0227-audio-baseline.log
// and the matching original-0227-audio-baseline.xcresult bundle.
// These verify the chosen local behavior, not source-game timing acceptance.
@MainActor
private final class AudioExperienceDiagnosticRig {
    let clock = AudioTestClock()
    var handles: [AudioTestHandle] = []
    var resources: [String] = []
    var sessionChanges: [Bool] = []
    func player() throws -> FeedbackPlayer {
        guard let local = LocalTestAudioImport.load() else { throw XCTSkip("Local-only audio is deliberately absent from clean clones and distribution builds") }
        XCTAssertFalse(local.manifest.referenceVerified)
        let player = FeedbackPlayer(playerFactory: { [unowned self] url in
            let handle = AudioTestHandle(clock)
            // Read the real file's duration, but never send audio to an output device.
            handle.duration = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
            handles.append(handle); resources.append(url.lastPathComponent)
            return handle
        }, scheduler: clock.schedule, clock: { [unowned self] in clock.now },
           sessionControl: { [unowned self] active in sessionChanges.append(active); return true }, observeSystem: false)
        XCTAssertTrue(player.usesLocalTestAudio)
        XCTAssertTrue(player.validationErrors.isEmpty)
        XCTAssertFalse(player.hasVerifiedComboConfiguration)
        player.apply(settings: .init(sound: true, haptic: false, voice: true, music: false))
        player.setContext(page: .game, level: 1)
        return player
    }
}

extension AudioPolicyTests {
    private func groupedVoiceManifest() -> ReferenceAudioManifest {
        var voice = clip(group: .voice)
        voice.delay = 0; voice.minimumInterval = 0; voice.maximumConcurrent = 1
        voice.overflow = .stopOldest; voice.concurrencyGroup = "test-combo"
        return ReferenceAudioManifest(version: "synthetic-group-contract", referenceVerified: true,
            clips: ["nice": voice, "great": voice, "excellent": voice],
            combo: .init(cues: [.init(count: 2, event: "nice"), .init(count: 3, event: "great"), .init(count: 4, event: "excellent")], repeatLast: true))
    }
    private func finishingSwipeManifest(delay: Double = 0, end: AudioSwipeStop = .finishCurrent,
                                        cadence: Double = 0.075) -> ReferenceAudioManifest {
        var effect = clip(); effect.delay = delay; effect.minimumInterval = 0
        effect.maximumConcurrent = 3; effect.overflow = .stopOldest
        return ReferenceAudioManifest(version: "synthetic-swipe-contract", referenceVerified: true, clips: ["swipe_x": effect],
            swipe: .init(mode: .perCell, cadenceSeconds: cadence, maximumQueued: 12, end: end, cancel: .immediately))
    }

    func testConcurrencyGroupsValidateNamesCategoriesAndSharedLimitPolicy() throws {
        let valid = groupedVoiceManifest()
        XCTAssertTrue(valid.validationErrors { _ in true }.isEmpty)
        for name in ["", "white space", "../other", String(repeating: "x", count: 65), "语音"] {
            var invalid = valid; invalid.clips["nice"]?.concurrencyGroup = name
            XCTAssertTrue(invalid.validationErrors { _ in true }.contains { $0.hasPrefix("invalid concurrency group:") })
        }
        for mismatch in 0..<3 {
            var invalid = valid
            if mismatch == 0 { invalid.clips["nice"]?.group = .sound }
            if mismatch == 1 { invalid.clips["nice"]?.maximumConcurrent = 2 }
            if mismatch == 2 { invalid.clips["nice"]?.overflow = .dropNewest }
            XCTAssertTrue(invalid.validationErrors { _ in true }.contains("inconsistent concurrency group policy: test-combo"))
        }
        var music = musicManifest(); music.clips["background_music"]?.concurrencyGroup = "test-music"
        XCTAssertTrue(music.validationErrors { _ in true }.contains { $0.hasPrefix("music cannot share") })
        let old = ReferenceAudioManifest(version: "old-contract", referenceVerified: true, clips: ["mark_x": clip()])
        let decoded = try JSONDecoder().decode(ReferenceAudioManifest.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.clips["mark_x"]?.concurrencyGroup)
    }

    @MainActor func testExplicitSharedChannelReplacesOldVoiceWithoutStoppingOtherGroupsOrSound() {
        var manifest = groupedVoiceManifest()
        manifest.clips["excellent"]?.concurrencyGroup = "other-voice"
        var sound = clip(); sound.delay = 0; sound.minimumInterval = 0
        manifest.clips["double_tap_correct"] = sound
        let rig = AudioTestRig(), player = rig.player(manifest)
        player.apply(settings: .init(haptic: false, voice: true)); player.setContext(page: .game)
        player.play(.combo(2)); rig.clock.advance(0)
        player.play(.correct); player.play(.combo(4)); rig.clock.advance(0)
        player.play(.combo(3)); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 4)
        XCTAssertEqual(rig.handles.map(\.stopCount), [1, 0, 0, 0])
        XCTAssertEqual(rig.handles.filter(\.isPlaying).count, 3)
        player.apply(settings: .init(haptic: false, voice: false))
        XCTAssertTrue(rig.handles[1].isPlaying)
        XCTAssertFalse(rig.handles[2].isPlaying); XCTAssertFalse(rig.handles[3].isPlaying)
        player.setBlocked(.background, active: true)
        XCTAssertTrue(rig.handles.allSatisfy { !$0.isPlaying })
    }

    @MainActor func testAbsentConcurrencyGroupKeepsDistinctVoiceKeysIndependent() {
        var manifest = groupedVoiceManifest()
        for key in manifest.clips.keys { manifest.clips[key]?.concurrencyGroup = nil }
        let rig = AudioTestRig(), player = rig.player(manifest)
        player.apply(settings: .init(haptic: false, voice: true)); player.setContext(page: .game)
        for count in [2, 3, 4] { player.play(.combo(count)); rig.clock.advance(0) }
        XCTAssertEqual(rig.handles.filter(\.isPlaying).count, 3)
        XCTAssertTrue(rig.handles.allSatisfy { $0.stopCount == 0 })
    }

    @MainActor func testSharedChannelDropNewestAndMutedPendingVoiceHonorExplicitPolicy() {
        var manifest = groupedVoiceManifest()
        for key in manifest.clips.keys { manifest.clips[key]?.overflow = .dropNewest }
        let rig = AudioTestRig(), player = rig.player(manifest)
        player.apply(settings: .init(haptic: false, voice: true)); player.setContext(page: .game)
        player.play(.combo(2)); rig.clock.advance(0)
        player.play(.combo(3)); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 1); XCTAssertTrue(rig.handles[0].isPlaying)
        player.play(.combo(4)); player.apply(settings: .init(haptic: false, voice: false)); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 1); XCTAssertFalse(rig.handles[0].isPlaying)
    }

    @MainActor func testFinishCurrentSwipeCompletesAtMostOneDueCueAndNeverDrainsFutureQueue() {
        for cadence in [0.0, 0.075] {
            let rig = AudioTestRig(), player = rig.player(finishingSwipeManifest(cadence: cadence))
            player.setContext(page: .game); player.beginSwipe(); player.playMarks(count: 12)
            player.endSwipe(); XCTAssertEqual(rig.handles.count, 1)
            XCTAssertEqual(rig.handles[0].stopCount, 0)
            rig.clock.advance(2)
            XCTAssertEqual(rig.handles.count, 1, "Normal release cannot drain the 12-cell queue, even if every cue was already due")
        }
        let rig = AudioTestRig(), player = rig.player(finishingSwipeManifest(delay: 0.1))
        player.setContext(page: .game); player.beginSwipe(); player.playMarks(count: 4); player.endSwipe()
        rig.clock.advance(1); XCTAssertTrue(rig.handles.isEmpty, "Future cues must not be played early")
    }

    @MainActor func testFinishCurrentSwipeCancellationMuteLockBackgroundAndNewGestureCannotFlushCue() {
        for stop in 0..<5 {
            let rig = AudioTestRig(), player = rig.player(finishingSwipeManifest())
            player.setContext(page: .game); player.beginSwipe(); player.playMarks(count: 3)
            switch stop {
            case 0: player.endSwipe(cancelled: true) // Includes leaving the board.
            case 1: player.apply(settings: .init(sound: false, haptic: false))
            case 2: player.setBlocked(.inputLocked, active: true)
            case 3: player.setBlocked(.background, active: true)
            default: player.beginSwipe()
            }
            rig.clock.advance(1); XCTAssertTrue(rig.handles.isEmpty)
        }
        let rig = AudioTestRig(), player = rig.player(finishingSwipeManifest())
        player.setContext(page: .game); player.beginSwipe(); player.playMarks(count: 1); player.endSwipe()
        XCTAssertEqual(rig.handles.count, 1); XCTAssertTrue(rig.handles[0].isPlaying)
        player.beginSwipe()
        XCTAssertFalse(rig.handles[0].isPlaying, "A new gesture stops the previous finishing clip")
    }

    @MainActor func testImmediateSwipeStillDropsAllPendingCuesOnNormalRelease() {
        let rig = AudioTestRig(), player = rig.player(finishingSwipeManifest(end: .immediately))
        player.setContext(page: .game); player.beginSwipe(); player.playMarks(count: 3); player.endSwipe()
        rig.clock.advance(1); XCTAssertTrue(rig.handles.isEmpty)
    }

    @MainActor func testExperienceDiagnosticLocalComboSharesOneVoiceChannel() throws {
        let rig = AudioExperienceDiagnosticRig(), player = try rig.player()
        player.play(.combo(2)); rig.clock.advance(0.2)
        player.play(.combo(3)); rig.clock.advance(0.2)
        player.play(.combo(4)); rig.clock.advance(0)
        XCTAssertEqual(rig.resources, ["meow-test-combo_nice_s6.wav", "meow-test-combo_great_s6.wav", "meow-test-combo_excellent_s6.wav"])
        XCTAssertEqual(rig.handles.filter(\.isPlaying).count, 1)
        XCTAssertEqual(rig.handles.map(\.stopCount), [1, 1, 0])
        XCTAssertTrue(rig.handles[2].isPlaying)
        XCTAssertTrue(rig.handles.allSatisfy { $0.currentTime < $0.duration })
        print("AUDIO_DIAGNOSTIC combo: only latest Excellent remains playing at t=0.400; preceding Nice and Great each stopped once")
    }

    @MainActor func testExperienceDiagnosticLocalSwipeLiftPreservesActiveClipsWithoutFutureTail() throws {
        let rig = AudioExperienceDiagnosticRig(), player = try rig.player()
        player.beginSwipe(); player.playMarks(count: 5)
        rig.clock.advance(0.08)
        XCTAssertEqual(rig.handles.count, 2)
        XCTAssertTrue(rig.handles.allSatisfy { $0.isPlaying && $0.currentTime < $0.duration })
        player.endSwipe(cancelled: false); rig.clock.advance(1)
        XCTAssertEqual(rig.handles.count, 2)
        XCTAssertTrue(rig.handles.allSatisfy { $0.stopCount == 0 })
        print("AUDIO_DIAGNOSTIC swipe: five accepted cells, lift at 80ms: two active 182ms clips are not stopped; three future cues discarded, no long tail")
    }

    @MainActor func testExperienceDiagnosticLocalSwipeEndingInSameCallbackCompletesOneDueClip() throws {
        let rig = AudioExperienceDiagnosticRig(), player = try rig.player()
        // PuzzleBoardUIView.pan(.ended) can mark fresh cells and finish the swipe
        // in the same callback; delay zero still schedules a later main-queue job.
        player.beginSwipe(); player.playMarks(count: 3); player.endSwipe(cancelled: false)
        rig.clock.advance(1)
        XCTAssertEqual(rig.handles.count, 1)
        XCTAssertEqual(rig.handles[0].playCount, 1); XCTAssertEqual(rig.handles[0].stopCount, 0)
        print("AUDIO_DIAGNOSTIC swipe: three newly accepted cells in ending callback: one already-due short clip starts, future cues discarded")
    }

    @MainActor func testExperienceDiagnosticLocalFinalHitAndComboSurviveWonOverlay() throws {
        let rig = AudioExperienceDiagnosticRig(), player = try rig.player()
        player.play(.correct); player.play(.combo(4))
        player.setEnvironment(.init(page: .game, level: 1, overlay: .won, blocks: [.inputLocked]))
        rig.clock.advance(0)
        XCTAssertEqual(Set(rig.resources), ["meow-test-mark_cat.wav", "meow-test-combo_excellent_s6.wav"])
        XCTAssertTrue(rig.handles.allSatisfy { $0.isPlaying && $0.stopCount == 0 })
        rig.clock.advance(0.5)
        XCTAssertTrue(rig.handles.allSatisfy { $0.isPlaying && $0.stopCount == 0 })
        print("AUDIO_DIAGNOSTIC final hit: correct and Excellent both start after won/inputLocked and remain uncut at 500ms")
    }

    @MainActor func testExperienceDiagnosticLocalEveryShortEffectCreatesPlayerAtDeferredTrigger() throws {
        let rig = AudioExperienceDiagnosticRig(), player = try rig.player()
        XCTAssertTrue(rig.handles.isEmpty); XCTAssertTrue(rig.sessionChanges.isEmpty)
        player.play(.mark)
        XCTAssertTrue(rig.handles.isEmpty, "Zero-delay cue still waits for its scheduled callback")
        rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 1); XCTAssertEqual(rig.sessionChanges, [true])
        rig.clock.advance(0.25); player.play(.mark); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 2)
        XCTAssertEqual(rig.resources, ["meow-test-mark_x_2.wav", "meow-test-mark_x_2.wav"])
        print("AUDIO_DIAGNOSTIC latency architecture: no prepared player at first event; both marks create fresh players inside the scheduled callback; device latency not measured")
    }

    @MainActor func testExperienceDiagnosticLocalMusicCoexistsWithEffectsAndSettingsBackgroundResume() throws {
        let rig = AudioExperienceDiagnosticRig(), player = try rig.player()
        player.apply(settings: .init(sound: true, haptic: false, voice: true, music: true)); rig.clock.advance(0)
        player.play(.correct); player.play(.combo(2)); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.filter(\.isPlaying).count, 3)
        let music = try XCTUnwrap(zip(rig.resources, rig.handles).first { $0.0.contains("bgm_") }?.1)
        XCTAssertEqual(music.volume, 0.4)
        XCTAssertEqual(music.fades.last?.0, 0.4, "No voice ducking is currently configured")
        player.apply(settings: .init(sound: true, haptic: false, voice: false, music: true))
        XCTAssertEqual(rig.handles.filter(\.isPlaying).count, 2)
        player.setBlocked(.background, active: true); rig.clock.advance(0.16)
        XCTAssertTrue(rig.handles.allSatisfy { !$0.isPlaying })
        XCTAssertEqual(rig.sessionChanges.last, false)
        player.setBlocked(.background, active: false); rig.clock.advance(0)
        XCTAssertTrue(music.isPlaying); XCTAssertEqual(music.playCount, 2)
        XCTAssertEqual(rig.handles.filter(\.isPlaying).count, 1)
        print("AUDIO_DIAGNOSTIC routing: BGM+correct+Nice coexist; voice mute stops voice only; background stops effects and pauses BGM; foreground resumes existing BGM only")
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
    var prepareCount = 0
    var preparationSucceeds = true
    func prepareToPlay() -> Bool { prepareCount += 1; return preparationSucceeds }
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
    var onPlayerCreated: (() -> Void)?
    func player(_ manifest: ReferenceAudioManifest, resourcesExist: Bool = true) -> FeedbackPlayer {
        FeedbackPlayer(manifest: manifest,
            resourceResolver: { resourcesExist ? URL(fileURLWithPath: "/contract-test-only/" + $0) : nil },
            playerFactory: { [unowned self] _ in let handle = AudioTestHandle(clock); handles.append(handle); onPlayerCreated?(); return handle },
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
    @MainActor func testPreparedEffectsStartWithoutConstructingOrPreparingInsideTheCue() async {
        var effect = clip(); effect.delay = 0; effect.minimumInterval = 0; effect.maximumConcurrent = 2
        let rig = AudioTestRig(), player = rig.player(ReferenceAudioManifest(version: "pool", referenceVerified: true, clips: ["mark_x": effect]))
        player.setContext(page: .game)
        await player.prepareShortEffects()
        XCTAssertEqual(rig.handles.count, 2)
        XCTAssertTrue(rig.handles.allSatisfy { $0.prepareCount == 1 && $0.playCount == 0 })
        XCTAssertTrue(rig.sessionChanges.isEmpty, "Warming does not explicitly activate the playback session or play audio")
        player.play(.mark); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 2)
        XCTAssertEqual(rig.handles.map(\.playCount), [1, 0])
        XCTAssertEqual(rig.handles.map(\.prepareCount), [1, 1])
        XCTAssertEqual(rig.handles[0].volume, effect.volume)
        rig.handles[0].isPlaying = false // Controlled natural completion.
        rig.clock.advance(10.04)
        XCTAssertEqual(rig.handles[0].prepareCount, 2)
        player.play(.mark); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 2)
        XCTAssertEqual(rig.handles[0].playCount, 2)
        XCTAssertEqual(rig.handles[0].currentTime, 0)
    }

    @MainActor func testPreparedFilePoolDeduplicatesMarkAndSwipeWithoutSharingActiveCursor() async {
        var effect = clip(); effect.delay = 0; effect.minimumInterval = 0; effect.maximumConcurrent = 3
        let manifest = ReferenceAudioManifest(version: "shared-file-pool", referenceVerified: true,
            clips: ["mark_x": effect, "swipe_x": effect],
            swipe: .init(mode: .perCell, cadenceSeconds: 0, maximumQueued: 12, end: .finishCurrent, cancel: .immediately))
        let rig = AudioTestRig(), player = rig.player(manifest)
        player.setContext(page: .game); await player.prepareShortEffects(); await player.prepareShortEffects()
        XCTAssertEqual(rig.handles.count, 6, "One bounded resource pool, no duplicate prewarm on reentry")
        player.play(.mark); rig.clock.advance(0)
        player.beginSwipe(); player.playMarks(count: 3); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.filter(\.isPlaying).count, 4)
        XCTAssertEqual(rig.handles.filter { $0.playCount == 1 }.count, 4)
        player.endSwipe(cancelled: true); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.filter(\.isPlaying).count, 1, "Cancelling swipe cannot stop the distinct single-tap voice")
    }

    @MainActor func testPreparedPoolBudgetsDoNotBecomePlaybackConcurrencyLimits() async {
        var effect = clip(); effect.delay = 0; effect.minimumInterval = 0; effect.maximumConcurrent = 8
        var clips: [String: AudioClipPolicy] = [:]
        for event in ["mark_x", "swipe_x", "erase_x", "double_tap_correct", "double_tap_wrong"] {
            var sample = effect; sample.file = event + ".wav"; clips[event] = sample
        }
        let manifest = ReferenceAudioManifest(version: "bounded-pool", referenceVerified: true, clips: clips,
            swipe: .init(mode: .perCell, cadenceSeconds: 0, maximumQueued: 12, end: .finishCurrent, cancel: .immediately))
        let rig = AudioTestRig(), player = rig.player(manifest)
        player.setContext(page: .game); await player.prepareShortEffects()
        XCTAssertEqual(rig.handles.count, 24)
        for _ in 0..<8 { player.play(.correct); rig.clock.advance(0) }
        XCTAssertEqual(rig.handles.filter(\.isPlaying).count, 8, "Two uncached fallback handles preserve the imported limit of eight")
        XCTAssertEqual(rig.handles.count, 26)
        player.play(.correct); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 26, "The ninth remains rejected by the original dropNewest policy")
    }

    @MainActor func testPreparedPlaybackRetainsDelayAndCancelsQueuedCueWhenMuted() async {
        let rig = AudioTestRig(), player = rig.player(ReferenceAudioManifest(version: "delayed-pool", referenceVerified: true, clips: ["mark_x": clip()]))
        player.setContext(page: .game); await player.prepareShortEffects()
        player.play(.mark); rig.clock.advance(0.19)
        XCTAssertTrue(rig.handles.allSatisfy { $0.playCount == 0 })
        player.apply(settings: .init(sound: false)); rig.clock.advance(1)
        XCTAssertTrue(rig.handles.allSatisfy { $0.playCount == 0 })
        await player.prepareShortEffects()
        XCTAssertEqual(rig.handles.count, 4, "Disabled sound cannot be warmed or replayed")
        player.apply(settings: .init(sound: true)); await player.prepareShortEffects()
        player.play(.mark); rig.clock.advance(0.2)
        XCTAssertEqual(rig.handles.filter { $0.playCount > 0 }.count, 1)
        XCTAssertEqual(rig.handles.count, 8, "A new setting generation does not reuse invalidated handles")
    }

    @MainActor func testPreparedHandlesAreInvalidatedAcrossBackgroundInterruptionAndMediaReset() async {
        var effect = clip(); effect.delay = 0; effect.minimumInterval = 0; effect.maximumConcurrent = 1
        for boundary in 0..<4 {
            let rig = AudioTestRig(), player = rig.player(ReferenceAudioManifest(version: "lifecycle-pool", referenceVerified: true, clips: ["mark_x": effect]))
            player.setContext(page: .game); await player.prepareShortEffects()
            player.play(.mark); rig.clock.advance(0)
            switch boundary {
            case 0: player.setBlocked(.background, active: true)
            case 1, 3: player.handleInterruption(began: true, shouldResume: false)
            default: player.handleMediaServicesReset()
            }
            XCTAssertFalse(rig.handles[0].isPlaying)
            rig.clock.advance(0)
            XCTAssertEqual(rig.handles[0].prepareCount, 1, "The old queued recycle must be invalidated")
            if boundary == 0 { player.setBlocked(.background, active: false) }
            if boundary == 1 { player.handleInterruption(began: false, shouldResume: true) }
            if boundary == 3 {
                player.handleInterruption(began: false, shouldResume: false)
                await player.prepareShortEffects()
                player.play(.mark); rig.clock.advance(0)
                XCTAssertEqual(rig.handles.count, 1, "No automatic preparation or playback without shouldResume")
                let warmed = expectation(description: "Explicit music re-enable rebuilds the short-effect cache")
                rig.onPlayerCreated = { if rig.handles.count == 2 { warmed.fulfill() } }
                player.apply(settings: .init(sound: true, haptic: false, voice: false, music: true))
                await fulfillment(of: [warmed], timeout: 1)
                rig.onPlayerCreated = nil
            } else { await player.prepareShortEffects() }
            player.play(.mark); rig.clock.advance(0)
            XCTAssertEqual(rig.handles.count, 2)
            XCTAssertEqual(rig.handles.map(\.playCount), [1, 1])
            player.setBlocked(.background, active: true)
        }
    }

    @MainActor func testPreparedStopOldestAndStaleCleanupNeverStopAReusedHandle() async {
        var effect = clip(); effect.delay = 0; effect.minimumInterval = 0; effect.maximumConcurrent = 1; effect.overflow = .stopOldest
        let rig = AudioTestRig(), player = rig.player(ReferenceAudioManifest(version: "reuse-pool", referenceVerified: true, clips: ["mark_x": effect]))
        player.setContext(page: .game); await player.prepareShortEffects()
        rig.handles[0].duration = 0.2
        player.play(.mark); rig.clock.advance(0)
        rig.clock.advance(0.05); player.play(.mark); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 2, "A just-stopped handle is not leased before deferred re-preparation")
        rig.clock.advance(0.05); player.play(.mark); rig.clock.advance(0)
        XCTAssertEqual(rig.handles[0].playCount, 2)
        XCTAssertTrue(rig.handles[0].isPlaying)
        rig.clock.advance(0.15) // Beyond the first lease's old completion callback.
        XCTAssertTrue(rig.handles[0].isPlaying)
        XCTAssertEqual(rig.handles[0].stopCount, 1)
        XCTAssertEqual(rig.handles[1].stopCount, 1)
    }

    @MainActor func testFailedIdlePreparationFallsBackWithoutLosingCueAndExplicitWarmRecoversReuse() async {
        var effect = clip(); effect.delay = 0; effect.minimumInterval = 0; effect.maximumConcurrent = 1
        let rig = AudioTestRig(), player = rig.player(ReferenceAudioManifest(version: "recover-pool", referenceVerified: true, clips: ["mark_x": effect]))
        player.setContext(page: .game); await player.prepareShortEffects()
        let cached = rig.handles[0]; cached.duration = 0.2
        player.play(.mark); rig.clock.advance(0)
        cached.preparationSucceeds = false; cached.isPlaying = false
        rig.clock.advance(0.25) // Natural completion followed by a transient prepare failure.
        let attempts = cached.prepareCount
        await player.prepareShortEffects()
        XCTAssertEqual(cached.prepareCount, attempts + 1, "One failed retry per request; no busy retry loop")
        XCTAssertEqual(cached.playCount, 1, "Preparation cannot replay the completed cue")
        player.play(.mark); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 2)
        let fallback = rig.handles[1]
        XCTAssertTrue(fallback.isPlaying, "An unavailable cache must not swallow a valid cue")
        cached.preparationSucceeds = true
        await player.prepareShortEffects()
        XCTAssertTrue(fallback.isPlaying, "Rewarming an idle handle cannot disturb the active fallback")
        XCTAssertEqual(fallback.stopCount, 0)
        fallback.isPlaying = false
        player.play(.mark); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 2, "The recovered cache is reused without another construction")
        XCTAssertTrue(cached.isPlaying); XCTAssertEqual(cached.playCount, 2)
        XCTAssertEqual(cached.currentTime, 0)
    }

    @MainActor func testUnverifiedAndMutedPoolWarmupDoesNotReadOrPrepareAudio() async {
        let rig = AudioTestRig(), player = rig.player(.silent)
        await player.prepareShortEffects()
        XCTAssertTrue(rig.handles.isEmpty); XCTAssertTrue(rig.sessionChanges.isEmpty)
        let local = AudioTestRig(), muted = local.player(ReferenceAudioManifest(version: "muted-pool", referenceVerified: true, clips: ["mark_x": clip()]))
        muted.apply(settings: .init(sound: false, haptic: false, voice: false, music: false))
        await muted.prepareShortEffects()
        XCTAssertTrue(local.handles.isEmpty); XCTAssertTrue(local.sessionChanges.isEmpty)
    }

    @MainActor func testLocalPreparedAudioKeepsWaveformsAndPolicyButRemovesCueTimeCreation() async throws {
        let rig = AudioExperienceDiagnosticRig(), player = try rig.player()
        await player.prepareShortEffects()
        XCTAssertEqual(rig.handles.count, 21)
        XCTAssertEqual(Set(rig.resources).count, 8, "Music is not a prepared short effect; mark and swipe share their file pool")
        XCTAssertTrue(rig.handles.allSatisfy { $0.playCount == 0 && $0.prepareCount == 1 })
        player.play(.correct); player.play(.combo(2)); rig.clock.advance(0)
        XCTAssertEqual(rig.handles.count, 21)
        XCTAssertEqual(rig.handles.filter(\.isPlaying).count, 2)
        XCTAssertTrue(rig.handles.allSatisfy { $0.prepareCount == 1 })
        print("AUDIO_DIAGNOSTIC prepared local playback: 21 bounded handles / 8 unchanged effect files warmed before input; correct + Nice create/prepare zero additional players at their scheduled cue. No physical output latency measured.")
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
