import XCTest
import CapydokuCore
@testable import Capydoku

@MainActor
private final class AcceptedMoveAudioClock {
    final class Job {
        let deadline: TimeInterval
        let action: () -> Void
        var cancelled = false

        init(deadline: TimeInterval, action: @escaping () -> Void) {
            self.deadline = deadline
            self.action = action
        }
    }

    var now: TimeInterval = 0
    private var jobs: [Job] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> AudioScheduledTask {
        let job = Job(deadline: now + delay, action: action)
        jobs.append(job)
        return AudioScheduledTask { job.cancelled = true }
    }

    func advance(_ duration: TimeInterval) {
        let destination = now + duration
        while let index = jobs.indices.filter({ jobs[$0].deadline <= destination })
            .min(by: { jobs[$0].deadline < jobs[$1].deadline }) {
            let job = jobs.remove(at: index)
            now = job.deadline
            if !job.cancelled { job.action() }
        }
        now = destination
    }
}

/// Records the production adapter's play() calls without emitting device audio.
@MainActor
private final class AcceptedMoveAudioHandle: AudioPlaybackHandle {
    var isPlaying = false
    var duration: TimeInterval = 10
    var currentTime: TimeInterval = 0
    var volume: Float = 1
    var numberOfLoops = 0
    let onPlay: () -> Void

    init(onPlay: @escaping () -> Void) { self.onPlay = onPlay }
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { isPlaying = true; onPlay(); return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func setVolume(_ volume: Float, fadeDuration: TimeInterval) { self.volume = volume }
}

@MainActor
private final class AcceptedMoveAudioRig {
    struct Cue {
        let file: String
        let time: TimeInterval
    }

    let clock = AcceptedMoveAudioClock()
    private(set) var cues: [Cue] = []

    func player(imported: LocalTestAudioImport) -> FeedbackPlayer {
        // Omit manifest so the production initializer selects the authorized
        // Debug-only import. Never relabel the unverified policy as verified.
        FeedbackPlayer(resourceResolver: imported.resource,
            playerFactory: { [unowned self] url in
                AcceptedMoveAudioHandle { [unowned self] in
                    cues.append(Cue(file: url.lastPathComponent, time: clock.now))
                }
            }, scheduler: clock.schedule, clock: { [unowned self] in clock.now },
            sessionControl: { _ in true }, observeSystem: false)
    }

    func playTimes(for clip: AudioClipPolicy) -> [TimeInterval] {
        cues.filter { $0.file == clip.file }.map(\.time)
    }
}

final class AcceptedMoveAudioTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (AppModel, AcceptedMoveAudioRig, LocalTestAudioImport) {
        guard let imported = LocalTestAudioImport.load() else {
            throw XCTSkip("Requires the authorized local Debug audio experiment; clean clones and distribution builds intentionally omit it")
        }
        XCTAssertFalse(imported.manifest.referenceVerified)
        let rig = AcceptedMoveAudioRig()
        let player = rig.player(imported: imported)
        XCTAssertTrue(player.usesLocalTestAudio)
        XCTAssertTrue(player.validationErrors.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("accepted-move-audio-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(saveDirectory: directory, runsTimer: false,
                           feedbackEnabled: true, feedbackPlayer: player)
        app.progress.tutorialCompleted = true
        app.progress.settings.soundEnabled = true
        app.progress.settings.musicEnabled = false
        app.progress.settings.voiceEnabled = false
        app.progress.settings.hapticsEnabled = false
        app.settingsChanged()
        app.start(level: 1)
        rig.clock.advance(0)
        XCTAssertNil(app.errorMessage)
        XCTAssertEqual(app.session?.status, .playing)
        XCTAssertTrue(app.currentAudioEnvironment.blocks.isEmpty)
        XCTAssertTrue(rig.cues.isEmpty)
        return (app, rig, imported)
    }

