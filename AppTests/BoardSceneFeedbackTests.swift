import XCTest
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class BoardSceneRig {
    static let puzzle = Puzzle(id: 1, size: 4,
        regions: [0, 0, 1, 1, 0, 0, 0, 1, 2, 3, 0, 1, 3, 3, 3, 1],
        solution: [1, 7, 8, 14], seed: 11400714819323198485,
        generatorVersion: "original-pipeline-v3", difficulty: "easy")
    var session: GameSession
    var entranceID: UUID?
    var effectsEnabled = true
    var hidden = false
    var reduceMotion = false
    var preview = Set<Int>()
    var actionCount = 0
    let board = PuzzleGridUIView(frame: CGRect(x: 20, y: 150, width: 320, height: 320))
    let window: UIWindow
    private let previousWindow: UIWindow?

    init(session: GameSession? = nil, entranceID: UUID? = nil) throws {
        self.session = session ?? GameSession(puzzle: Self.puzzle); self.entranceID = entranceID
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = controller; window.makeKeyAndVisible()
        // Match UIViewRepresentable: configuration may precede mounting/layout.
        refresh(); controller.view.addSubview(board); board.layoutIfNeeded()
    }
    func refresh() {
        board.configure(size: session.puzzle.size, regions: session.puzzle.regions,
            found: session.found, marks: session.marks, errors: session.errors, preview: preview,
            sessionID: session.id, entranceID: entranceID, lives: session.lives, score: session.score,
            effectsEnabled: effectsEnabled, reduceMotion: reduceMotion,
            tutorialTargets: [], locked: session.status != .playing,
            hideAccessibility: hidden || session.status != .playing,
            onToggle: { [weak self] index in
                guard let self else { return }; actionCount += 1; session.toggleMark(at: index); refresh()
            }, onSubmit: { [weak self] index in
                guard let self else { return }; actionCount += 1; _ = session.submit(cell: index); refresh()
            }, onMark: { [weak self] cells in
                guard let self else { return }; actionCount += 1; session.markMany(cells); refresh()
            })
    }
    var scenes: [BoardSceneFeedbackView] { board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardSceneFeedbackView } }
    func point(_ index: Int) throws -> CGPoint {
        let cell = try XCTUnwrap(board.accessibilityElements?[index] as? UIAccessibilityElement)
        return CGPoint(x: cell.accessibilityFrameInContainerSpace.midX, y: cell.accessibilityFrameInContainerSpace.midY)
    }
    func close() {
        board.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
        previousWindow?.makeKeyAndVisible()
    }
}

final class BoardSceneFeedbackTests: XCTestCase {
    /// Check the persistent board pixels, after the temporary celebration has
    /// actually expired. A happy overlay alone cannot satisfy this contract.
    @MainActor func testCompletedBoardKeepsHappyPortraitsAfterCelebrationAndRestore() async throws {
        for reduced in [false, true] {
            let rig = try BoardSceneRig(); defer { rig.close() }
            rig.reduceMotion = reduced; rig.refresh()
            for index in [1, 7, 8] { XCTAssertTrue(rig.board.activate(index: index, submit: true)) }
            try await Task.sleep(nanoseconds: 660_000_000)
            assertPortraits(rig, expression: .neutral, label: "playing")
            XCTAssertTrue(rig.board.activate(index: 14, submit: true))
            let committed = rig.session
            XCTAssertEqual(committed.status, .won)
            try await Task.sleep(nanoseconds: 860_000_000)
            XCTAssertTrue(rig.scenes.isEmpty)
            assertPortraits(rig, expression: .happy, label: "won-reduced-\(reduced)")
            capture(rig.window, "completed-board-persistent-happy-reduced-\(reduced)")
            rig.board.cancelPresentation(); rig.effectsEnabled = false; rig.refresh()
            assertPortraits(rig, expression: .happy, label: "effects-off")
            XCTAssertEqual(rig.session, committed)
            // Re-mounting a completed save must retain the expression without
            // reissuing the victory animation or adding any gameplay event.
            let restored = try BoardSceneRig(session: committed)
            defer { restored.close() }
            XCTAssertTrue(restored.scenes.isEmpty)
            assertPortraits(restored, expression: .happy, label: "restored")
            restored.session = GameSession(puzzle: BoardSceneRig.puzzle)
            _ = restored.session.submit(cell: 1); restored.refresh()
            restored.board.cancelPresentation()
            assertPortraits(restored, expression: .neutral, label: "new-attempt")
            XCTAssertEqual(restored.session.status, .playing)
        }
    }

