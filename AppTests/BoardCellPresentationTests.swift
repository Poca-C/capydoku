import XCTest
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor
private final class CellPresentationRig {
    static let puzzle = Puzzle(id: 1, size: 4,
        regions: [0, 0, 1, 1, 0, 0, 0, 1, 2, 3, 0, 1, 3, 3, 3, 1],
        solution: [1, 7, 8, 14], seed: 11400714819535654101,
        generatorVersion: "original-pipeline-v3", difficulty: "easy")
    var session = GameSession(puzzle: CellPresentationRig.puzzle)
    let board = PuzzleGridUIView(frame: CGRect(x: 20, y: 140, width: 320, height: 320))
    let window: UIWindow
    private let previousWindow: UIWindow?

    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.addSubview(board); refresh(); board.layoutIfNeeded()
    }

    func refresh(_ target: PuzzleGridUIView? = nil) {
        (target ?? board).configure(size: session.puzzle.size, regions: session.puzzle.regions,
            found: session.found, marks: session.marks, errors: session.errors, preview: [],
            sessionID: session.id, lives: session.lives, reduceMotion: false,
            tutorialTargets: [], locked: false,
            onToggle: { [weak self] index in
                guard let self else { return }; session.toggleMark(at: index); refresh()
            }, onSubmit: { [weak self] index in
                guard let self else { return }; _ = session.submit(cell: index); refresh()
            }, onMark: { _ in })
    }

    var effects: [BoardCellFeedbackView] { board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardCellFeedbackView } }
    func close() {
        board.removeFromSuperview(); window.isHidden = true
        window.rootViewController = nil; previousWindow?.makeKeyAndVisible()
    }
}

final class BoardCellPresentationTests: XCTestCase {
    @MainActor private func animations(_ layer: CALayer) -> [CAAnimation] {
        (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
            + (layer.sublayers ?? []).flatMap(animations)
    }

    @MainActor private func effect(_ kind: BoardCellFeedbackView.Kind, reduceMotion: Bool = false, errorMark: Bool = false) -> BoardCellFeedbackView {
        BoardCellFeedbackView(cellIndex: 0, kind: kind, frame: CGRect(x: 0, y: 0, width: 72, height: 72),
            tileColor: UIColor(CapyPalette.regionColors[0]), reduceMotion: reduceMotion, errorMark: errorMark)
    }

    @MainActor private func pixels(_ view: UIView) throws -> Data {
        view.setNeedsDisplay(); view.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { view.layer.render(in: $0.cgContext) }
        return try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
    }

    @MainActor private func capture(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image {
            (view.layer.presentation() ?? view.layer).render(in: $0.cgContext)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testUndoRetractsBothOutlinedStrokesWithoutShrinkingOrFadingTheWholeX() throws {
        for errorMark in [false, true] {
            let view = effect(.markRemoved, errorMark: errorMark)
            let host = UIView(frame: view.bounds); host.addSubview(view); view.play()
            defer { view.removeFromSuperview() }
            XCTAssertEqual(view.duration, 0.13)
            let strokes = view.layer.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
            XCTAssertEqual(strokes.count, 2)
            for stroke in strokes {
                let withdrawal = try XCTUnwrap(stroke.animation(forKey: "strokeEnd") as? CABasicAnimation)
                XCTAssertEqual((withdrawal.fromValue as? NSNumber)?.doubleValue, 1)
                XCTAssertEqual((withdrawal.toValue as? NSNumber)?.doubleValue, 0)
                XCTAssertEqual(withdrawal.duration, 0.13)
                XCTAssertEqual(stroke.strokeEnd, 0, "The final model drawing must stay empty after animation removal")
                XCTAssertEqual(stroke.opacity, 1)
                XCTAssertNil(stroke.animation(forKey: "opacity"))
                XCTAssertNil(stroke.animation(forKey: "transform.scale"))
            }
            XCTAssertEqual(strokes.first?.strokeColor, UIColor(CapyPalette.markOutline).cgColor)
            XCTAssertEqual(strokes.last?.strokeColor, errorMark ? UIColor(CapyPalette.life).cgColor : UIColor.white.cgColor)
            XCTAssertGreaterThan(try XCTUnwrap(strokes.first).lineWidth, try XCTUnwrap(strokes.last).lineWidth)
            XCTAssertFalse(view.isUserInteractionEnabled); XCTAssertTrue(view.accessibilityElementsHidden)
        }
    }

    @MainActor func testFoundStarsStayLocalAndAllAccentsEndWithinExistingDuration() async throws {
        let view = effect(.found), host = UIView(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        host.addSubview(view); view.play()
        let stars = (view.layer.sublayers ?? []).filter { $0.name?.hasPrefix("found-local-star-") == true }
        XCTAssertEqual(stars.count, 4)
        XCTAssertEqual(view.duration, 0.32)
        XCTAssertEqual((view.layer.sublayers ?? []).filter { $0.name == "found-local-glow" }.count, 1)
        for star in stars {
            XCTAssertTrue(view.bounds.contains(star.frame), "Local accents must not travel into neighboring cells or the progress bar")
            let travel = try XCTUnwrap(star.animation(forKey: "found-local-travel") as? CABasicAnimation)
            let start = try XCTUnwrap(travel.fromValue as? NSValue).cgPointValue
            let end = try XCTUnwrap(travel.toValue as? NSValue).cgPointValue
            XCTAssertTrue(view.bounds.contains(start)); XCTAssertTrue(view.bounds.contains(end))
            XCTAssertEqual(star.opacity, 0, "No particle remains in the final drawing")
        }
        XCTAssertTrue(animations(view.layer).allSatisfy { $0.duration <= view.duration && $0.repeatCount == 0 && !$0.autoreverses })
        try await Task.sleep(nanoseconds: 410_000_000)
        XCTAssertNil(view.superview); XCTAssertTrue(animations(view.layer).isEmpty)
    }

    @MainActor func testReduceMotionCreatesNoParticlesOrHiddenMotionAndStillCleansUp() async throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 90))
        let effects = [BoardCellFeedbackView.Kind.found, .markAdded, .markRemoved].map { effect($0, reduceMotion: true) }
        for view in effects {
            host.addSubview(view); view.play()
            XCTAssertEqual(view.duration, 0.10)
            XCTAssertTrue(animations(view.layer).isEmpty)
            XCTAssertFalse((view.layer.sublayers ?? []).contains { $0.name?.hasPrefix("found-local-") == true })
            XCTAssertFalse(view.isUserInteractionEnabled); XCTAssertTrue(view.accessibilityElementsHidden)
        }
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertTrue(effects.allSatisfy { $0.superview == nil && animations($0.layer).isEmpty })
    }

    @MainActor func testEarlyRemovalClearsAnimationsAndOldCleanupCannotRemoveReplacement() async throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        let old = effect(.found); host.addSubview(old); old.play()
        XCTAssertFalse(animations(old.layer).isEmpty)
        old.removeFromSuperview()
        XCTAssertTrue(animations(old.layer).isEmpty)
        try await Task.sleep(nanoseconds: 200_000_000)
        let replacement = effect(.found); host.addSubview(replacement); replacement.play()
        try await Task.sleep(nanoseconds: 170_000_000)
        XCTAssertTrue(replacement.superview === host, "The removed view's former cleanup deadline must not affect the new feedback")
        try await Task.sleep(nanoseconds: 210_000_000)
        XCTAssertNil(replacement.superview); XCTAssertTrue(animations(replacement.layer).isEmpty)
    }

