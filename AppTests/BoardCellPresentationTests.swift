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
    var bursts: [BoardPlacementBurstView] { board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardPlacementBurstView } }
    func center(_ index: Int) throws -> CGPoint {
        let element = try XCTUnwrap(board.accessibilityElements?[index] as? UIAccessibilityElement)
        return CGPoint(x: element.accessibilityFrameInContainerSpace.midX,
                       y: element.accessibilityFrameInContainerSpace.midY)
    }
    func close() {
        board.removeFromSuperview(); window.isHidden = true
        window.rootViewController = nil; previousWindow?.makeKeyAndVisible()
    }
}

final class BoardCellPresentationTests: XCTestCase {
    @MainActor func testConfirmedMistakeEndsPreviousCelebrationWithoutWaitingToApplyDamage() throws {
        let rig = try CellPresentationRig(); defer { rig.close() }
        rig.board.activate(index: 1, submit: true)
        let reward = try XCTUnwrap(rig.bursts.first), earned = rig.session.score
        rig.board.beginCellPress(at: try rig.center(0)); rig.board.endCellPress()
        XCTAssertTrue(rig.bursts.contains { $0 === reward }, "Intent alone must not cancel the earlier success")
        rig.board.activate(index: 0, submit: true)
        XCTAssertEqual(rig.session.lives, 2); XCTAssertEqual(rig.session.errors, [0])
        XCTAssertEqual(rig.session.found, [1]); XCTAssertEqual(rig.session.score, earned)
        XCTAssertTrue(rig.bursts.isEmpty, "Once a mistake is confirmed its feedback must not compete with old success confetti")
        XCTAssertTrue(animations(reward.layer).isEmpty)
    }

    @MainActor func testMistakeDuringExpressionSettleImmediatelyRetiresTheCorrectFace() async throws {
        let rig = try CellPresentationRig(); defer { rig.close() }
        rig.board.activate(index: 1, submit: true)
        let face = try XCTUnwrap(rig.effects.first { $0.kind == .found })
        let earned = rig.session.score
        try await Task.sleep(nanoseconds: 370_000_000)
        XCTAssertNotNil(face.superview, "The accepted happy reaction outlives its quick pop.")
        rig.board.activate(index: 0, submit: true)
        XCTAssertNil(face.superview); XCTAssertTrue(animations(face.layer).isEmpty)
        XCTAssertEqual(rig.session.lives, 2); XCTAssertEqual(rig.session.found, [1])
        XCTAssertEqual(rig.session.score, earned)
        rig.board.activate(index: 7, submit: true)
        let replacement = try XCTUnwrap(rig.effects.first { $0.cellIndex == 7 })
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(replacement.superview, "The cancelled 0.60s cleanup of the older correct face cannot remove a newer one.")
        XCTAssertEqual(rig.session.found, [1, 7]); XCTAssertEqual(rig.session.lives, 2)
    }

