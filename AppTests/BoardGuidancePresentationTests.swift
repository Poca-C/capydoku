import XCTest
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class GuidanceRig {
    static let puzzle = Puzzle(id: 1, size: 4,
        regions: [0, 0, 1, 1, 0, 0, 0, 1, 2, 3, 0, 1, 3, 3, 3, 1],
        solution: [1, 7, 8, 14], seed: 11400714819323198485,
        generatorVersion: "original-pipeline-v3", difficulty: "easy")
    var session: GameSession
    let board = PuzzleGridUIView(frame: CGRect(x: 20, y: 150, width: 320, height: 320))
    let window: UIWindow
    private let previousWindow: UIWindow?
    var targets = Set<Int>()
    var action: String?
    var locked = false
    var hidden = false
    var preview = Set<Int>()
    var reduceMotion = false
    var effectsEnabled = true
    var callbacks = [[VisibleConflictKind]]()
    var scores = [(Int, CGPoint)]()

    init(session: GameSession? = nil, idleBlinkScheduler: ((TimeInterval, DispatchWorkItem) -> Void)? = nil) throws {
        self.session = session ?? GameSession(puzzle: Self.puzzle)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = controller; window.makeKeyAndVisible()
        if let idleBlinkScheduler { board.idleBlinkScheduler = idleBlinkScheduler }
        controller.view.addSubview(board); refresh(); board.layoutIfNeeded()
    }

    func refresh() {
        board.configure(size: session.puzzle.size, regions: session.puzzle.regions,
            found: session.found, marks: session.marks, errors: session.errors, preview: preview,
            sessionID: session.id, lives: session.lives, score: session.score, effectsEnabled: effectsEnabled,
            reduceMotion: reduceMotion, tutorialTargets: targets, tutorialAction: action,
            locked: locked, hideAccessibility: hidden,
            onToggle: { [weak self] index in
                guard let self else { return }; session.toggleMark(at: index); refresh()
            }, onSubmit: { [weak self] index in
                guard let self else { return }; _ = session.submit(cell: index); refresh()
            }, onMark: { [weak self] cells in
                guard let self else { return }; session.markMany(cells); refresh()
            }, onConflictFeedback: { [weak self] kinds in self?.callbacks.append(kinds) },
            onScoreFeedback: { [weak self] delta, point in self?.scores.append((delta, point)) })
    }
    var guides: [BoardTutorialGuideView] { board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardTutorialGuideView } }
    var conflicts: [BoardConflictFeedbackView] { board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardConflictFeedbackView } }
    var blinks: [CapyFaceExpressionView] {
        board.subviews.flatMap(\.subviews).compactMap { $0 as? CapyFaceExpressionView }.filter { $0.expression == .blink }
    }
    var looks: [CapyIdleGazeView] {
        board.subviews.flatMap(\.subviews).compactMap { $0 as? CapyIdleGazeView }
    }
    func center(_ index: Int) throws -> CGPoint {
        let element = try XCTUnwrap(board.accessibilityElements?[index] as? UIAccessibilityElement)
        return CGPoint(x: element.accessibilityFrameInContainerSpace.midX, y: element.accessibilityFrameInContainerSpace.midY)
    }
    func close() {
        board.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
        previousWindow?.makeKeyAndVisible()
    }
}

@MainActor private final class BlinkTestSchedule {
    var jobs = [(TimeInterval, DispatchWorkItem)]()
    var pending: [(TimeInterval, DispatchWorkItem)] { jobs.filter { !$0.1.isCancelled } }
    func schedule(_ delay: TimeInterval, _ work: DispatchWorkItem) { jobs.append((delay, work)) }
    func fireNext() throws {
        let index = try XCTUnwrap(jobs.firstIndex { !$0.1.isCancelled })
        let work = jobs.remove(at: index).1; work.perform()
    }
}

