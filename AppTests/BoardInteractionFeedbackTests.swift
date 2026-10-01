import XCTest
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class InteractionFeedbackRig {
    // Original-pipeline-v3 L1 geometry from the current 150-level pack. The
    // real Core session owns decisions; this rig only connects UIKit callbacks.
    static let puzzle = Puzzle(id: 1, size: 4,
        regions: [0, 0, 1, 1, 0, 0, 0, 1, 2, 3, 0, 1, 3, 3, 3, 1],
        solution: [1, 7, 8, 14], seed: 11400714819535654101,
        generatorVersion: "original-pipeline-v3", difficulty: "easy")
    var session: GameSession
    let board = PuzzleGridUIView(frame: CGRect(x: 11, y: 37, width: 320, height: 320))
    let container = UIView(frame: CGRect(x: 19, y: 160, width: 350, height: 370))
    let window: UIWindow
    let previousWindow: UIWindow?
    var effectsEnabled = true
    var reduceMotion: Bool?
    var locked = false
    var hideAccessibility = false
    var tutorialTargets = Set<Int>()
    var preview = Set<Int>()
    var actions = 0
    var arrivals: [(index: Int, cellFrame: CGRect)] = []

    init(session: GameSession? = nil) throws {
        self.session = session ?? GameSession(puzzle: Self.puzzle)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.addSubview(container); container.addSubview(board)
        refresh(); board.layoutIfNeeded()
    }

    func refresh(_ target: PuzzleGridUIView? = nil) {
        (target ?? board).configure(size: session.puzzle.size, regions: session.puzzle.regions,
            found: session.found, marks: session.marks, errors: session.errors, preview: preview,
            sessionID: session.id, lives: session.lives, effectsEnabled: effectsEnabled,
            reduceMotion: reduceMotion,
            tutorialTargets: tutorialTargets, locked: locked || session.status != .playing,
            hideAccessibility: hideAccessibility || session.status != .playing,
            onToggle: { [weak self] index in
                guard let self else { return }; actions += 1
                session.toggleMark(at: index); refresh()
            }, onSubmit: { [weak self] index in
                guard let self else { return }; actions += 1
                _ = session.submit(cell: index); refresh()
            }, onMark: { [weak self] indices in
                guard let self else { return }; actions += 1
                session.markMany(indices); refresh()
            }, onFoundFeedback: { [weak self] index, anchor in self?.arrivals.append((index, anchor.cellFrame)) })
    }

    func cellFrame(_ index: Int) throws -> CGRect {
        let cell = try XCTUnwrap(board.accessibilityElements?[index] as? UIAccessibilityElement)
        return cell.accessibilityFrameInContainerSpace
    }
    func point(_ index: Int) throws -> CGPoint {
        let frame = try cellFrame(index)
        return CGPoint(x: frame.midX, y: frame.midY)
    }
    var press: [BoardPressedCellView] { board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardPressedCellView } }
    var cells: [BoardCellFeedbackView] { board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardCellFeedbackView } }
    var transients: [UIView] { board.subviews.flatMap(\.subviews) }
    func close() {
        board.removeFromSuperview()
        window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible()
    }
}

final class BoardInteractionFeedbackTests: XCTestCase {
    @MainActor func testPowerPolicyNotificationCancelsSettlingFaceWithoutReplayingOrChangingTheMove() async throws {
        let rig = try InteractionFeedbackRig(); defer { rig.close() }
        rig.board.activate(index: 1, submit: true)
        let face = try XCTUnwrap(rig.cells.first { $0.kind == .found })
        let accepted = rig.session
        try await Task.sleep(nanoseconds: 370_000_000)
        XCTAssertNotNil(face.superview)
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertNil(face.superview); XCTAssertTrue(rig.cells.isEmpty)
        XCTAssertTrue(face.layer.sublayers?.allSatisfy { ($0.animationKeys() ?? []).isEmpty } == true)
        rig.refresh(); XCTAssertTrue(rig.cells.isEmpty)
        XCTAssertEqual(rig.session, accepted); XCTAssertEqual(rig.arrivals.count, 1)
    }