    @MainActor func testNextContactKeepsCommittedRewardAliveWhileFurtherFindsAndMarksApplyImmediately() async throws {
        let rig = try CellPresentationRig(); defer { rig.close() }
        rig.board.activate(index: 1, submit: true)
        let first = try XCTUnwrap(rig.bursts.first)
        let firstFlight = try XCTUnwrap(first.layer.sublayers?.first?.animation(forKey: "placement-flight"))
        try await Task.sleep(nanoseconds: 100_000_000)
        capture(rig.board, name: "continuous-find-01-first-reward")

        let next = try rig.center(7), pointsBeforeTouch = rig.session.score
        rig.board.beginCellPress(at: next)
        XCTAssertTrue(rig.bursts.contains { $0 === first }, "The first contact of the next double-tap cannot erase a committed reward")
        XCTAssertEqual(first.layer.sublayers?.first?.animation(forKey: "placement-flight")?.beginTime, firstFlight.beginTime,
                       "Contact cannot restart the reward's finite lifetime")
        XCTAssertTrue(rig.board.hitTest(next, with: nil) === rig.board, "Continuing particles cannot intercept board input")
        XCTAssertEqual(rig.session.found, [1]); XCTAssertEqual(rig.session.score, pointsBeforeTouch)
        try await Task.sleep(nanoseconds: 80_000_000)
        capture(rig.board, name: "continuous-find-02-next-contact-keeps-flight")
        rig.board.endCellPress()
        rig.board.activate(index: 7, submit: true)
        XCTAssertEqual(rig.session.found, [1, 7]); XCTAssertGreaterThan(rig.session.score, pointsBeforeTouch)
        XCTAssertEqual(Set(rig.bursts.map(\.cellIndex)), [1, 7])
        let second = try XCTUnwrap(rig.bursts.first { $0.cellIndex == 7 })
        let secondFlight = try XCTUnwrap(second.layer.sublayers?.first?.animation(forKey: "placement-flight"))
        XCTAssertGreaterThan(secondFlight.beginTime, firstFlight.beginTime)
        try await Task.sleep(nanoseconds: 90_000_000)
        capture(rig.board, name: "continuous-find-03-two-independent-rewards")

        let pointsBeforeMark = rig.session.score
        rig.board.beginCellPress(at: try rig.center(0)); rig.board.endCellPress()
        rig.board.activate(index: 0, submit: false)
        XCTAssertEqual(rig.session.marks, [0]); XCTAssertEqual(rig.session.found, [1, 7])
        XCTAssertEqual(rig.session.score, pointsBeforeMark); XCTAssertEqual(rig.session.lives, 3)
        XCTAssertTrue(rig.bursts.contains { $0 === second }, "An ordinary mark also preserves the accepted reward")
        rig.board.beginCellPress(at: CGPoint(x: -20, y: -20)); rig.board.endCellPress()
        XCTAssertTrue(rig.bursts.contains { $0 === second }, "An out-of-board contact is not a cancellation event")
        try await Task.sleep(nanoseconds: 560_000_000)
        XCTAssertTrue(rig.bursts.isEmpty, "Both original cleanup deadlines must still finish normally")
        XCTAssertTrue(animations(first.layer).isEmpty); XCTAssertTrue(animations(second.layer).isEmpty)
        capture(rig.board, name: "continuous-find-04-settled-with-committed-mark")
    }