    @MainActor
    func testTwoAcceptedWrongCellsWithin100msEachPlayTheirFailureCue() throws {
        let (app, rig, imported) = try fixture()
        let clip = try XCTUnwrap(imported.manifest.clips["double_tap_wrong"])
        XCTAssertEqual(clip.group, .sound)
        let initial = try XCTUnwrap(app.session)
        let wrong = Array(initial.puzzle.regions.indices.filter { !initial.puzzle.solution.contains($0) }.prefix(2))
        XCTAssertEqual(wrong.count, 2)
        guard wrong.count == 2 else { return }
        XCTAssertGreaterThanOrEqual(initial.lives, 3)

        app.submit(wrong[0])
        rig.clock.advance(0)
        XCTAssertEqual(app.session?.lives, initial.lives - 1)
        XCTAssertEqual(rig.playTimes(for: clip), [0])
        rig.clock.advance(0.1)
        app.submit(wrong[1])
        rig.clock.advance(0)

        XCTAssertEqual(app.session?.lives, initial.lives - 2)
        XCTAssertEqual(app.session?.errors, Set(wrong))
        XCTAssertEqual(app.session?.combo, 0)
        XCTAssertEqual(app.session?.status, .playing)
        // Original [336]: each actual life loss has one failure cue.
        XCTAssertEqual(rig.playTimes(for: clip), [0, 0.1], "Two accepted life losses must each reach the playback adapter")
        rig.clock.advance(1)
        XCTAssertEqual(rig.playTimes(for: clip).count, 2, "No delayed duplicate may compensate for a missing immediate cue")
    }

    @MainActor
    func testDuplicateSubmissionOfSameWrongCellDoesNotLoseAnotherLifeOrReplay() throws {
        let (app, rig, imported) = try fixture()
        let clip = try XCTUnwrap(imported.manifest.clips["double_tap_wrong"])
        let initial = try XCTUnwrap(app.session)
        let wrong = try XCTUnwrap(initial.puzzle.regions.indices.first { !initial.puzzle.solution.contains($0) })

        // Both submissions occur in one synchronous main-actor turn, within
        // AppModel's real 280ms duplicate-delivery guard; no input clock is faked.
        app.submit(wrong)
        app.submit(wrong)
        rig.clock.advance(0)
        XCTAssertEqual(app.session?.lives, initial.lives - 1)
        XCTAssertEqual(app.session?.errors, Set([wrong]))
        XCTAssertEqual(rig.playTimes(for: clip), [0])
        rig.clock.advance(1)
        XCTAssertEqual(rig.playTimes(for: clip), [0])
    }

    @MainActor
    func testTwoAcceptedCorrectCellsWithin100msEachPlayTheirCorrectCue() throws {
        let (app, rig, imported) = try fixture()
        let clip = try XCTUnwrap(imported.manifest.clips["double_tap_correct"])
        XCTAssertEqual(clip.group, .sound)
        let initial = try XCTUnwrap(app.session)
        let solution = initial.puzzle.solution
        XCTAssertGreaterThan(solution.count, 2)
        guard solution.count > 2 else { return }

        app.submit(solution[0])
        rig.clock.advance(0)
        let firstScore = try XCTUnwrap(app.session?.score)
        XCTAssertGreaterThan(firstScore, initial.score)
        XCTAssertEqual(rig.playTimes(for: clip), [0])
        rig.clock.advance(0.1)
        app.submit(solution[1])
        rig.clock.advance(0)

        XCTAssertEqual(app.session?.found, Set(solution.prefix(2)))
        XCTAssertEqual(app.session?.combo, 2)
        XCTAssertEqual(app.session?.lives, initial.lives)
        XCTAssertGreaterThan(try XCTUnwrap(app.session?.score), firstScore)
        XCTAssertEqual(app.session?.status, .playing)
        // Original [335]: each correct find immediately plays one cue.
        XCTAssertEqual(rig.playTimes(for: clip), [0, 0.1], "Both committed finds must produce their own immediate correct cue")
        rig.clock.advance(1)
        XCTAssertEqual(rig.playTimes(for: clip).count, 2)
    }
}