    @MainActor private func assertPortraits(_ rig: BoardSceneRig, expression: CapyFaceExpression,
                                           label: String, file: StaticString = #filePath, line: UInt = #line) {
        let board = rig.board
        board.layoutIfNeeded(); board.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: board.bounds, format: format)
        let actual = renderer.image { board.layer.render(in: $0.cgContext) }
        let size = rig.session.puzzle.size
        let area = board.bounds.insetBy(dx: 7, dy: 7), side = area.width / CGFloat(size)
        let gap = max(1.1, min(2, side * 0.028))
        for index in rig.session.found.sorted() {
            let tile = CGRect(x: area.minX + CGFloat(index % size) * side,
                              y: area.minY + CGFloat(index / size) * side,
                              width: side, height: side).insetBy(dx: gap, dy: gap)
            let face = tile.insetBy(dx: tile.width * 0.07, dy: tile.height * 0.07)
            let expected = renderer.image { context in
                UIColor(CapyPalette.regionColors[rig.session.puzzle.regions[index]]).setFill()
                context.fill(tile)
                CapyExpressionArtwork.image(expression)?.draw(in: face)
            }
            let crop = face.insetBy(dx: 1, dy: 1).applying(CGAffineTransform(scaleX: 3, y: 3)).integral
            guard let a = actual.cgImage?.cropping(to: crop), let e = expected.cgImage?.cropping(to: crop) else {
                XCTFail("Missing portrait pixels: \(label)", file: file, line: line); continue
            }
            // Normalize cropped images: providers may retain the parent row
            // stride, so compare compact rendered buffers, not provider tails.
            func pixels(_ image: CGImage) -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
                bytes.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                return bytes
            }
            let left = pixels(a), right = pixels(e)
            let differing = zip(left, right).filter { abs(Int($0) - Int($1)) > 2 }.count
            XCTAssertEqual(differing, 0, "\(label) cell \(index) must retain \(expression) pixels", file: file, line: line)
        }
    }

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

    @MainActor func testEntranceSurvivesInitialMountButSameEventNeverReplaysAndFirstContactRevealsLiveBoard() throws {
        let event = UUID(), rig = try BoardSceneRig(entranceID: event); defer { rig.close() }
        let entrance = try XCTUnwrap(rig.scenes.first)
        XCTAssertEqual(entrance.kind, .entrance); XCTAssertEqual(entrance.duration, 0.56)
        XCTAssertEqual(rig.actionCount, 0); XCTAssertTrue(rig.session.marks.isEmpty)
        for _ in 0..<5 { rig.refresh() }
        XCTAssertTrue(rig.scenes.first === entrance)
        let point = try rig.point(0)
        XCTAssertTrue(rig.board.hitTest(point, with: nil) === rig.board)
        XCTAssertEqual(rig.board.gestureRecognizers?.count, 3)
        rig.board.beginCellPress(at: point)
        XCTAssertTrue(rig.scenes.isEmpty); XCTAssertTrue(animations(entrance.layer).isEmpty)
        XCTAssertTrue(rig.session.marks.isEmpty, "Cancelling decoration does not itself perform a move")
        rig.board.endCellPress(); rig.board.activate(index: 0, submit: false)
        XCTAssertEqual(rig.session.marks, [0]); XCTAssertEqual(rig.actionCount, 1)
        rig.entranceID = nil; rig.refresh(); rig.entranceID = event; rig.refresh()
        XCTAssertTrue(rig.scenes.isEmpty)
        rig.entranceID = UUID(); rig.refresh()
        XCTAssertEqual(rig.scenes.count, 1)
        rig.board.activate(index: 0, submit: false)
        XCTAssertTrue(rig.scenes.isEmpty); XCTAssertTrue(rig.session.marks.isEmpty)
    }

    @MainActor func testCoveredBackgroundAndPowerChangesCancelEntranceWithoutReplay() throws {
        let rig = try BoardSceneRig(entranceID: UUID()); defer { rig.close() }
        let first = try XCTUnwrap(rig.scenes.first)
        rig.hidden = true; rig.refresh()
        XCTAssertTrue(rig.scenes.isEmpty); XCTAssertTrue(animations(first.layer).isEmpty)
        rig.hidden = false; rig.refresh(); XCTAssertTrue(rig.scenes.isEmpty)
        rig.effectsEnabled = false; rig.entranceID = UUID(); rig.refresh()
        rig.effectsEnabled = true; rig.refresh(); XCTAssertTrue(rig.scenes.isEmpty, "Covered events are consumed rather than deferred")
        rig.entranceID = UUID(); rig.refresh(); XCTAssertEqual(rig.scenes.count, 1)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(rig.scenes.isEmpty)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        rig.refresh(); XCTAssertTrue(rig.scenes.isEmpty)
        rig.entranceID = UUID(); rig.refresh(); XCTAssertEqual(rig.scenes.count, 1)
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertTrue(rig.scenes.isEmpty); rig.refresh(); XCTAssertTrue(rig.scenes.isEmpty)
        rig.entranceID = UUID(); rig.refresh()
        rig.board.removeFromSuperview(); XCTAssertTrue(rig.scenes.isEmpty)
    }

    @MainActor func testRealCompletionCelebratesOnceEvenWithResultLockAndKeepsFinalCellFeedback() async throws {
        var saved = GameSession(puzzle: BoardSceneRig.puzzle)
        for index in [1, 7, 8] { _ = saved.submit(cell: index) }
        let rig = try BoardSceneRig(session: saved); defer { rig.close() }
        XCTAssertTrue(rig.scenes.isEmpty)
        rig.board.activate(index: 14, submit: true)
        XCTAssertEqual(rig.session.status, .won)
        let celebration = try XCTUnwrap(rig.scenes.first)
        XCTAssertEqual(celebration.kind, .victory); XCTAssertEqual(celebration.duration, 0.78)
        let overlay = try XCTUnwrap(celebration.superview)
        let found = try XCTUnwrap(overlay.subviews.compactMap { $0 as? BoardCellFeedbackView }.first { $0.cellIndex == 14 })
        XCTAssertLessThan(try XCTUnwrap(overlay.subviews.firstIndex(of: celebration)), try XCTUnwrap(overlay.subviews.firstIndex(of: found)))
        let hearts = (celebration.layer.sublayers ?? []).filter { $0.name?.hasPrefix("victory-heart-") == true }
        XCTAssertEqual(Set(hearts.compactMap(\.name)), Set(rig.session.found.map { "victory-heart-\($0)" }))
        let lastHeart = try XCTUnwrap(hearts.first { $0.name == "victory-heart-14" })
        let start = try XCTUnwrap(celebration.layer.sublayers?.first { $0.name == "victory-board-warmth" }?.animation(forKey: "scene-opacity")).beginTime
        let lastHeartStart = try XCTUnwrap(lastHeart.animation(forKey: "scene-opacity")).beginTime
        XCTAssertGreaterThanOrEqual(lastHeartStart - start, found.duration, "The final animal cannot show both its local and scene hearts together.")
        rig.refresh(); XCTAssertTrue(rig.scenes.first === celebration)
        let committed = rig.session
        try await Task.sleep(nanoseconds: 850_000_000)
        XCTAssertTrue(rig.scenes.isEmpty); XCTAssertTrue(animations(celebration.layer).isEmpty)
        rig.refresh(); XCTAssertTrue(rig.scenes.isEmpty); XCTAssertEqual(rig.session, committed)
    }

    @MainActor func testRapidFinalTwoFindsHandEarlierExpressionToVictoryWithoutRestartingItsPop() async throws {
        // Exercise both an unfinished pop and a pop already in its expression
        // tail. These are separate real submissions, not a fabricated overlay.
        for delay in [UInt64(120_000_000), UInt64(440_000_000)] {
            var saved = GameSession(puzzle: BoardSceneRig.puzzle)
            for index in [1, 7] { _ = saved.submit(cell: index) }
            let rig = try BoardSceneRig(session: saved); defer { rig.close() }
            rig.board.activate(index: 8, submit: true)
            let earlier = try XCTUnwrap(rig.board.subviews.flatMap(\.subviews)
                .compactMap { $0 as? BoardCellFeedbackView }.first { $0.cellIndex == 8 })
            let oldFace = try XCTUnwrap(earlier.layer.sublayers?.first { $0.name == "found-face-happy" })
            let oldPop = try XCTUnwrap(oldFace.animation(forKey: "found-pop"))
            XCTAssertNotNil(oldFace.animation(forKey: "found-expression-settle"))
            try await Task.sleep(nanoseconds: delay)
            XCTAssertNotNil(earlier.superview)
            rig.board.activate(index: 14, submit: true)
            let committed = rig.session
            XCTAssertEqual(committed.status, .won)
            let celebration = try XCTUnwrap(rig.scenes.first)
            let overlay = try XCTUnwrap(celebration.superview)
            let finishing = try XCTUnwrap(overlay.subviews.compactMap { $0 as? BoardCellFeedbackView }.first { $0.cellIndex == 14 })
            XCTAssertEqual(finishing.duration, 0.32)
            let newFace = try XCTUnwrap(finishing.layer.sublayers?.first { $0.name == "found-face-happy" })
            XCTAssertNil(newFace.animation(forKey: "found-expression-settle"), "The winning cell hands off directly to the scene's happy face.")
            XCTAssertNil(oldFace.animation(forKey: "found-expression-settle"), "An earlier late blink must not cover the victory cheer.")
            if delay < 320_000_000 {
                XCTAssertNotNil(earlier.superview, "An unfinished accepted pop may finish at its original deadline.")
                XCTAssertEqual(oldFace.animation(forKey: "found-pop")?.beginTime, oldPop.beginTime)
                XCTAssertEqual(oldFace.animation(forKey: "found-pop")?.duration, oldPop.duration)
                XCTAssertTrue((try XCTUnwrap(oldFace.contents) as AnyObject) === CapyExpressionArtwork.image(.happy)?.cgImage)
                try await Task.sleep(nanoseconds: 245_000_000)
                XCTAssertNil(earlier.superview, "The old pop must finish from its original start, not 0.32s after the last find.")
            } else {
                XCTAssertNil(earlier.superview, "A completed pop relinquishes its entire settling cover immediately.")
                XCTAssertTrue(animations(earlier.layer).isEmpty)
            }
            XCTAssertNotNil(celebration.superview)
            capture(rig.window, "board-victory-earlier-expression-handoff-\(delay / 1_000_000)ms")
            rig.refresh()
            XCTAssertEqual(rig.session, committed); XCTAssertTrue(rig.scenes.first === celebration)
            try await Task.sleep(nanoseconds: 850_000_000)
            XCTAssertTrue(rig.scenes.isEmpty)
            XCTAssertFalse(overlay.subviews.contains { $0 is BoardCellFeedbackView })
            XCTAssertTrue(animations(earlier.layer).isEmpty); XCTAssertTrue(animations(finishing.layer).isEmpty)
            XCTAssertEqual(rig.session, committed)
        }
    }

    @MainActor func testCompletedRestoreAndHiddenCompletionDoNotReplayOnResumeOrNextSession() throws {
        var won = GameSession(puzzle: BoardSceneRig.puzzle)
        for index in [1, 7, 8, 14] { _ = won.submit(cell: index) }
        let restored = try BoardSceneRig(session: won); defer { restored.close() }
        XCTAssertTrue(restored.scenes.isEmpty)
        var almost = GameSession(puzzle: BoardSceneRig.puzzle)
        for index in [1, 7, 8] { _ = almost.submit(cell: index) }
        restored.session = almost; restored.refresh()
        restored.effectsEnabled = false; restored.refresh()
        _ = restored.session.submit(cell: 14); restored.refresh()
        restored.effectsEnabled = true; restored.refresh(); XCTAssertTrue(restored.scenes.isEmpty)
        restored.session = GameSession(puzzle: BoardSceneRig.puzzle); restored.refresh()
        XCTAssertTrue(restored.scenes.isEmpty)
        // Exercise the same fresh completion through each cancellation boundary;
        // a removed scene must take its delayed hearts with it.
        for gate in 0..<5 {
            var near = GameSession(puzzle: BoardSceneRig.puzzle)
            for index in [1, 7, 8] { _ = near.submit(cell: index) }
            restored.session = near; restored.refresh()
            restored.board.activate(index: 14, submit: true)
            let effect = try XCTUnwrap(restored.scenes.first)
            XCTAssertEqual((effect.layer.sublayers ?? []).filter { $0.name?.hasPrefix("victory-heart-") == true }.count, 4)
            switch gate {
            case 0: restored.effectsEnabled = false; restored.refresh()
            case 1: NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            case 2: restored.session = GameSession(puzzle: BoardSceneRig.puzzle); restored.refresh()
            case 3: restored.board.removeFromSuperview()
            default: restored.preview = [0]; restored.refresh()
            }
            XCTAssertNil(effect.superview); XCTAssertTrue(animations(effect.layer).isEmpty)
            restored.effectsEnabled = true; restored.preview = []
            if gate == 1 { NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
            if gate == 3 { restored.window.rootViewController?.view.addSubview(restored.board); restored.board.layoutIfNeeded() }
            restored.refresh(); XCTAssertTrue(restored.scenes.isEmpty, "Resuming cannot replay an old heart celebration.")
        }
    }

    @MainActor func testFourThroughTenCellBoardsHaveBoundedFiniteStaggerAndParticles() throws {
        for size in 4...10 {
            for side in [CGFloat(190), CGFloat(340)] {
                let frame = CGRect(x: 0, y: 0, width: side, height: side), board = frame.insetBy(dx: 7, dy: 7)
                // Shape-only drawing fixture; these row regions are not a playable level.
                let regions = (0..<(size * size)).map { $0 / size }
                for kind in [BoardSceneFeedbackView.Kind.entrance, .victory] {
                    // Shift through every column, so every possible cell, including
                    // the four corners, is exercised at both compact and large sizes.
                    for shift in 0..<(kind == .victory ? size : 1) {
                        let found = Set((0..<size).map { $0 * size + ($0 * 2 + shift) % size })
                        let scene = BoardSceneFeedbackView(kind: kind, frame: frame, boardRect: board, size: size,
                            regions: regions, found: found, finishingCells: [found.max()!], reduceMotion: false, lowPower: false)
                        let host = UIView(frame: frame); host.addSubview(scene); scene.play()
                        XCTAssertFalse(scene.isUserInteractionEnabled); XCTAssertTrue(scene.accessibilityElementsHidden)
                        XCTAssertTrue(scene.tileFrames.allSatisfy { board.contains($0) })
                        XCTAssertLessThanOrEqual(scene.particleCount, size * 2)
                        for star in (scene.layer.sublayers ?? []).filter({ $0.name?.hasPrefix("victory-star-") == true }) {
                            XCTAssertTrue(board.contains(star.frame))
                        }
                        XCTAssertTrue(animations(scene.layer).allSatisfy { $0.repeatCount == 0 && !$0.autoreverses && $0.duration <= scene.duration })
                        if kind == .victory {
                            let hearts = (scene.layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
                                .filter { $0.name?.hasPrefix("victory-heart-") == true }
                            XCTAssertEqual(hearts.count, found.count)
                            let start = try XCTUnwrap(scene.layer.sublayers?.first { $0.name == "victory-board-warmth" }?.animation(forKey: "scene-opacity")).beginTime
                            for index in found {
                                let heart = try XCTUnwrap(hearts.first { $0.name == "victory-heart-\(index)" })
                                let tile = scene.tileFrames[index]
                                let lift = try XCTUnwrap(heart.animation(forKey: "scene-transform.translation.y") as? CAKeyframeAnimation)
                                let scale = try XCTUnwrap(heart.animation(forKey: "scene-transform.scale") as? CAKeyframeAnimation)
                                let peakScale = try XCTUnwrap((scale.values as? [NSNumber])?.map(\.doubleValue).max())
                                let radius = (heart.bounds.width + heart.lineWidth) * CGFloat(peakScale) / 2
                                let ends = try XCTUnwrap(lift.values as? [NSNumber])
                                for dy in ends {
                                    let extent = CGRect(x: heart.position.x - radius, y: heart.position.y + CGFloat(dy.doubleValue) - radius,
                                                        width: radius * 2, height: radius * 2)
                                    XCTAssertTrue(tile.contains(extent)); XCTAssertTrue(board.contains(extent))
                                    XCTAssertLessThanOrEqual(extent.maxY, tile.minY + tile.height * 0.34,
                                                            "Keep hearts in the upper strip, above the face's main eye/mouth area.")
                                }
                                XCTAssertEqual(heart.opacity, 0); XCTAssertNotNil(heart.path)
                                XCTAssertEqual(heart.fillColor, UIColor(CapyPalette.regionColors[9]).cgColor)
                                let face = try XCTUnwrap(scene.layer.sublayers?.first { $0.name == "victory-animal-\(index)" }?.sublayers?.first)
                                XCTAssertEqual(lift.beginTime, try XCTUnwrap(face.animation(forKey: "scene-transform.scale")).beginTime, accuracy: 0.0001)
                                for animation in animations(heart) {
                                    XCTAssertLessThanOrEqual(animation.beginTime - start + animation.duration, scene.duration,
                                                            "Even the delayed final heart must end inside the existing scene window.")
                                }
                            }
                        }
                        if kind == .entrance {
                            let tiles = (scene.layer.sublayers ?? []).filter { $0.name?.hasPrefix("entrance-tile-") == true }
                            let first = try XCTUnwrap(tiles.first?.animation(forKey: "scene-transform.scale"))
                            let last = try XCTUnwrap(tiles.last?.animation(forKey: "scene-transform.scale"))
                            XCTAssertEqual(last.beginTime - first.beginTime, 0.24, accuracy: 0.0001)
                            XCTAssertLessThanOrEqual(last.beginTime - first.beginTime + last.duration, scene.duration)
                        }
                        scene.removeFromSuperview(); XCTAssertTrue(animations(scene.layer).isEmpty)
                    }
                }
            }
        }
    }

    @MainActor func testReduceMotionAndLowPowerUseOnlyShortStaticOutline() async throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        var effects = [BoardSceneFeedbackView]()
        for policy in [(true, false), (false, true)] {
            for kind in [BoardSceneFeedbackView.Kind.entrance, .victory] {
                let effect = BoardSceneFeedbackView(kind: kind, frame: host.bounds, boardRect: host.bounds.insetBy(dx: 7, dy: 7),
                    size: 4, regions: BoardSceneRig.puzzle.regions, found: [1, 7, 8, 14],
                    reduceMotion: policy.0, lowPower: policy.1)
                host.addSubview(effect); effect.play(); effects.append(effect)
                XCTAssertTrue(effect.simplified); XCTAssertEqual(effect.duration, 0.18)
                XCTAssertEqual(effect.particleCount, 0); XCTAssertTrue(animations(effect.layer).isEmpty)
                XCTAssertEqual(effect.layer.sublayers?.map(\.name), ["scene-static-outline"])
            }
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(effects.allSatisfy { $0.superview == nil })
    }

    @MainActor func testActualHostShowsEntranceWaveAndVisibleWinSequenceWithoutChangingCommittedState() async throws {
        let rig = try BoardSceneRig(entranceID: UUID()); defer { rig.close() }
        let initial = rig.session
        try await Task.sleep(nanoseconds: 90_000_000)
        capture(rig.window, "board-entrance-090ms-leading-tiles")
        try await Task.sleep(nanoseconds: 210_000_000)
        capture(rig.window, "board-entrance-300ms-following-tiles")
        try await Task.sleep(nanoseconds: 320_000_000)
        XCTAssertTrue(rig.scenes.isEmpty); XCTAssertEqual(rig.session, initial)
        for index in [1, 7, 8, 14] { rig.board.activate(index: index, submit: true) }
        let committed = rig.session
        try await Task.sleep(nanoseconds: 140_000_000)
        capture(rig.window, "board-victory-140ms-warmth-and-first-cheers")
        try await Task.sleep(nanoseconds: 360_000_000)
        capture(rig.window, "board-victory-500ms-last-animal-cheer")
        try await Task.sleep(nanoseconds: 350_000_000)
        capture(rig.window, "board-victory-850ms-settled")
        XCTAssertTrue(rig.scenes.isEmpty); XCTAssertEqual(rig.session, committed)
    }

    @MainActor func testCurrentPackVictoryHeartsUseNaturalPlaybackAtSixAndTenCells() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "levels", withExtension: "json"))
        let levels = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
        // Unlike the row-region shape fixtures above, these are actual current
        // packaged levels, completed through the board's normal submission path.
        for size in [6, 10] {
            let puzzle = try XCTUnwrap(levels.first { $0.size == size })
            let finishingCell = try XCTUnwrap(puzzle.solution.last)
            var near = GameSession(puzzle: puzzle)
            for index in puzzle.solution.dropLast() { _ = near.submit(cell: index) }
            XCTAssertEqual(near.status, .playing); XCTAssertEqual(near.found.count, size - 1)
            let rig = try BoardSceneRig(session: near); defer { rig.close() }
            let width: CGFloat = size == 10 ? 190 : 320
            rig.board.frame = CGRect(x: 20, y: 150, width: width, height: width)
            rig.board.layoutIfNeeded(); rig.refresh()
            rig.board.activate(index: finishingCell, submit: true)
            let celebration = try XCTUnwrap(rig.scenes.first)
            XCTAssertNotNil(celebration.window)
            XCTAssertEqual(rig.session.status, .won)
            let committed = rig.session
            // Natural wall-clock playback in a visible UIWindow, with no layer
            // timeOffset/speed manipulation. Capture names describe the stage;
            // the nominal waits are not claims of exact frame timestamps.
            try await Task.sleep(nanoseconds: 150_000_000)
            capture(rig.window, "board-current-pack-L\(puzzle.id)-\(size)x\(size)-hearts-early")
            try await Task.sleep(nanoseconds: 225_000_000)
            capture(rig.window, "board-current-pack-L\(puzzle.id)-\(size)x\(size)-hearts-finishing")
            try await Task.sleep(nanoseconds: 475_000_000)
            capture(rig.window, "board-current-pack-L\(puzzle.id)-\(size)x\(size)-hearts-settled")
            XCTAssertTrue(rig.scenes.isEmpty); XCTAssertTrue(animations(celebration.layer).isEmpty)
            XCTAssertEqual(rig.session, committed)
        }
    }
}