    @MainActor private func animations(_ layer: CALayer) -> [CAAnimation] {
        (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
            + (layer.sublayers ?? []).flatMap(animations)
    }

    @MainActor private func effect(_ kind: BoardCellFeedbackView.Kind, reduceMotion: Bool = false, lowPower: Bool = false, errorMark: Bool = false, settlesToRest: Bool = true) -> BoardCellFeedbackView {
        BoardCellFeedbackView(cellIndex: 0, kind: kind, frame: CGRect(x: 0, y: 0, width: 72, height: 72),
            tileColor: UIColor(CapyPalette.regionColors[0]), reduceMotion: reduceMotion, lowPower: lowPower, errorMark: errorMark,
            settlesToRest: settlesToRest)
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
        XCTAssertEqual(view.duration, 0.60)
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
        XCTAssertTrue(animations(view.layer).filter { ($0 as? CAPropertyAnimation)?.keyPath != "contents" }.allSatisfy { $0.duration <= 0.32 },
                      "Expression settling must not slow the existing pop, ring or particles.")
        let lowPower = effect(.found, lowPower: true)
        host.addSubview(lowPower); lowPower.play()
        let lowPowerLayers = lowPower.layer.sublayers ?? []
        XCTAssertEqual(lowPower.duration, 0.32)
        XCTAssertEqual(lowPowerLayers.count, 2, "Low power keeps only the avatar and ring; decorative layers are not created")
        XCTAssertFalse(lowPowerLayers.contains { $0.name?.hasPrefix("found-local-") == true || $0.name?.hasPrefix("found-region-fragment-") == true })
        let lowPowerFace = try XCTUnwrap(lowPowerLayers.first { $0.name == "found-face-happy" })
        XCTAssertNotNil(lowPowerFace.animation(forKey: "found-pop"))
        XCTAssertNil(lowPowerFace.animation(forKey: "found-expression-settle"))
        let lowPowerRing = try XCTUnwrap(lowPowerLayers.first { $0 !== lowPowerFace })
        XCTAssertNotNil(lowPowerRing.animation(forKey: "transform.scale"))
        XCTAssertTrue(animations(lowPower.layer).allSatisfy { $0.duration <= lowPower.duration && $0.repeatCount == 0 && !$0.autoreverses })
        XCTAssertFalse(lowPower.isUserInteractionEnabled)
        try await Task.sleep(nanoseconds: 680_000_000)
        XCTAssertNil(view.superview); XCTAssertTrue(animations(view.layer).isEmpty)
        XCTAssertNil(lowPower.superview); XCTAssertTrue(animations(lowPower.layer).isEmpty)
    }

    @MainActor func testFoundExpressionSettlesOnOneFaceAndItsFinalPixelsMatchTheUncoveredBoard() async throws {
        let rig = try CellPresentationRig(); defer { rig.close() }
        rig.board.activate(index: 1, submit: true)
        let view = try XCTUnwrap(rig.effects.first { $0.kind == .found })
        let faceLayers = (view.layer.sublayers ?? []).filter { $0.name == "found-face-happy" }
        XCTAssertEqual(faceLayers.count, 1, "The expression transition must not cross-fade two complete faces.")
        let face = try XCTUnwrap(faceLayers.first)
        let poses = try XCTUnwrap(face.animation(forKey: "found-expression-settle") as? CAKeyframeAnimation)
        XCTAssertEqual(poses.calculationMode, .discrete)
        XCTAssertEqual(poses.duration, 0.60); XCTAssertEqual(poses.repeatCount, 0)
        let times = try XCTUnwrap(poses.keyTimes).map(\.doubleValue)
        let values = try XCTUnwrap(poses.values)
        XCTAssertEqual(times.count, values.count)
        for (seconds, expected) in [(0.35, CapyFaceExpression.happy), (0.47, .blink), (0.55, .neutral)] {
            let index = try XCTUnwrap(times.indices.last { times[$0] <= seconds / poses.duration })
            XCTAssertTrue((values[index] as AnyObject) === CapyExpressionArtwork.image(expected)?.cgImage,
                          "The short expression sequence must hold happiness, blink, then settle before removal.")
        }
        XCTAssertTrue((try XCTUnwrap(face.contents) as AnyObject) === CapyExpressionArtwork.image(.neutral)?.cgImage,
                      "Removing the contents animation must leave the same face as the committed board.")
        XCTAssertTrue(CATransform3DIsIdentity(face.transform)); XCTAssertEqual(face.opacity, 1)
        let accepted = rig.session
        try await Task.sleep(nanoseconds: 545_000_000)
        XCTAssertNotNil(view.superview, "The neutral ending must be displayed briefly before the cover is removed.")
        let presentation = try XCTUnwrap(face.presentation())
        XCTAssertTrue((try XCTUnwrap(presentation.contents) as AnyObject) === CapyExpressionArtwork.image(.neutral)?.cgImage)
        capture(rig.board, name: "cell-found-resting-before-cover-removal")
        // Render the complete board at its original origin and native screen
        // scale before cropping integer pixels. Rendering a translated 1x
        // interior would resample the board's backing and the live image layer
        // differently. These are model-layer diagnostics, not compositor/video
        // frames; the natural presentation contents were checked just above.
        let interior = rig.board.convert(view.bounds.insetBy(dx: 6, dy: 6), from: view)
        let scale = rig.window.screen.scale
        let crop = CGRect(x: floor(interior.minX * scale), y: floor(interior.minY * scale),
                          width: ceil(interior.maxX * scale) - floor(interior.minX * scale),
                          height: ceil(interior.maxY * scale) - floor(interior.minY * scale))
        let faceInBoard = face.convert(face.bounds, to: rig.board.layer)
        let faceInWindow = face.convert(face.bounds, to: rig.window.layer)
        let cell = try XCTUnwrap(rig.board.accessibilityElements?[1] as? UIAccessibilityElement).accessibilityFrameInContainerSpace
        let gap = max(1.1, min(2, cell.width * 0.028))
        let tile = cell.insetBy(dx: gap, dy: gap)
        let boardTarget = tile.insetBy(dx: tile.width * 0.07, dy: tile.height * 0.07)
        let targetInWindow = rig.board.convert(boardTarget, to: rig.window)
        func interiorImage() throws -> CGImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: rig.board.bounds, format: format).image { context in
                rig.board.layer.render(in: context.cgContext)
            }
            return try XCTUnwrap(image.cgImage?.cropping(to: crop))
        }
        let coveredImage = try interiorImage()
        view.removeFromSuperview()
        let uncoveredImage = try interiorImage()
        for (name, image) in [("before", coveredImage), ("after", uncoveredImage)] {
            let attachment = XCTAttachment(image: UIImage(cgImage: image, scale: scale, orientation: .up))
            attachment.name = "cell-found-native-handoff-" + name; attachment.lifetime = .keepAlways; add(attachment)
        }
        func rgba(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let drew = bytes.withUnsafeMutableBytes { storage -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            XCTAssertTrue(drew)
            return bytes
        }
        let covered = try rgba(coveredImage), uncovered = try rgba(uncoveredImage)
        XCTAssertEqual(coveredImage.width, uncoveredImage.width); XCTAssertEqual(coveredImage.height, uncoveredImage.height)
        var differentPixels = 0, absoluteSum = 0, maximumDifference = 0
        var minX = coveredImage.width, minY = coveredImage.height, maxX = -1, maxY = -1
        for pixel in 0..<(coveredImage.width * coveredImage.height) {
            var changed = false
            for channel in 0..<4 {
                let difference = abs(Int(covered[pixel * 4 + channel]) - Int(uncovered[pixel * 4 + channel]))
                absoluteSum += difference; maximumDifference = max(maximumDifference, difference)
                changed = changed || difference != 0
            }
            if changed {
                differentPixels += 1
                let x = pixel % coveredImage.width, y = pixel / coveredImage.width
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        func rectComponents(_ rect: CGRect) -> [Double] { [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }
        let diagnostics: [String: Any] = [
            "rendering": "Complete model board layer rendered at its original origin with native screen scale, then integer-pixel crop; no per-crop translation or 1x downsampling.",
            "screenScale": Double(scale), "boardBackingScale": Double(rig.board.layer.contentsScale),
            "faceContentsScale": Double(face.contentsScale), "cropPixels": rectComponents(crop),
            "faceFrameInBoardPoints": rectComponents(faceInBoard), "boardTargetFramePoints": rectComponents(boardTarget),
            "faceFrameInWindowPoints": rectComponents(faceInWindow), "boardTargetFrameInWindowPoints": rectComponents(targetInWindow),
            "pixelCount": coveredImage.width * coveredImage.height, "differentPixelCount": differentPixels,
            "comparedChannels": "premultiplied RGBA in sRGB",
            "meanAbsoluteChannelError0To255": Double(absoluteSum) / Double(covered.count),
            "maximumAbsoluteChannelDifference0To255": maximumDifference,
            "differenceBoundsInCropPixels": maxX >= minX ? [minX, minY, maxX - minX + 1, maxY - minY + 1] : []
        ]
        let report = XCTAttachment(data: try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]),
                                   uniformTypeIdentifier: "public.json")
        report.name = "cell-found-native-handoff-diagnostics"; report.lifetime = .keepAlways; add(report)
        XCTAssertTrue(covered == uncovered, "Removing a settled face cannot change the committed character pixels; inspect native handoff attachments before deciding whether a residual is geometric or rasterization-only.")
        XCTAssertEqual(rig.session, accepted)
        XCTAssertTrue(animations(view.layer).isEmpty)
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
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(replacement.superview === host, "The removed view's former cleanup deadline must not affect the new feedback")
        try await Task.sleep(nanoseconds: 210_000_000)
        XCTAssertNil(replacement.superview); XCTAssertTrue(animations(replacement.layer).isEmpty)
    }

    @MainActor func testFinalCellAndLowPowerKeepTheQuickHappyHandoffWithoutASettleTrack() async throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        let finishing = effect(.found, settlesToRest: false)
        let lowPower = effect(.found, lowPower: true)
        for view in [finishing, lowPower] {
            host.addSubview(view); view.play()
            XCTAssertEqual(view.duration, 0.32)
            let face = try XCTUnwrap(view.layer.sublayers?.first { $0.name == "found-face-happy" })
            XCTAssertNil(face.animation(forKey: "found-expression-settle"))
            XCTAssertTrue((try XCTUnwrap(face.contents) as AnyObject) === CapyExpressionArtwork.image(.happy)?.cgImage)
            XCTAssertEqual(face.animation(forKey: "found-pop")?.duration, 0.32)
            XCTAssertFalse(view.isUserInteractionEnabled)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue([finishing, lowPower].allSatisfy { $0.superview == nil && animations($0.layer).isEmpty })
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
        // The local pop ends at320ms, its expression settles by600ms, and the
        // independent board-level reward arc ends at620ms.
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
