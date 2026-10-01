import XCTest
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class FeedbackBoardRig {
    let model: AppModel
    let board = PuzzleGridUIView(frame: CGRect(x: 20, y: 180, width: 340, height: 340))
    let window: UIWindow
    let previousWindow: UIWindow?
    let directory: URL
    var effectsEnabled = true

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("visual-feedback-" + UUID().uuidString)
        model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true; model.start(level: 1)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.addSubview(board)
        refresh(); board.layoutIfNeeded()
    }

    func refresh(_ target: PuzzleGridUIView? = nil) {
        guard let s = model.session else { return }
        (target ?? board).configure(size: s.puzzle.size, regions: s.puzzle.regions, found: s.found,
            marks: s.marks, errors: s.errors, preview: [], sessionID: s.id, lives: s.lives,
            effectsEnabled: effectsEnabled, tutorialTargets: [], locked: s.status != .playing,
            onToggle: { [weak self] in self?.model.toggle($0); self?.refresh() },
            onSubmit: { [weak self] in self?.model.submit($0); self?.refresh() }, onMark: { _ in })
    }

    var mistakes: [BoardMistakeFeedbackView] { board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardMistakeFeedbackView } }
    func close() {
        window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible()
        try? FileManager.default.removeItem(at: directory)
    }
}

