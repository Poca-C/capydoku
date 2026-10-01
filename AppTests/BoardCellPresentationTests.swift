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

    @MainActor private func effect(_ kind: BoardCellFeedbackView.Kind, reduceMotion: Bool = false, lowPower: Bool = false, errorMark: Bool = false) -> BoardCellFeedbackView {
        BoardCellFeedbackView(cellIndex: 0, kind: kind, frame: CGRect(x: 0, y: 0, width: 72, height: 72),
            tileColor: UIColor(CapyPalette.regionColors[0]), reduceMotion: reduceMotion, lowPower: lowPower, errorMark: errorMark)
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
        let heart = try XCTUnwrap((view.layer.sublayers ?? []).first { $0.name == "found-local-heart" } as? CAShapeLayer)
        XCTAssertNotNil(heart.path); XCTAssertNotEqual(heart.fillColor, UIColor(CapyPalette.life).cgColor)
        XCTAssertEqual(heart.opacity, 0, "The affection heart is transient and cannot become a second life indicator")
        let fragments = (view.layer.sublayers ?? []).filter { $0.name?.hasPrefix("found-region-fragment-") == true }
        XCTAssertEqual(fragments.count, 4)
        XCTAssertEqual(stars.count + fragments.count + 1, 9, "The accepted placement has a fixed, small decorative budget")
        for star in stars {
            XCTAssertTrue(view.bounds.contains(star.frame), "Local accents must not travel into neighboring cells or the progress bar")
            let travel = try XCTUnwrap(star.animation(forKey: "found-local-travel") as? CABasicAnimation)
            let start = try XCTUnwrap(travel.fromValue as? NSValue).cgPointValue
            let end = try XCTUnwrap(travel.toValue as? NSValue).cgPointValue
            XCTAssertTrue(view.bounds.contains(start)); XCTAssertTrue(view.bounds.contains(end))
            XCTAssertEqual(star.opacity, 0, "No particle remains in the final drawing")
        }
        XCTAssertTrue(animations(view.layer).allSatisfy { $0.duration <= view.duration && $0.repeatCount == 0 && !$0.autoreverses })
        let lowPower = effect(.found, lowPower: true)
        host.addSubview(lowPower); lowPower.play()
        let lowPowerLayers = lowPower.layer.sublayers ?? []
        XCTAssertEqual(lowPower.duration, 0.32)
        XCTAssertEqual(lowPowerLayers.count, 2, "Low power keeps only the avatar and ring; decorative layers are not created")
        XCTAssertFalse(lowPowerLayers.contains { $0.name?.hasPrefix("found-local-") == true || $0.name?.hasPrefix("found-region-fragment-") == true })
        let lowPowerFace = try XCTUnwrap(lowPowerLayers.first { $0.name == "found-face-happy" })
        XCTAssertNotNil(lowPowerFace.animation(forKey: "found-pop"))
        let lowPowerRing = try XCTUnwrap(lowPowerLayers.first { $0 !== lowPowerFace })
        XCTAssertNotNil(lowPowerRing.animation(forKey: "transform.scale"))
        XCTAssertTrue(animations(lowPower.layer).allSatisfy { $0.duration <= lowPower.duration && $0.repeatCount == 0 && !$0.autoreverses })
        XCTAssertFalse(lowPower.isUserInteractionEnabled)
        try await Task.sleep(nanoseconds: 410_000_000)
        XCTAssertNil(view.superview); XCTAssertTrue(animations(view.layer).isEmpty)
        XCTAssertNil(lowPower.superview); XCTAssertTrue(animations(lowPower.layer).isEmpty)
    }

    @MainActor func testReduceMotionCreatesNoParticlesOrHiddenMotionAndStillCleansUp() async throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 90))
        var effects = [BoardCellFeedbackView.Kind.found, .markAdded, .markRemoved].map { effect($0, reduceMotion: true) }
        effects.append(effect(.found, reduceMotion: true, lowPower: true))
        for view in effects {
            host.addSubview(view); view.play()
            XCTAssertEqual(view.duration, 0.10)
            XCTAssertTrue(animations(view.layer).isEmpty)
            XCTAssertFalse((view.layer.sublayers ?? []).contains { $0.name?.hasPrefix("found-local-") == true })
            XCTAssertFalse((view.layer.sublayers ?? []).contains { $0.name?.hasPrefix("found-region-fragment-") == true })
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

    @MainActor func testMulticolorSparklesAndRegionalFragmentsStayInsideFourThroughTenCellBoards() throws {
        let expectedColors = [2, 4, 8, 9].map { UIColor(CapyPalette.regionColors[$0]).cgColor }
        for size in 4...10 {
            for boardSide in [CGFloat(190), CGFloat(340)] {
                let side = (boardSide - 14) / CGFloat(size)
                let gap = max(1.1, min(2, side * 0.028)), tileSide = side - gap * 2
                for tileColor in CapyPalette.regionColors.map({ UIColor($0) }) {
                    let view = BoardCellFeedbackView(cellIndex: size * size - 1, kind: .found,
                        frame: CGRect(x: 0, y: 0, width: tileSide, height: tileSide), tileColor: tileColor, reduceMotion: false)
                    let host = UIView(frame: view.bounds); host.addSubview(view); view.play()
                    let stars = (view.layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
                        .filter { $0.name?.hasPrefix("found-local-star-") == true }
                    XCTAssertEqual(stars.compactMap(\.fillColor), expectedColors)
                    let fragments = (view.layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
                        .filter { $0.name?.hasPrefix("found-region-fragment-") == true }
                    XCTAssertEqual(fragments.count, 4)
                    for fragment in fragments { XCTAssertEqual(fragment.fillColor, tileColor.cgColor) }
                    let heart = try XCTUnwrap((view.layer.sublayers ?? []).first { $0.name == "found-local-heart" } as? CAShapeLayer)
                    var specs: [(CAShapeLayer, String, CGFloat)] = []
                    for star in stars {
                        let radius: CGFloat = star.bounds.width / 2 + star.lineWidth / 2
                        specs.append((star, "found-local-travel", radius))
                    }
                    for fragment in fragments {
                        // The circumscribed circle also bounds intermediate rotation.
                        let radius: CGFloat = hypot(fragment.bounds.width, fragment.bounds.height) / 2 + fragment.lineWidth / 2
                        specs.append((fragment, "found-fragment-travel", radius))
                    }
                    let heartRadius: CGFloat = heart.bounds.width * 0.54 + heart.lineWidth / 2
                    specs.append((heart, "found-heart-lift", heartRadius))
                    for (particle, key, radius) in specs {
                        let travel = try XCTUnwrap(particle.animation(forKey: key) as? CABasicAnimation)
                        let start = try XCTUnwrap(travel.fromValue as? NSValue).cgPointValue
                        let end = try XCTUnwrap(travel.toValue as? NSValue).cgPointValue
                        for point in [start, end] {
                            let extent = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                            XCTAssertTrue(view.bounds.contains(extent), "Every path endpoint plus maximum scale/rotation stays inside a \(size)x\(size) tile")
                        }
                        XCTAssertEqual(particle.opacity, 0)
                    }
                    view.removeFromSuperview(); XCTAssertTrue(animations(view.layer).isEmpty)
                }
            }
        }
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
        capture(rig.board, name: "cell-found-070ms-heart-arriving-and-regional-fragments")
        try await Task.sleep(nanoseconds: 100_000_000)
        capture(rig.board, name: "cell-found-170ms-intact-heart-multicolor-sparkles-regional-fragments")
        // The local face ends at320ms; the board-level reward arc ends at620ms.
        try await Task.sleep(nanoseconds: 540_000_000)
        capture(rig.window, name: "cell-found-710ms-settled-board")
        XCTAssertTrue(rig.effects.isEmpty); XCTAssertEqual(rig.session, committed)
        let restored = PuzzleGridUIView(frame: rig.board.frame)
        rig.window.rootViewController?.view.addSubview(restored)
        defer { restored.removeFromSuperview() }
        rig.refresh(restored); restored.layoutIfNeeded()
        XCTAssertEqual(try pixels(rig.board), try pixels(restored), "After cleanup, the board must match a freshly drawn copy of its committed state exactly")
    }
}