final class BoardGuidancePresentationTests: XCTestCase {
    @MainActor private func animations(_ layer: CALayer) -> [CAAnimation] {
        (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
            + (layer.sublayers ?? []).flatMap(animations)
    }
    @MainActor private func capture(_ view: UIView, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image {
            (view.layer.presentation() ?? view.layer).render(in: $0.cgContext)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testOnlyVisibleAnimalsExplainActualMistakesAndRedrawNeverRepeatsCallback() throws {
        let rig = try GuidanceRig(); defer { rig.close() }
        rig.board.activate(index: 0, submit: true)
        XCTAssertEqual(rig.session.lives, 2)
        XCTAssertTrue(rig.conflicts.isEmpty); XCTAssertEqual(rig.callbacks, [[]],
            "The hidden solution cannot explain an error against an undiscovered animal")
        rig.board.activate(index: 1, submit: true)
        rig.board.activate(index: 0, submit: true)
        let effect = try XCTUnwrap(rig.conflicts.first)
        XCTAssertEqual(effect.candidate, 0); XCTAssertEqual(effect.conflicts.map(\.otherCell), [1])
        XCTAssertEqual(Set(rig.callbacks.last ?? []), [.region, .row, .adjacent])
        XCTAssertEqual(effect.highlightedCells, [0, 1, 2, 3, 4, 5, 6, 10])
        XCTAssertEqual(rig.session.lives, 1)
        rig.refresh(); rig.board.setNeedsDisplay(); rig.board.layoutIfNeeded()
        XCTAssertEqual(rig.callbacks.count, 2)
        XCTAssertTrue(rig.board.hitTest(try rig.center(0), with: nil) === rig.board)
        XCTAssertFalse(effect.isUserInteractionEnabled); XCTAssertTrue(effect.accessibilityElementsHidden)
        XCTAssertEqual(rig.board.gestureRecognizers?.count, 3)
    }

    @MainActor func testConflictDoesNotReplayOnRestoreAndClearsForBlockingChanges() throws {
        var saved = GameSession(puzzle: GuidanceRig.puzzle)
        _ = saved.submit(cell: 1); _ = saved.submit(cell: 0)
        let rig = try GuidanceRig(session: saved); defer { rig.close() }
        XCTAssertTrue(rig.conflicts.isEmpty); XCTAssertTrue(rig.callbacks.isEmpty)
        rig.board.activate(index: 0, submit: true)
        let old = try XCTUnwrap(rig.conflicts.first)
        rig.hidden = true; rig.refresh()
        XCTAssertTrue(rig.conflicts.isEmpty); XCTAssertTrue(animations(old.layer).isEmpty)
        rig.hidden = false; rig.refresh()
        XCTAssertTrue(rig.conflicts.isEmpty)
        rig.session = GameSession(puzzle: GuidanceRig.puzzle); rig.refresh()
        XCTAssertTrue(rig.conflicts.isEmpty); XCTAssertEqual(rig.callbacks.count, 1)
    }

    @MainActor func testUndoingAnErrorImmediatelyClearsItsConflictPartnersAndRuleEmphasis() throws {
        let rig = try GuidanceRig(); defer { rig.close() }
        rig.board.activate(index: 1, submit: true)
        rig.board.activate(index: 0, submit: true)
        let explanation = try XCTUnwrap(rig.conflicts.first)
        let reactions = rig.board.subviews.flatMap(\.subviews).compactMap { $0 as? CapyFaceExpressionView }
            .filter { $0.expression == .startled }
        XCTAssertEqual(reactions.map(\.cellIndex), [1])
        XCTAssertFalse(try XCTUnwrap(rig.callbacks.last).isEmpty)
        let count = rig.callbacks.count, lives = rig.session.lives
        rig.board.activate(index: 0, submit: false)
        XCTAssertFalse(rig.session.errors.contains(0)); XCTAssertEqual(rig.session.lives, lives)
        XCTAssertTrue(rig.conflicts.isEmpty); XCTAssertNil(explanation.superview)
        XCTAssertTrue(animations(explanation.layer).isEmpty); XCTAssertTrue(reactions.allSatisfy { $0.superview == nil })
        XCTAssertEqual(rig.callbacks.count, count + 1); XCTAssertEqual(rig.callbacks.last, [])
        rig.refresh(); XCTAssertEqual(rig.callbacks.count, count + 1)
    }

    @MainActor func testRenderedMistakeYieldsToTheNextCorrectMoveWithoutLosingItsReward() async throws {
        let rig = try GuidanceRig(); defer { rig.close() }
        rig.board.activate(index: 1, submit: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        rig.board.activate(index: 0, submit: true)
        // Let the wrong action reach the display before the next submission.
        // This is distinct from correct/wrong moves coalesced into one update.
        try await Task.sleep(nanoseconds: 120_000_000)
        let explanation = try XCTUnwrap(rig.conflicts.first)
        let oldReactions = rig.board.subviews.flatMap(\.subviews).compactMap { $0 as? CapyFaceExpressionView }
            .filter { $0.expression == .startled }
        XCTAssertEqual(explanation.candidate, 0)
        XCTAssertEqual(oldReactions.map(\.cellIndex), [1])
        XCTAssertEqual(Set(try XCTUnwrap(rig.callbacks.last)), [.region, .row, .adjacent])
        capture(rig.window, "sequential-feedback-rendered-mistake")
        let callbacksBeforeCorrect = rig.callbacks.count
        let scoreBeforeCorrect = rig.session.score

        rig.board.activate(index: 7, submit: true)
        try await Task.sleep(nanoseconds: 90_000_000)
        let effects = rig.board.subviews.flatMap(\.subviews)
        capture(rig.window, "sequential-feedback-new-correct")
        XCTAssertEqual(rig.session.found, [1, 7])
        XCTAssertEqual(rig.session.errors, [0], "The saved red X remains; only its old explanation retires.")
        XCTAssertEqual(rig.session.lives, 2)
        XCTAssertGreaterThan(rig.session.score, scoreBeforeCorrect)
        XCTAssertTrue(effects.contains { ($0 as? BoardCellFeedbackView)?.cellIndex == 7 && ($0 as? BoardCellFeedbackView)?.kind == .found })
        XCTAssertTrue(effects.contains { ($0 as? BoardPlacementBurstView)?.cellIndex == 7 }, "The new correct response must still play.")
        XCTAssertTrue(rig.conflicts.isEmpty, "A later accepted correct move owns the transient explanation.")
        XCTAssertNil(explanation.superview)
        XCTAssertTrue(oldReactions.allSatisfy { $0.superview == nil }, "The old conflict partners must stop looking startled.")
        XCTAssertFalse(effects.contains { $0 is BoardMistakeFeedbackView }, "The previous wrong placement cannot compete with the new reward.")
        XCTAssertEqual(rig.callbacks.count, callbacksBeforeCorrect + 1)
        XCTAssertEqual(rig.callbacks.last, [], "The board must also retire the old rule-strip emphasis.")
        rig.refresh()
        XCTAssertEqual(rig.callbacks.count, callbacksBeforeCorrect + 1, "A refresh cannot publish another clear event.")
    }

    @MainActor func testAnOrdinaryMarkPreservesTheMistakeAndANewWrongMoveReplacesItsExplanation() throws {
        let rig = try GuidanceRig(); defer { rig.close() }
        rig.board.activate(index: 1, submit: true)
        rig.board.activate(index: 0, submit: true)
        let first = try XCTUnwrap(rig.conflicts.first)
        let firstCallbacks = rig.callbacks
        let score = rig.session.score
        rig.board.activate(index: 5, submit: false)
        XCTAssertEqual(rig.session.marks, [0, 5])
        XCTAssertEqual(rig.session.errors, [0]); XCTAssertEqual(rig.session.lives, 2)
        XCTAssertTrue(rig.conflicts.first === first, "An ordinary exclusion is not a newly accepted answer.")
        XCTAssertEqual(rig.callbacks, firstCallbacks, "Marking another cell cannot clear the rule explanation.")

        rig.board.activate(index: 2, submit: true)
        let next = try XCTUnwrap(rig.conflicts.first)
        XCTAssertFalse(next === first); XCTAssertNil(first.superview)
        XCTAssertEqual(next.candidate, 2)
        XCTAssertEqual(next.conflicts.map(\.otherCell), [1])
        XCTAssertEqual(Set(try XCTUnwrap(rig.callbacks.last)), [.row, .adjacent])
        XCTAssertEqual(rig.callbacks.count, firstCallbacks.count + 1)
        XCTAssertEqual(rig.session.found, [1]); XCTAssertEqual(rig.session.errors, [0, 2])
        XCTAssertEqual(rig.session.lives, 1); XCTAssertEqual(rig.session.score, score)
        let effects = rig.board.subviews.flatMap(\.subviews)
        XCTAssertTrue(effects.contains { ($0 as? BoardMistakeFeedbackView)?.cellIndex == 2 })
        XCTAssertTrue(effects.contains { ($0 as? CapyFaceExpressionView)?.expression == .startled })
        XCTAssertFalse(effects.contains { $0 is BoardPlacementBurstView || ($0 as? BoardCellFeedbackView)?.kind == .found })
    }

    @MainActor func testReplacingConflictPartnersCannotLeaveAnOldStartledFaceAfterTheNextCorrectMove() async throws {
        // Component coverage: the Root's one-life spotlight is intentionally
        // absent, so it cannot hide a stale board expression after two errors.
        let rig = try GuidanceRig(); defer { rig.close() }
        func startled() -> [CapyFaceExpressionView] {
            rig.board.subviews.flatMap(\.subviews).compactMap { $0 as? CapyFaceExpressionView }
                .filter { $0.expression == .startled }
        }
        rig.board.activate(index: 1, submit: true)
        rig.board.activate(index: 7, submit: true)
        let firstErrorTime = CACurrentMediaTime()
        rig.board.activate(index: 0, submit: true)
        let first = try XCTUnwrap(rig.conflicts.first)
        let firstFace = try XCTUnwrap(startled().first)
        XCTAssertEqual(first.conflicts.map(\.otherCell), [1]); XCTAssertEqual(firstFace.cellIndex, 1)
        try await Task.sleep(nanoseconds: 40_000_000)

        rig.board.activate(index: 11, submit: true)
        try await Task.sleep(nanoseconds: 40_000_000)
        let second = try XCTUnwrap(rig.conflicts.first)
        XCTAssertEqual(second.candidate, 11); XCTAssertEqual(second.conflicts.map(\.otherCell), [7])
        XCTAssertNil(first.superview)
        XCTAssertEqual(Set(startled().map(\.cellIndex)), [7], "Replacing the explanation must retire participants from its predecessor.")
        capture(rig.window, "sequential-feedback-replaced-conflict-partners")

        rig.board.activate(index: 8, submit: true)
        XCTAssertLessThan(CACurrentMediaTime() - firstErrorTime, firstFace.duration,
                          "This fixture must examine cleanup before natural expression expiry can hide the omission.")
        XCTAssertEqual(rig.session.found, [1, 7, 8]); XCTAssertEqual(rig.session.errors, [0, 11])
        XCTAssertEqual(rig.session.lives, 1); XCTAssertEqual(rig.session.status, .playing)
        XCTAssertTrue(rig.conflicts.isEmpty); XCTAssertNil(second.superview)
        XCTAssertTrue(startled().isEmpty, "A correct move cannot leave a face reacting to an older, replaced conflict.")
        XCTAssertNil(firstFace.superview)
        XCTAssertEqual(rig.callbacks.count, 3); XCTAssertEqual(rig.callbacks.last, [])
        XCTAssertTrue(rig.board.subviews.flatMap(\.subviews).contains { ($0 as? BoardPlacementBurstView)?.cellIndex == 8 })
        capture(rig.window, "sequential-feedback-replaced-conflict-new-correct")
    }

    @MainActor func testDynamicSwipeGuideUsesActualAxisAndChangingTargetsCancelsPreviousAnimation() throws {
        let rig = try GuidanceRig(); defer { rig.close() }
        rig.targets = [8, 9]; rig.action = "swipe"; rig.refresh()
        let horizontal = try XCTUnwrap(rig.guides.first)
        XCTAssertEqual(horizontal.gestureStart, try rig.center(8)); XCTAssertEqual(horizontal.gestureEnd, try rig.center(9))
        XCTAssertFalse(animations(horizontal.layer).isEmpty)
        let before = rig.session
        rig.targets = [2, 6]; rig.refresh()
        let vertical = try XCTUnwrap(rig.guides.first)
        XCTAssertEqual(vertical.gestureStart, try rig.center(2)); XCTAssertEqual(vertical.gestureEnd, try rig.center(6))
        XCTAssertNil(horizontal.superview); XCTAssertTrue(animations(horizontal.layer).isEmpty)
        XCTAssertEqual(rig.session, before)
        XCTAssertTrue(rig.board.hitTest(try rig.center(2), with: nil) === rig.board)
        XCTAssertFalse(rig.board.inputActivity.isBusy)
    }

    @MainActor func testReadGuideRemainsVisibleButLockedAndReducedMotionHasStaticTapAndSwipeMeaning() throws {
        let rig = try GuidanceRig(); defer { rig.close() }
        rig.targets = [1, 5, 9, 13]; rig.action = "read"; rig.locked = true; rig.refresh()
        let read = try XCTUnwrap(rig.guides.first)
        XCTAssertNil(read.gestureStart); XCTAssertTrue(animations(read.layer).isEmpty)
        XCTAssertFalse(rig.board.activate(index: 1, submit: true)); XCTAssertTrue(rig.session.found.isEmpty)
        rig.locked = false; rig.reduceMotion = true; rig.action = "doubleTap"; rig.targets = [8]; rig.refresh()
        let tap = try XCTUnwrap(rig.guides.first)
        XCTAssertEqual(tap.gestureStart, try rig.center(8)); XCTAssertTrue(animations(tap.layer).isEmpty)
        XCTAssertTrue((tap.layer.sublayers ?? []).contains { $0.name == "tutorial-double-tap-static" })
        rig.action = "swipe"; rig.targets = [8, 9]; rig.refresh()
        let swipe = try XCTUnwrap(rig.guides.first)
        XCTAssertTrue(animations(swipe.layer).isEmpty)
        XCTAssertTrue((swipe.layer.sublayers ?? []).contains { $0.name == "tutorial-swipe-direction" })
        rig.reduceMotion = false; rig.effectsEnabled = false; rig.refresh()
        XCTAssertTrue(animations(try XCTUnwrap(rig.guides.first).layer).isEmpty)
    }

    @MainActor func testGuidanceCleanupOnPreviewBackgroundRemovalAndNoOldInputOrMistakeReplay() throws {
        let rig = try GuidanceRig(); defer { rig.close() }
        rig.targets = [1]; rig.action = "doubleTap"; rig.refresh()
        let first = try XCTUnwrap(rig.guides.first)
        rig.preview = [0]; rig.refresh()
        XCTAssertTrue(rig.guides.isEmpty); XCTAssertTrue(animations(first.layer).isEmpty)
        rig.preview = []; rig.refresh(); let second = try XCTUnwrap(rig.guides.first)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(rig.guides.isEmpty); XCTAssertTrue(animations(second.layer).isEmpty)
        _ = rig.session.submit(cell: 1); rig.refresh()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(rig.guides.count, 1); XCTAssertTrue(rig.scores.isEmpty); XCTAssertTrue(rig.callbacks.isEmpty)
        let resumed = try XCTUnwrap(rig.guides.first)
        rig.board.cancelPresentation()
        XCTAssertTrue(rig.guides.isEmpty); XCTAssertTrue(animations(resumed.layer).isEmpty)
        XCTAssertFalse(rig.board.inputActivity.isBusy)
    }

    @MainActor func testSmallCellGuidesClipToBoardAndInvalidOrDiagonalTargetsInventNoSwipe() throws {
        let boardRect = CGRect(x: 7, y: 7, width: 176, height: 176)
        let small = BoardTutorialGuideView(frame: CGRect(x: 0, y: 0, width: 190, height: 190), boardRect: boardRect,
            size: 10, targetCells: [98, 99, -1, 100], action: "swipe", reduceMotion: false)
        XCTAssertEqual(small.targetCells, [98, 99]); XCTAssertNotNil(small.layer.mask)
        XCTAssertTrue(small.targetFrames.allSatisfy { boardRect.contains($0) })
        XCTAssertTrue(boardRect.contains(try XCTUnwrap(small.gestureStart)))
        XCTAssertTrue(boardRect.contains(try XCTUnwrap(small.gestureEnd)))
        let diagonal = BoardTutorialGuideView(frame: small.frame, boardRect: boardRect,
            size: 10, targetCells: [0, 11], action: "swipe", reduceMotion: false)
        diagonal.play(); XCTAssertNil(diagonal.gestureStart); XCTAssertTrue(animations(diagonal.layer).isEmpty)
        capture(small, "tutorial-small-cells-bottom-edge-static-model")
    }

    @MainActor func testSmallCellHandFitsAllFourCornersWithoutMovingTouchTargetsOrSwipePath() throws {
        let board = CGRect(x: 7, y: 7, width: 176, height: 176)
        let frame = CGRect(x: 0, y: 0, width: 190, height: 190)
        for corner in [0, 9, 90, 99] {
            for reduced in [false, true] {
                let guide = BoardTutorialGuideView(frame: frame, boardRect: board, size: 10,
                    targetCells: [corner], action: "doubleTap", reduceMotion: reduced)
                guide.play()
                let hand = try XCTUnwrap(guide.layer.sublayers?.first { $0.name == "tutorial-hand" })
                let ring = try XCTUnwrap(guide.layer.sublayers?.first { $0.name == "tutorial-touch-ring" })
                XCTAssertTrue(board.insetBy(dx: 2, dy: 2).contains(hand.frame), "The complete hand, including edge padding, stays visible")
                XCTAssertEqual(ring.position, guide.gestureStart)
                XCTAssertEqual(ring.position.x, board.minX + (CGFloat(corner % 10) + 0.5) * 17.6, accuracy: 0.0001)
                XCTAssertEqual(ring.position.y, board.minY + (CGFloat(corner / 10) + 0.5) * 17.6, accuracy: 0.0001)
            }
        }
        for cells in [Set([0, 9]), Set([90, 99]), Set([0, 90]), Set([9, 99])] {
            let guide = BoardTutorialGuideView(frame: frame, boardRect: board, size: 10,
                targetCells: cells, action: "swipe", reduceMotion: false)
            guide.play()
            let hand = try XCTUnwrap(guide.layer.sublayers?.first { $0.name == "tutorial-hand" })
            let ring = try XCTUnwrap(guide.layer.sublayers?.first { $0.name == "tutorial-touch-ring" })
            let handMotion = try XCTUnwrap(hand.animation(forKey: "tutorial-swipe") as? CAKeyframeAnimation)
            let ringMotion = try XCTUnwrap(ring.animation(forKey: "tutorial-swipe") as? CAKeyframeAnimation)
            let positions = try XCTUnwrap(handMotion.values as? [NSValue]).map(\.cgPointValue)
            for point in positions {
                let movedFrame = CGRect(x: point.x - hand.bounds.width * hand.anchorPoint.x,
                    y: point.y - hand.bounds.height * hand.anchorPoint.y, width: hand.bounds.width, height: hand.bounds.height)
                XCTAssertTrue(board.insetBy(dx: 2, dy: 2).contains(movedFrame))
            }
            let actual = try XCTUnwrap(ringMotion.values as? [NSValue]).map(\.cgPointValue)
            let start = try XCTUnwrap(guide.gestureStart), end = try XCTUnwrap(guide.gestureEnd)
            XCTAssertEqual(actual, [start, start, end, end], "The real gesture endpoints never shift with the hand artwork")
        }
    }

    @MainActor func testScoreUsesActualCommittedIncreaseOnceAndCoalescedMovesReportOneTotal() throws {
        let rig = try GuidanceRig(); defer { rig.close() }
        let before = rig.session.score
        rig.board.activate(index: 1, submit: true)
        XCTAssertEqual(rig.scores.count, 1); XCTAssertEqual(rig.scores[0].0, rig.session.score - before)
        XCTAssertEqual(rig.scores[0].1, rig.board.convert(try rig.center(1), to: rig.window))
        rig.refresh(); XCTAssertEqual(rig.scores.count, 1)
        let beforeCombined = rig.session.score
        _ = rig.session.submit(cell: 7); _ = rig.session.submit(cell: 8); rig.refresh()
        XCTAssertEqual(rig.scores.count, 2); XCTAssertEqual(rig.scores[1].0, rig.session.score - beforeCombined)
        XCTAssertEqual(rig.scores[1].1, rig.board.convert(try rig.center(8), to: rig.window))
        rig.session = GameSession(puzzle: GuidanceRig.puzzle); rig.refresh()
        XCTAssertEqual(rig.scores.count, 2)
        rig.effectsEnabled = false; _ = rig.session.submit(cell: 1); rig.refresh()
        rig.effectsEnabled = true; rig.refresh(); XCTAssertEqual(rig.scores.count, 2)
    }

    @MainActor func testActualHostSamplesTutorialMotionConflictExplanationAndSettledCleanup() async throws {
        let rig = try GuidanceRig(); defer { rig.close() }
        rig.targets = [8, 9]; rig.action = "swipe"; rig.refresh()
        try await Task.sleep(nanoseconds: 280_000_000)
        capture(rig.window, "tutorial-horizontal-280ms-hand-at-start")
        try await Task.sleep(nanoseconds: 480_000_000)
        capture(rig.window, "tutorial-horizontal-760ms-hand-travelling")
        rig.targets = [2, 6]; rig.refresh()
        try await Task.sleep(nanoseconds: 760_000_000)
        capture(rig.window, "tutorial-vertical-760ms-hand-travelling")
        rig.targets = []; rig.action = nil; rig.refresh()
        rig.board.activate(index: 1, submit: true)
        rig.board.activate(index: 0, submit: true)
        let state = rig.session
        let explanation = try XCTUnwrap(rig.conflicts.first)
        try await Task.sleep(nanoseconds: 150_000_000)
        capture(rig.window, "conflict-visible-row-region-adjacency-150ms")
        try await Task.sleep(nanoseconds: 420_000_000)
        capture(rig.window, "conflict-visible-units-570ms")
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(rig.conflicts.isEmpty); XCTAssertNil(explanation.superview)
        XCTAssertTrue(animations(explanation.layer).isEmpty); XCTAssertEqual(rig.session, state)
    }

    @MainActor func testIdleBlinkHasOneBoardJobAcrossRedrawsAndRotatesOneFoundAnimalAtATime() throws {
        var saved = GameSession(puzzle: GuidanceRig.puzzle)
        _ = saved.submit(cell: 1); _ = saved.submit(cell: 7)
        let schedule = BlinkTestSchedule()
        let rig = try GuidanceRig(session: saved, idleBlinkScheduler: schedule.schedule); defer { rig.close() }
        let initial = try XCTUnwrap(schedule.pending.first)
        XCTAssertEqual(schedule.pending.count, 1); XCTAssertEqual(initial.0, 4)
        for _ in 0..<12 { rig.refresh() }
        XCTAssertEqual(schedule.pending.count, 1)
        XCTAssertTrue(try XCTUnwrap(schedule.pending.first).1 === initial.1,
            "Ordinary page refreshes cannot postpone the job or allocate a second timer")
        try schedule.fireNext()
        let first = try XCTUnwrap(rig.blinks.first)
        XCTAssertEqual(rig.blinks.count, 1); XCTAssertEqual(first.cellIndex, 1); XCTAssertEqual(first.duration, 0.14)
        XCTAssertEqual(schedule.pending.count, 1); XCTAssertEqual(schedule.pending.first?.0, 4)
        XCTAssertTrue(rig.board.hitTest(try rig.center(1), with: nil) === rig.board)
        capture(rig.window, "idle-blink-first-visible-animal")
        first.removeFromSuperview() // The expression's own removal is tested separately.
        try schedule.fireNext()
        XCTAssertTrue(rig.blinks.isEmpty); XCTAssertEqual(rig.looks.map(\.cellIndex), [7])
        XCTAssertEqual(rig.looks.first?.direction, .left)
        rig.looks.first?.removeFromSuperview(); try schedule.fireNext()
        XCTAssertEqual(rig.blinks.map(\.cellIndex), [1]); XCTAssertTrue(rig.looks.isEmpty)
        rig.blinks.first?.removeFromSuperview(); try schedule.fireNext()
        XCTAssertEqual(rig.looks.map(\.cellIndex), [7]); XCTAssertEqual(rig.looks.first?.direction, .right)
        XCTAssertEqual(schedule.pending.count, 1); XCTAssertEqual(rig.session, saved)
        XCTAssertTrue(rig.scores.isEmpty); XCTAssertTrue(rig.callbacks.isEmpty)
        XCTAssertFalse(rig.board.inputActivity.isBusy)
    }

    @MainActor func testIdleBlinkJobsCancelForTutorialPreviewLockMotionBackgroundNewSessionAndRemoval() throws {
        var saved = GameSession(puzzle: GuidanceRig.puzzle); _ = saved.submit(cell: 1)
        let schedule = BlinkTestSchedule()
        let rig = try GuidanceRig(session: saved, idleBlinkScheduler: schedule.schedule); defer { rig.close() }
        let beforeHide = try XCTUnwrap(schedule.pending.first?.1)
        rig.hidden = true; rig.refresh(); XCTAssertTrue(schedule.pending.isEmpty)
        beforeHide.perform(); XCTAssertTrue(rig.blinks.isEmpty)
        rig.hidden = false; rig.refresh(); XCTAssertEqual(schedule.pending.count, 1)
        rig.targets = [1]; rig.action = "tap"; rig.refresh(); XCTAssertTrue(schedule.pending.isEmpty)
        rig.targets = []; rig.action = nil; rig.refresh(); XCTAssertEqual(schedule.pending.count, 1)
        rig.preview = [0]; rig.refresh(); XCTAssertTrue(schedule.pending.isEmpty)
        rig.preview = []; rig.refresh(); XCTAssertEqual(schedule.pending.count, 1)
        rig.locked = true; rig.refresh(); XCTAssertTrue(schedule.pending.isEmpty)
        rig.locked = false; rig.refresh(); XCTAssertEqual(schedule.pending.count, 1)
        rig.reduceMotion = true; rig.refresh(); XCTAssertTrue(schedule.pending.isEmpty)
        rig.reduceMotion = false; rig.refresh(); XCTAssertEqual(schedule.pending.count, 1)
        rig.effectsEnabled = false; rig.refresh(); XCTAssertTrue(schedule.pending.isEmpty)
        rig.effectsEnabled = true; rig.refresh(); XCTAssertEqual(schedule.pending.count, 1)
        try schedule.fireNext(); XCTAssertEqual(rig.blinks.count, 1)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(schedule.pending.isEmpty); XCTAssertTrue(rig.blinks.isEmpty)
        rig.refresh(); XCTAssertTrue(schedule.pending.isEmpty)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(schedule.pending.count, 1)
        let oldSession = try XCTUnwrap(schedule.pending.first?.1)
        rig.session = GameSession(puzzle: GuidanceRig.puzzle); rig.refresh()
        XCTAssertTrue(schedule.pending.isEmpty); XCTAssertTrue(oldSession.isCancelled)
        oldSession.perform(); XCTAssertTrue(rig.blinks.isEmpty)
        _ = rig.session.submit(cell: 1); rig.refresh(); XCTAssertEqual(schedule.pending.count, 1)
        rig.board.removeFromSuperview(); XCTAssertTrue(schedule.pending.isEmpty)
    }

    @MainActor func testIdleBlinkSkipsActiveFeedbackAndResumesOnNextBoardTick() async throws {
        let schedule = BlinkTestSchedule()
        let rig = try GuidanceRig(idleBlinkScheduler: schedule.schedule); defer { rig.close() }
        XCTAssertTrue(schedule.pending.isEmpty)
        rig.board.activate(index: 1, submit: true)
        try schedule.fireNext(); XCTAssertTrue(rig.blinks.isEmpty, "The found animation owns the character")
        XCTAssertEqual(schedule.pending.count, 1)
        rig.board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardCellFeedbackView }.forEach { $0.removeFromSuperview() }
        rig.board.beginCellPress(at: try rig.center(0))
        try schedule.fireNext(); XCTAssertTrue(rig.blinks.isEmpty)
        rig.board.endCellPress()
        try schedule.fireNext(); XCTAssertTrue(rig.blinks.isEmpty, "The accepted reward continues after the next contact ends")
        XCTAssertTrue(rig.board.subviews.flatMap(\.subviews).contains { $0 is BoardPlacementBurstView })
        // Do not cancel a reward just to make an idle tick possible. Wait for
        // its actual finite cleanup, then idle motion can resume naturally.
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(rig.board.subviews.flatMap(\.subviews).contains { $0 is BoardPlacementBurstView })
        try schedule.fireNext(); XCTAssertEqual(rig.blinks.count, 1)
        rig.board.activate(index: 0, submit: true)
        XCTAssertTrue(rig.blinks.isEmpty, "A new mistake cancels an already-present blink")
        try schedule.fireNext(); XCTAssertTrue(rig.blinks.isEmpty, "Error explanation has priority over idle motion")
        rig.board.subviews.flatMap(\.subviews).filter {
            $0 is BoardMistakeFeedbackView || $0 is BoardConflictFeedbackView || $0 is CapyFaceExpressionView
        }.forEach { $0.removeFromSuperview() }
        try schedule.fireNext(); XCTAssertEqual(rig.looks.count, 1)
        XCTAssertEqual(rig.looks.first?.direction, .left)
        XCTAssertEqual(schedule.pending.count, 1)
    }

    @MainActor func testVisibleIdleLookCancelsImmediatelyForContactAndEveryBoardLifecycleBoundary() throws {
        for boundary in ["contact", "lock", "preview", "tutorial", "hidden", "motion", "disabled", "background", "session", "removed"] {
            var saved = GameSession(puzzle: GuidanceRig.puzzle); _ = saved.submit(cell: 1)
            let schedule = BlinkTestSchedule()
            let rig = try GuidanceRig(session: saved, idleBlinkScheduler: schedule.schedule); defer { rig.close() }
            try schedule.fireNext(); rig.blinks.first?.removeFromSuperview(); try schedule.fireNext()
            let look = try XCTUnwrap(rig.looks.first)
            XCTAssertTrue(rig.board.hitTest(try rig.center(1), with: nil) === rig.board)
            switch boundary {
            case "contact": rig.board.beginCellPress(at: try rig.center(0))
            case "lock": rig.locked = true; rig.refresh()
            case "preview": rig.preview = [0]; rig.refresh()
            case "tutorial": rig.targets = [0]; rig.action = "tap"; rig.refresh()
            case "hidden": rig.hidden = true; rig.refresh()
            case "motion": rig.reduceMotion = true; rig.refresh()
            case "disabled": rig.effectsEnabled = false; rig.refresh()
            case "background": NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            case "session": rig.session = GameSession(puzzle: GuidanceRig.puzzle); rig.refresh()
            default: rig.board.removeFromSuperview()
            }
            XCTAssertTrue(rig.looks.isEmpty, boundary); XCTAssertNil(look.superview, boundary)
            XCTAssertTrue(animations(look.layer).isEmpty, boundary)
            if boundary != "session" { XCTAssertEqual(rig.session, saved, boundary) }
            XCTAssertTrue(rig.scores.isEmpty); XCTAssertTrue(rig.callbacks.isEmpty)
            if boundary == "background" { NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
        }
    }

    @MainActor func testActualHostedIdleLooksShowBothDirectionsAndSettleWithoutChangingTheGame() async throws {
        var saved = GameSession(puzzle: GuidanceRig.puzzle); _ = saved.submit(cell: 1)
        let schedule = BlinkTestSchedule()
        let rig = try GuidanceRig(session: saved, idleBlinkScheduler: schedule.schedule); defer { rig.close() }
        for direction in [CapyIdleGazeDirection.left, .right] {
            try schedule.fireNext(); rig.blinks.first?.removeFromSuperview(); try schedule.fireNext()
            let look = try XCTUnwrap(rig.looks.first); XCTAssertEqual(look.direction, direction)
            try await Task.sleep(nanoseconds: 230_000_000)
            capture(rig.window, "idle-gaze-\(direction)-230ms-actual-board")
            try await Task.sleep(nanoseconds: 680_000_000)
            XCTAssertNil(look.superview); XCTAssertTrue(animations(look.layer).isEmpty)
            XCTAssertEqual(rig.session, saved); XCTAssertEqual(schedule.pending.count, 1)
        }
        capture(rig.window, "idle-gaze-neutral-settled-board")
    }
}