    @MainActor private func capture(_ view: UIView, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            (view.layer.presentation() ?? view.layer).render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testRawContactAcknowledgesImmediatelyWithoutChangingGameOrRecognizerActivity() throws {
        let rig = try InteractionFeedbackRig(); defer { rig.close() }
        let before = rig.session, first = try rig.point(0), next = try rig.point(1)
        // Exercise the presentation endpoints used by raw pan contacts, not
        // fabricated UITouch objects or a claim about system recognizer timing.
        rig.board.beginCellPress(at: first)
        let highlight = try XCTUnwrap(rig.press.first)
        XCTAssertEqual(highlight.cellIndex, 0)
        XCTAssertFalse(highlight.isUserInteractionEnabled)
        XCTAssertTrue(rig.board.hitTest(first, with: nil) === rig.board)
        XCTAssertEqual(rig.board.gestureRecognizers?.count, 3)
        XCTAssertFalse(rig.board.inputActivity.isBusy)
        capture(rig.window, "board-contact-before-recognition")
        rig.board.moveCellPress(to: next)
        XCTAssertEqual(rig.press.map(\.cellIndex), [1])
        rig.board.moveCellPress(to: CGPoint(x: -1, y: -1))
        XCTAssertTrue(rig.press.isEmpty)
        rig.board.moveCellPress(to: first)
        XCTAssertTrue(rig.press.isEmpty, "Leaving the board ends this contact; re-entry needs a new touch.")
        rig.board.beginCellPress(at: first); rig.board.endCellPress()
        XCTAssertTrue(rig.press.isEmpty)
        XCTAssertEqual(rig.session, before, "Press and cancellation cannot mark, find, score or deduct life.")
        XCTAssertEqual(rig.actions, 0); XCTAssertTrue(rig.arrivals.isEmpty)
    }

    @MainActor func testOnlyOperableCellsShowPressAndPolicyChangesClearIt() throws {
        let rig = try InteractionFeedbackRig(); defer { rig.close() }
        let first = try rig.point(0), solution = try rig.point(1)
        rig.tutorialTargets = [1]; rig.refresh()
        rig.board.beginCellPress(at: first); XCTAssertTrue(rig.press.isEmpty)
        rig.board.beginCellPress(at: solution); XCTAssertEqual(rig.press.count, 1)
        rig.tutorialTargets = [7]; rig.refresh(); XCTAssertTrue(rig.press.isEmpty)
        rig.tutorialTargets = []; rig.refresh()
        rig.board.beginCellPress(at: first)
        rig.locked = true; rig.refresh(); XCTAssertTrue(rig.press.isEmpty)
        rig.board.beginCellPress(at: first); XCTAssertTrue(rig.press.isEmpty)
        rig.locked = false; rig.refresh(); rig.board.beginCellPress(at: first)
        rig.preview = [0]; rig.refresh(); XCTAssertTrue(rig.press.isEmpty)
        rig.preview = []; rig.refresh(); rig.board.beginCellPress(at: first)
        rig.hideAccessibility = true; rig.refresh(); XCTAssertTrue(rig.press.isEmpty)
        rig.hideAccessibility = false; rig.refresh()
        XCTAssertTrue(rig.board.activate(index: 1, submit: true))
        rig.board.beginCellPress(at: solution); XCTAssertTrue(rig.press.isEmpty)
        XCTAssertEqual(rig.session.found, [1]); XCTAssertEqual(rig.actions, 1)
    }

    @MainActor func testMarkUndoAndRapidReplacementLeaveOnlyCommittedCoreState() async throws {
        let rig = try InteractionFeedbackRig(); defer { rig.close() }
        let initialLives = rig.session.lives
        rig.board.activate(index: 0, submit: false)
        let added = try XCTUnwrap(rig.cells.first)
        XCTAssertEqual(added.kind, .markAdded); XCTAssertEqual(rig.session.marks, [0])
        XCTAssertEqual(added.backgroundColor?.cgColor.alpha, 1, "An opaque tile prevents the committed X from swallowing its stroke animation.")
        XCTAssertTrue(rig.board.hitTest(try rig.point(0), with: nil) === rig.board)
        rig.board.activate(index: 0, submit: false)
        let removed = try XCTUnwrap(rig.cells.first)
        XCTAssertEqual(removed.kind, .markRemoved); XCTAssertNil(added.superview)
        XCTAssertTrue(rig.session.marks.isEmpty)
        rig.board.activate(index: 0, submit: false)
        let replacement = try XCTUnwrap(rig.cells.first)
        XCTAssertEqual(replacement.kind, .markAdded); XCTAssertNil(removed.superview)
        XCTAssertEqual(rig.cells.count, 1)
        let committed = rig.session
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(rig.cells.isEmpty); XCTAssertEqual(rig.session, committed)
        XCTAssertEqual(rig.session.lives, initialLives); XCTAssertTrue(rig.arrivals.isEmpty)
    }

    @MainActor func testFinalFoundUsesWindowCoordinatesAndDoesNotReplayOnRestoreOrRedraw() async throws {
        var restored = GameSession(puzzle: InteractionFeedbackRig.puzzle)
        for index in [1, 7, 8] { _ = restored.submit(cell: index) }
        let rig = try InteractionFeedbackRig(session: restored); defer { rig.close() }
        XCTAssertTrue(rig.cells.isEmpty); XCTAssertTrue(rig.arrivals.isEmpty)
        let finalPoint = try rig.point(14)
        let expected = rig.board.convert(finalPoint, to: rig.window)
        // Cache the independently measured accessibility rectangle before the
        // winning move removes cell accessibility and disables input.
        let finalCell = try rig.cellFrame(14)
        let expectedFrame = rig.board.convert(finalCell, to: rig.window)
        rig.board.activate(index: 14, submit: true)
        XCTAssertEqual(rig.session.status, .won)
        XCTAssertEqual(rig.arrivals.count, 1); XCTAssertEqual(rig.arrivals.first?.index, 14)
        let reportedFrame = try XCTUnwrap(rig.arrivals.first).cellFrame
        XCTAssertEqual(reportedFrame.midX, expected.x, accuracy: 0.001)
        XCTAssertEqual(reportedFrame.midY, expected.y, accuracy: 0.001)
        XCTAssertEqual(reportedFrame.minX, expectedFrame.minX, accuracy: 0.001)
        XCTAssertEqual(reportedFrame.minY, expectedFrame.minY, accuracy: 0.001)
        XCTAssertEqual(reportedFrame.width, expectedFrame.width, accuracy: 0.001)
        XCTAssertEqual(reportedFrame.height, expectedFrame.height, accuracy: 0.001)
        XCTAssertNotEqual(reportedFrame.origin, finalCell.origin,
                          "The callback must include both nested view offsets, not a board-local rectangle.")
        let effect = try XCTUnwrap(rig.cells.first)
        XCTAssertEqual(effect.kind, .found); XCTAssertFalse(effect.isUserInteractionEnabled)
        XCTAssertEqual(effect.backgroundColor?.cgColor.alpha, 1, "The final avatar must not already appear at full size beneath its pop.")
        XCTAssertTrue(rig.board.accessibilityElements?.isEmpty == true)
        XCTAssertTrue(rig.board.gestureRecognizers?.allSatisfy { !$0.isEnabled } == true)
        rig.refresh(); rig.board.setNeedsDisplay(); rig.board.layoutIfNeeded()
        XCTAssertEqual(rig.arrivals.count, 1); XCTAssertTrue(rig.cells.first === effect)
        try await Task.sleep(nanoseconds: 80_000_000)
        capture(rig.window, "board-final-found-pop-before-result")
        try await Task.sleep(nanoseconds: 320_000_000)
        capture(rig.window, "board-final-found-settled")
        XCTAssertTrue(rig.cells.isEmpty); XCTAssertEqual(rig.session.status, .won)
        let replacement = PuzzleGridUIView(frame: rig.board.frame)
        rig.container.addSubview(replacement); rig.refresh(replacement); replacement.layoutIfNeeded()
        XCTAssertTrue(replacement.subviews.flatMap(\.subviews).isEmpty)
        XCTAssertEqual(rig.arrivals.count, 1, "Saved found cells are state, not new arrivals.")
        replacement.removeFromSuperview()
    }

    @MainActor func testSuspensionSessionReplacementAndDetachmentClearWithoutReplaying() throws {
        let rig = try InteractionFeedbackRig(); defer { rig.close() }
        defer { NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
        let point = try rig.point(0)
        rig.board.activate(index: 1, submit: true); rig.board.beginCellPress(at: point)
        XCTAssertFalse(rig.transients.isEmpty)
        let committed = rig.session
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(rig.transients.isEmpty)
        rig.refresh(); rig.board.beginCellPress(at: point)
        XCTAssertTrue(rig.transients.isEmpty)
        XCTAssertTrue(rig.board.gestureRecognizers?.allSatisfy { !$0.isEnabled } == true)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        rig.refresh(); XCTAssertTrue(rig.transients.isEmpty)
        XCTAssertEqual(rig.arrivals.count, 1); XCTAssertEqual(rig.session, committed)
        rig.board.activate(index: 0, submit: false); rig.board.beginCellPress(at: point)
        rig.session.id = UUID(); rig.refresh()
        XCTAssertTrue(rig.transients.isEmpty, "A fresh attempt with identical geometry cannot retain the old press or mark animation.")
        rig.board.beginCellPress(at: point)
        rig.effectsEnabled = false; rig.refresh(); XCTAssertTrue(rig.transients.isEmpty)
        rig.effectsEnabled = true; rig.refresh(); XCTAssertTrue(rig.transients.isEmpty)
        rig.board.activate(index: 7, submit: true); rig.board.beginCellPress(at: point)
        XCTAssertFalse(rig.transients.isEmpty)
        rig.board.removeFromSuperview(); XCTAssertTrue(rig.transients.isEmpty)
        XCTAssertEqual(rig.arrivals.count, 2)
    }

    @MainActor func testReducedMotionHasStaticConfirmationWithoutHiddenMotionAnimations() async throws {
        let rig = try InteractionFeedbackRig(); defer { rig.close() }
        let original = rig.session
        var effects: [BoardCellFeedbackView] = []
        for (index, kind) in [BoardCellFeedbackView.Kind.found, .markAdded, .markRemoved].enumerated() {
            let effect = BoardCellFeedbackView(cellIndex: index, kind: kind,
                frame: CGRect(x: 20 + index * 90, y: 40, width: 80, height: 80),
                tileColor: UIColor(CapyPalette.regionColors[index]), reduceMotion: true)
            rig.container.addSubview(effect); effect.play(); effects.append(effect)
        }
        func animationKeys(_ layer: CALayer) -> [String] {
            (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(animationKeys)
        }
        XCTAssertTrue(effects.allSatisfy { animationKeys($0.layer).isEmpty })
        capture(rig.window, "board-reduce-motion-static-confirmations")
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertTrue(effects.allSatisfy { $0.superview == nil })
        XCTAssertEqual(rig.session, original); XCTAssertEqual(rig.actions, 0)
    }

    @MainActor func testConfiguredReduceMotionAppliesToCommittedFoundAndMistakeFeedback() throws {
        let rig = try InteractionFeedbackRig(); defer { rig.close() }
        rig.reduceMotion = true; rig.refresh()
        rig.board.activate(index: 1, submit: true)
        let found = try XCTUnwrap(rig.cells.first)
        XCTAssertEqual(found.kind, .found)
        rig.board.activate(index: 0, submit: true)
        let mistake = try XCTUnwrap(rig.transients.compactMap { $0 as? BoardMistakeFeedbackView }.first)
        func animationKeys(_ layer: CALayer) -> [String] {
            (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(animationKeys)
        }
        XCTAssertTrue(animationKeys(found.layer).isEmpty)
        XCTAssertTrue(animationKeys(mistake.layer).isEmpty)
        XCTAssertEqual(rig.session.found, [1]); XCTAssertEqual(rig.session.errors, [0])
        XCTAssertEqual(rig.session.lives, 2); XCTAssertEqual(rig.arrivals.count, 1)
    }
}