    @MainActor func testActualBoardSamplesAndSettledPixelsMatchImmediateCommittedState() async throws {
        let rig = try CellPresentationRig(); defer { rig.close() }
        rig.board.activate(index: 0, submit: false)
        XCTAssertEqual(rig.session.marks, [0])
        rig.board.activate(index: 0, submit: false)
        XCTAssertTrue(rig.session.marks.isEmpty, "Undo commits before its withdrawal animation")
        XCTAssertEqual(rig.effects.first?.kind, .markRemoved)
        try await Task.sleep(nanoseconds: 35_000_000)
        capture(rig.window, name: "cell-undo-035ms-retracting-second-stroke")
        try await Task.sleep(nanoseconds: 45_000_000)
        capture(rig.window, name: "cell-undo-080ms-retracting-first-stroke")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(rig.effects.isEmpty)
        rig.board.activate(index: 1, submit: true)
        XCTAssertEqual(rig.session.found, [1]); XCTAssertGreaterThan(rig.session.score, 0)
        let committed = rig.session
        try await Task.sleep(nanoseconds: 70_000_000)
        capture(rig.window, name: "cell-found-070ms-avatar-light-local-stars")
        try await Task.sleep(nanoseconds: 100_000_000)
        capture(rig.window, name: "cell-found-170ms-local-stars-outward")
        try await Task.sleep(nanoseconds: 230_000_000)
        capture(rig.window, name: "cell-found-400ms-settled-board")
        XCTAssertTrue(rig.effects.isEmpty); XCTAssertEqual(rig.session, committed)
        let restored = PuzzleGridUIView(frame: rig.board.frame)
        rig.window.rootViewController?.view.addSubview(restored)
        defer { restored.removeFromSuperview() }
        rig.refresh(restored); restored.layoutIfNeeded()
        XCTAssertEqual(try pixels(rig.board), try pixels(restored), "After cleanup, the board must match a freshly drawn copy of its committed state exactly")
    }
}