final class GameVisualFeedbackTests: XCTestCase {
    @MainActor private func capture(_ view: UIView, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            (view.layer.presentation() ?? view.layer).render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testRepeatedWrongRedCellAnimatesEachActualDeductionButNotDuplicateDelivery() async throws {
        let rig = try FeedbackBoardRig(); defer { rig.close() }
        let puzzle = try XCTUnwrap(rig.model.session).puzzle
        let wrong = try XCTUnwrap(puzzle.regions.indices.first { !puzzle.solution.contains($0) })
        XCTAssertTrue(rig.board.activate(index: wrong, submit: true))
        let first = try XCTUnwrap(rig.mistakes.first)
        XCTAssertEqual(rig.model.session?.lives, 2)
        XCTAssertFalse(first.isUserInteractionEnabled)
        XCTAssertTrue(first.accessibilityElementsHidden)
        rig.board.activate(index: wrong, submit: true)
        XCTAssertEqual(rig.model.session?.lives, 2)
        XCTAssertTrue(rig.mistakes.first === first, "An ignored duplicate must not restart a transient animation.")
        try await Task.sleep(nanoseconds: 310_000_000)
        rig.board.activate(index: wrong, submit: true)
        let second = try XCTUnwrap(rig.mistakes.first)
        XCTAssertFalse(second === first)
        XCTAssertNil(first.superview)
        XCTAssertEqual(rig.mistakes.count, 1)
        XCTAssertEqual(rig.model.session?.lives, 1)
        XCTAssertEqual(rig.model.session?.errors, [wrong])
        for (delay, name) in [(100_000_000, "mistake-01-head-shake"), (270_000_000, "mistake-02-heart-tearing"),
                              (250_000_000, "mistake-03-red-x-transition"), (230_000_000, "mistake-04-settled-red-x")] {
            try await Task.sleep(nanoseconds: UInt64(delay))
            capture(rig.window, name)
        }
        XCTAssertTrue(rig.mistakes.isEmpty)
        XCTAssertEqual(rig.model.session?.lives, 1, "Finishing an effect cannot change the game.")
    }

    @MainActor func testUndoRestartRestoreAndSuspensionRemoveStaleEffectsWithoutReplayingDamage() async throws {
        let rig = try FeedbackBoardRig(); defer { rig.close() }
        let puzzle = try XCTUnwrap(rig.model.session).puzzle
        let wrong = try XCTUnwrap(puzzle.regions.indices.first { !puzzle.solution.contains($0) })
        rig.board.activate(index: wrong, submit: true)
        XCTAssertEqual(rig.mistakes.count, 1)
        let restoredBoard = PuzzleGridUIView(frame: rig.board.frame)
        rig.window.rootViewController?.view.addSubview(restoredBoard)
        rig.refresh(restoredBoard)
        XCTAssertTrue(restoredBoard.subviews.flatMap(\.subviews).isEmpty, "Initial saved errors are state, not new wrong actions.")
        restoredBoard.removeFromSuperview()
        rig.board.activate(index: wrong, submit: false)
        XCTAssertTrue(rig.mistakes.isEmpty)
        XCTAssertEqual(rig.model.session?.lives, 2)
        XCTAssertFalse(rig.model.session?.errors.contains(wrong) ?? true)
        rig.model.restart(); rig.refresh()
        rig.board.activate(index: wrong, submit: true)
        XCTAssertEqual(rig.mistakes.count, 1)
        let old = try XCTUnwrap(rig.mistakes.first)
        let previousSession = rig.model.session?.id
        // Distinct restart actions, beyond the button's duplicate-delivery guard.
        try await Task.sleep(nanoseconds: 420_000_000)
        rig.model.restart(); rig.refresh()
        XCTAssertNotEqual(rig.model.session?.id, previousSession)
        XCTAssertNil(old.superview)
        XCTAssertTrue(rig.mistakes.isEmpty, "Restarting the same board must clear the previous attempt's effects.")
        rig.board.activate(index: wrong, submit: true)
        XCTAssertEqual(rig.mistakes.count, 1)
        rig.effectsEnabled = false; rig.refresh()
        XCTAssertTrue(rig.mistakes.isEmpty)
        rig.effectsEnabled = true; rig.refresh()
        XCTAssertTrue(rig.mistakes.isEmpty, "Returning from a modal or the background must not replay saved damage.")
        rig.board.activate(index: puzzle.solution[0], submit: true)
        XCTAssertEqual(rig.model.session?.found.count, 1)
        rig.board.removeFromSuperview()
        XCTAssertTrue(rig.board.subviews.flatMap(\.subviews).isEmpty, "Navigation cancels particles as well as wrong feedback.")
    }

    @MainActor func testReducedMotionShowsStaticSplitHeartThenXAndReleasesOverlay() async throws {
        let rig = try FeedbackBoardRig(); defer { rig.close() }
        let cell = try XCTUnwrap(rig.board.accessibilityElements?.first as? UIAccessibilityElement)
        let cellFrame = rig.board.convert(cell.accessibilityFrameInContainerSpace, to: rig.window.rootViewController?.view).insetBy(dx: 2, dy: 2)
        let effect = BoardMistakeFeedbackView(cellIndex: 0, frame: cellFrame,
                                             tileColor: UIColor(CapyPalette.regionColors[0]), reduceMotion: true)
        rig.window.rootViewController?.view.addSubview(effect); effect.play()
        func animations(_ layer: CALayer) -> [String] { (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(animations) }
        XCTAssertTrue(animations(effect.layer).isEmpty, "Reduce Motion must not include hidden scale, translation or rotation animations.")
        capture(rig.window, "mistake-reduce-motion-split-heart")
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(animations(effect.layer).isEmpty)
        capture(rig.window, "mistake-reduce-motion-red-x")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(effect.superview)
        XCTAssertEqual(rig.model.session?.lives, 3)
    }
}

@MainActor private final class PresentationClock {
    var now: Double = 0
    var jobs: [(at: Double, action: () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ operation: @escaping () -> Void) { jobs.append((now + delay, operation)) }
    func advance(_ amount: Double) {
        let end = now + amount
        while let index = jobs.indices.filter({ jobs[$0].at <= end }).min(by: { jobs[$0].at < jobs[$1].at }) {
            let job = jobs.remove(at: index); now = job.at; job.action()
        }
        now = end
    }
}

final class GameFeedbackPresentationTests: XCTestCase {
    @MainActor func testBackgroundOrAlertBlocksNewArrivalsAsWellAsAlreadyScheduledText() {
        let clock = PresentationClock()
        let presentation = GameFeedbackPresentation(schedule: clock.schedule)
        presentation.bindLives(3)
        presentation.combo(.init(text: "Nice", delay: 0.25))
        presentation.life(1)
        presentation.setPresentationEnabled(false)
        XCTAssertFalse(presentation.showLastLife)
        // A committed ad may update the session while the app is backgrounded.
        presentation.combo(.init(text: "Great", delay: 0.5))
        presentation.life(1)
        presentation.setPresentationEnabled(true)
        clock.advance(2)
        XCTAssertNil(presentation.comboText)
        XCTAssertFalse(presentation.showLastLife)
        presentation.combo(.init(text: "Excellent", delay: 0))
        XCTAssertEqual(presentation.comboText, "Excellent", "A new visible action still shows feedback after returning.")
    }

    @MainActor func testConfiguredDelayControlsTextAndNewCueCannotBeClearedByOldExpiry() {
        let clock = PresentationClock()
        let current = GameFeedbackPresentation(schedule: clock.schedule)
        current.combo(.init(text: "Nice", delay: 0.25))
        XCTAssertNil(current.comboText); clock.advance(0.24); XCTAssertNil(current.comboText)
        clock.advance(0.01); XCTAssertEqual(current.comboText, "Nice")
        clock.advance(1)
        current.combo(.init(text: "Great", delay: 0))
        clock.advance(0.31)
        XCTAssertEqual(current.comboText, "Great", "The older Nice timeout must not hide Great.")
        clock.advance(1); XCTAssertNil(current.comboText)
    }

    @MainActor func testResetOrMissingMappedCountCancelsScheduledText() {
        let clock = PresentationClock()
        let current = GameFeedbackPresentation(schedule: clock.schedule)
        for reset in [false, true] {
            current.combo(.init(text: "Excellent", delay: 0.5))
            if reset { current.clear() } else { current.combo(nil) }
            clock.advance(2)
            XCTAssertNil(current.comboText)
        }
    }

    @MainActor func testRevivalAndNewWarningCannotBeOverwrittenByPreviousLifeTimeout() {
        let clock = PresentationClock()
        let presentation = GameFeedbackPresentation(schedule: clock.schedule)
        presentation.bindLives(3)
        presentation.life(1); clock.advance(1)
        XCTAssertFalse(presentation.showLastLife)
        presentation.life(3); XCTAssertFalse(presentation.showLastLife)
        presentation.life(1); clock.advance(0.9)
        XCTAssertFalse(presentation.showLastLife, "The previous loss must not show the replacement warning early.")
        clock.advance(0.46)
        XCTAssertTrue(presentation.showLastLife)
        presentation.clear(); clock.advance(1)
        XCTAssertFalse(presentation.showLastLife)
    }

    @MainActor func testLastLifeWaitsForExplanationAndDuplicateObservationDoesNotRestartIt() {
        let clock = PresentationClock(), presentation = GameFeedbackPresentation(schedule: clock.schedule)
        presentation.bindLives(2); presentation.life(1)
        clock.advance(1); presentation.life(1)
        clock.advance(0.34); XCTAssertFalse(presentation.showLastLife)
        clock.advance(0.02); XCTAssertTrue(presentation.showLastLife)
        clock.advance(20); XCTAssertTrue(presentation.showLastLife)
    }

    @MainActor func testPendingLastLifeCannotSurviveNewActionCoverResetOrChangedScope() {
        for interruption in 0..<6 {
            let clock = PresentationClock(), presentation = GameFeedbackPresentation(schedule: clock.schedule)
            var current = true
            presentation.bindLives(2); presentation.life(1, isStillCurrent: { current })
            clock.advance(0.3)
            switch interruption {
            case 0: presentation.cancelPendingLastLife()
            case 1: presentation.dismissLastLife()
            case 2: presentation.setPresentationEnabled(false); presentation.setPresentationEnabled(true)
            case 3: presentation.clear(); presentation.bindLives(1)
            case 4: presentation.life(0); presentation.life(1)
            default: current = false
            }
            clock.advance(20)
            XCTAssertFalse(presentation.showLastLife, "Interruption \(interruption) must invalidate the old reminder.")
        }
    }

    @MainActor func testRestoringOneLifeAndRevivingToOneLifeAreNotNewMistakes() {
        let clock = PresentationClock(), presentation = GameFeedbackPresentation(schedule: clock.schedule)
        presentation.bindLives(1); presentation.life(1); clock.advance(2)
        XCTAssertFalse(presentation.showLastLife)
        presentation.life(0); presentation.life(1); clock.advance(2)
        XCTAssertFalse(presentation.showLastLife)
    }
}
