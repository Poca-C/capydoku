import XCTest
@testable import Capydoku

@MainActor
private final class HapticTestDriver: HapticFeedbackDriver {
    var preparations: [HapticFeedbackPattern] = []
    var emissions: [HapticFeedbackPattern] = []
    func prepare(_ pattern: HapticFeedbackPattern) { preparations.append(pattern) }
    func emit(_ pattern: HapticFeedbackPattern) { emissions.append(pattern) }
}

@MainActor
private final class HapticTestRig {
    let driver = HapticTestDriver()
    var now: TimeInterval = 0
    var observed: [FeedbackEvent] = []
    var audioSessionChanges: [Bool] = []
    lazy var player = FeedbackPlayer(manifest: .silent, clock: { [unowned self] in now },
        sessionControl: { [unowned self] active in audioSessionChanges.append(active); return true },
        observeSystem: false, hapticEmitter: { [unowned self] in observed.append($0) }, hapticDriver: driver)

    func enterGame(level: Int = 1) { player.setEnvironment(FeedbackEnvironment(page: .game, level: level)) }
}

final class HapticFeedbackTests: XCTestCase {
    @MainActor func testMarkEraseAndSwipeShareLightThrottleWithoutQueuedPulses() {
        let rig = HapticTestRig(); rig.enterGame()
        rig.player.play(.mark)
        rig.now = 0.02; rig.player.play(.erase)
        rig.player.beginSwipe(); rig.player.playMarks(count: 15)
        XCTAssertEqual(rig.driver.emissions, [.selection])
        rig.now = 0.061; rig.player.playMarks(count: 6)
        rig.now = 0.08; rig.player.playMarks(count: 1)
        rig.player.endSwipe(cancelled: true)
        rig.now = 20
        XCTAssertEqual(rig.driver.emissions, [.selection, .selection], "A suppressed batch is dropped, never replayed after a swipe ends")
        rig.player.play(.erase)
        XCTAssertEqual(rig.observed, [.mark, .mark, .erase])
    }

    @MainActor func testZeroOrNegativeMarkCountsAndGestureStartOrEndHaveNoPulse() {
        let rig = HapticTestRig(); rig.enterGame()
        rig.player.beginSwipe(); rig.player.playMarks(count: 0); rig.player.playMarks(count: -1)
        rig.player.endSwipe(); rig.player.endSwipe(cancelled: true)
        XCTAssertTrue(rig.driver.emissions.isEmpty)
        XCTAssertTrue(rig.observed.isEmpty)
    }

    @MainActor func testCorrectErrorAndVictoryRemainDistinctAndComboAddsNoPulse() {
        let rig = HapticTestRig(); rig.enterGame()
        rig.player.play(.correct); rig.player.play(.combo(1))
        rig.player.play(.wrong)
        rig.player.play(.correct); rig.player.play(.combo(2)); rig.player.play(.win)
        XCTAssertEqual(rig.driver.emissions, [.correct, .error, .correct, .success])
        XCTAssertEqual(rig.observed, [.correct, .wrong, .correct, .win], "Distinct accepted moves are not lost to the light-mark throttle")
    }

    @MainActor func testHapticSwitchIsImmediateAndIndependentOfMissingAudioAndOtherSwitches() {
        let rig = HapticTestRig(); rig.enterGame()
        rig.player.apply(settings: .init(sound: false, haptic: true, voice: false, music: false))
        rig.player.play(.mark)
        rig.player.apply(settings: .init(sound: true, haptic: false, voice: true, music: true))
        let preparationsBeforeMutedInput = rig.driver.preparations.count
        rig.player.beginSwipe(); rig.player.playMarks(count: 10)
        rig.player.play(.correct); rig.player.play(.wrong); rig.player.play(.win)
        XCTAssertEqual(rig.driver.preparations.count, preparationsBeforeMutedInput)
        rig.player.apply(settings: .init(sound: false, haptic: true, voice: false, music: false))
        XCTAssertEqual(rig.driver.emissions, [.selection], "Re-enabling cannot replay muted actions")
        rig.player.play(.erase)
        XCTAssertEqual(rig.driver.emissions, [.selection, .selection], "Re-enabling starts a fresh light-feedback window")
        XCTAssertTrue(rig.audioSessionChanges.isEmpty, "Haptics work with an unverified empty audio manifest and no audio session")
    }

    @MainActor func testEveryInputBlockSuppressesFeedbackAndClearsTheOldLightWindow() {
        for block in FeedbackAudioBlock.allCases {
            let rig = HapticTestRig(); rig.enterGame(); rig.player.play(.mark)
            rig.player.setBlocked(block, active: true)
            let preparationsBeforeBlockedInput = rig.driver.preparations.count
            rig.player.beginSwipe(); rig.player.playMarks(count: 5)
            for event in [FeedbackEvent.mark, .erase, .correct, .wrong, .win, .combo(3)] { rig.player.play(event) }
            XCTAssertEqual(rig.driver.emissions, [.selection], "\(block)")
            XCTAssertEqual(rig.driver.preparations.count, preparationsBeforeBlockedInput, "\(block)")
            rig.player.setBlocked(block, active: false)
            XCTAssertEqual(rig.driver.emissions, [.selection], "Unblocking does not replay an old event")
            rig.player.play(.erase)
            XCTAssertEqual(rig.driver.emissions, [.selection, .selection], "\(block)")
        }
    }

    @MainActor func testEndingAdvertisementWhileStillBackgroundedCannotResumeHaptics() {
        let rig = HapticTestRig(); rig.enterGame()
        rig.player.setBlocked(.advertisement, active: true)
        rig.player.setBlocked(.background, active: true)
        rig.player.setBlocked(.advertisement, active: false)
        let accepted = FeedbackEnvironment(page: .game, level: 1)
        rig.player.play(.correct, acceptedIn: accepted); rig.player.playMarks(count: 3)
        XCTAssertTrue(rig.driver.emissions.isEmpty)
        rig.player.setBlocked(.background, active: false)
        XCTAssertTrue(rig.driver.emissions.isEmpty)
        rig.player.play(.correct)
        XCTAssertEqual(rig.driver.emissions, [.correct])
    }

    @MainActor func testGameFeedbackDoesNotLeakIntoPagesOrNoninteractiveOverlays() {
        let rig = HapticTestRig()
        for page in [FeedbackAudioPage.startup, .home, .settings, .checkIn] {
            rig.player.setContext(page: page)
            rig.player.play(.correct); rig.player.playMarks(count: 3)
        }
        for overlay in [FeedbackAudioOverlay.settings, .debug, .hint, .won, .lost, .challenge, .loading, .notice, .error] {
            rig.player.setContext(page: .game, level: 1, overlay: overlay)
            rig.player.play(.correct); rig.player.play(.wrong); rig.player.playMarks(count: 3)
        }
        XCTAssertTrue(rig.driver.emissions.isEmpty)
        rig.player.setContext(page: .game, level: 1, overlay: .tutorial)
        rig.player.play(.mark)
        XCTAssertEqual(rig.driver.emissions, [.selection])
    }

    @MainActor func testCommittedRevealCanFinishOnSameBoardButCannotBypassPauseOrCrossBoards() {
        let rig = HapticTestRig(); rig.enterGame()
        let accepted = FeedbackEnvironment(page: .game, level: 1)
        rig.player.setEnvironment(FeedbackEnvironment(page: .game, level: 1, overlay: .won, blocks: [.inputLocked]))
        rig.player.play(.correct); rig.player.play(.mark, acceptedIn: accepted)
        XCTAssertTrue(rig.driver.emissions.isEmpty)
        rig.player.play(.correct, acceptedIn: accepted)
        XCTAssertEqual(rig.driver.emissions, [.correct])
        for block in [FeedbackAudioBlock.paused, .advertisement, .background] {
            rig.player.setBlocked(block, active: true)
            rig.player.play(.correct, acceptedIn: accepted)
            rig.player.setBlocked(block, active: false)
        }
        rig.enterGame(level: 2); rig.player.play(.correct, acceptedIn: accepted)
        rig.player.setContext(page: .home); rig.player.play(.correct, acceptedIn: accepted)
        XCTAssertEqual(rig.driver.emissions, [.correct])
    }

    @MainActor func testInterruptionDropsFeedbackUntilEndedThenAllowsNewActions() {
        let rig = HapticTestRig(); rig.enterGame(); rig.player.play(.mark)
        rig.player.handleInterruption(began: true, shouldResume: false)
        rig.player.play(.wrong); rig.player.playMarks(count: 3)
        rig.player.handleInterruption(began: false, shouldResume: false)
        rig.player.play(.correct)
        XCTAssertEqual(rig.driver.emissions, [.selection, .correct])
        rig.player.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(rig.driver.emissions, [.selection, .correct])
        rig.player.play(.erase)
        XCTAssertEqual(rig.driver.emissions, [.selection, .correct, .selection])
    }

    @MainActor func testHardwareIsPreparedOnlyForPlayableInputAndButtonsKeepTheirExistingPolicy() {
        let rig = HapticTestRig()
        _ = rig.player
        XCTAssertTrue(rig.driver.preparations.isEmpty)
        rig.enterGame()
        XCTAssertTrue(rig.driver.preparations.contains(.selection))
        XCTAssertTrue(rig.driver.preparations.contains(.correct))
        XCTAssertTrue(rig.driver.preparations.contains(.error))
        rig.player.play(.correct)
        XCTAssertEqual(rig.driver.preparations.last, .correct, "Prepare the retained generator again after firing")
        rig.player.play(.tap); rig.player.playButton(id: "generic"); rig.player.playButton(id: "unknown", enabled: false)
        XCTAssertEqual(rig.driver.emissions, [.correct], "Do not invent haptics for undefined buttons")
    }
}
