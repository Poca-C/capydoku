import XCTest
import UIKit
@testable import Capydoku

@MainActor private final class MistakePresentationRig {
    let window: UIWindow
    let previousWindow: UIWindow?
    let board: PuzzleGridUIView
    let sessionID = UUID()
    let size: Int
    let reduceMotion: Bool

    init(size: Int = 4, side: CGFloat = 340, reduceMotion: Bool = false) throws {
        self.size = size; self.reduceMotion = reduceMotion
        board = PuzzleGridUIView(frame: CGRect(x: 20, y: 170, width: side, height: side))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.addSubview(board); configure(error: false); board.layoutIfNeeded()
    }

    func configure(error: Bool) {
        // A drawing fixture, not a generated or accepted gameplay puzzle.
        board.configure(size: size, regions: (0..<(size * size)).map { $0 / size },
            found: [], marks: error ? [0] : [], errors: error ? [0] : [], preview: [],
            sessionID: sessionID, lives: error ? 2 : 3, reduceMotion: reduceMotion,
            tutorialTargets: [], locked: false,
            onToggle: { _ in }, onSubmit: { _ in }, onMark: { _ in })
    }

    func mistake() throws -> BoardMistakeFeedbackView {
        configure(error: true)
        return try XCTUnwrap(board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardMistakeFeedbackView }.first)
    }

    func close() {
        board.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
        previousWindow?.makeKeyAndVisible()
    }
}

private struct MistakeImagePixels {
    let bytes: [UInt8]
    init(_ image: UIImage) throws {
        let source = try XCTUnwrap(image.cgImage)
        var data = [UInt8](repeating: 0, count: source.width * source.height * 4)
        let drawn = data.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            return true
        }
        XCTAssertTrue(drawn); bytes = data
    }

    func mask(matching color: UIColor) -> [Bool] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let target = [r, g, b].map { Int(($0 * 255).rounded()) }
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            (0..<3).allSatisfy { abs(Int(bytes[offset + $0]) - target[$0]) <= 12 }
        }
    }
}

final class BoardMistakePresentationTests: XCTestCase {
    @MainActor private func renderModel(_ view: UIView, crop: CGRect? = nil) -> UIImage {
        let rect = crop ?? view.bounds
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        view.layer.displayIfNeeded()
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            view.layer.render(in: context.cgContext)
        }
    }

    @MainActor private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func cropPixels(_ image: UIImage, to rect: CGRect) throws -> UIImage {
        // Crop an already-rendered board on integral pixels. Translating its
        // bitmap by a fractional crop origin would resample its antialiasing.
        let pixelRect = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
            width: rect.width * image.scale, height: rect.height * image.scale).integral
        let cropped = try XCTUnwrap(image.cgImage?.cropping(to: pixelRect))
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    @MainActor private func captureLive(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            (view.layer.presentation() ?? view.layer).render(in: context.cgContext)
        }
        attach(image, name: name)
    }

    @MainActor private func layers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(layers)
    }

    @MainActor func testBriefShakeKeepsOpaqueCoverAndBoardHitGeometryFixed() async throws {
        let rig = try MistakePresentationRig(); defer { rig.close() }
        let cell = try XCTUnwrap(rig.board.accessibilityElements?.first as? UIAccessibilityElement)
        let cellFrame = cell.accessibilityFrameInContainerSpace, boardFrame = rig.board.frame
        let effect = try rig.mistake(), coverFrame = effect.frame
        let contentShake = try XCTUnwrap(layers(effect.layer).compactMap {
            $0.animation(forKey: "transform.translation.x") as? CAKeyframeAnimation
        }.first)
        let values = try XCTUnwrap(contentShake.values as? [NSNumber]).map(\.doubleValue)
        XCTAssertTrue(values.contains { $0 < 0 }); XCTAssertTrue(values.contains { $0 > 0 })
        XCTAssertEqual(values.first, 0); XCTAssertEqual(values.last, 0)
        XCTAssertLessThanOrEqual(values.map(abs).max() ?? 0, 2.4)
        XCTAssertEqual(contentShake.duration, 0.78, accuracy: 0.001)
        XCTAssertNil(effect.layer.animation(forKey: "transform.translation.x"), "The opaque tile stays fixed so its committed underlying X cannot flash at the edge.")
        XCTAssertEqual(effect.backgroundColor?.cgColor.alpha, 1)
        XCTAssertFalse(effect.isUserInteractionEnabled); XCTAssertTrue(effect.accessibilityElementsHidden)
        let point = CGPoint(x: cellFrame.midX, y: cellFrame.midY)
        XCTAssertTrue(rig.board.hitTest(point, with: nil) === rig.board)
        try await Task.sleep(nanoseconds: 60_000_000)
        captureLive(rig.window, name: "mistake-cell-early-shake-fixed-cover")
        XCTAssertEqual(effect.frame, coverFrame); XCTAssertTrue(CATransform3DIsIdentity(effect.layer.transform))
        XCTAssertEqual(rig.board.frame, boardFrame); XCTAssertEqual(cell.accessibilityFrameInContainerSpace, cellFrame)
        try await Task.sleep(nanoseconds: 220_000_000)
        captureLive(rig.window, name: "mistake-cell-shake-settled-heart")
        try await Task.sleep(nanoseconds: 580_000_000)
        XCTAssertNil(effect.superview)
        XCTAssertEqual(cell.accessibilityValue, "error")
    }

    @MainActor func testTransitionRedCrossMatchesActualBoardAtSmallAndLargeCellSizes() throws {
        for (size, side) in [(4, CGFloat(340)), (10, CGFloat(190)), (10, CGFloat(340))] {
            let rig = try MistakePresentationRig(size: size, side: side); defer { rig.close() }
            let effect = try rig.mistake()
            // Compare the same board coordinate system and identical integral
            // pixels before/after removing its cover. The 10x10 tile starts at
            // 8.1pt; rendering an isolated effect at 0pt then translating the
            // board's raster by 9.1pt gives different sampling phases at 3x.
            // These are settled model layers, not a live-frame timing claim.
            let local = effect.bounds.insetBy(dx: 1, dy: 1)
            let boardCrop = effect.convert(local, to: rig.board)
            let transient = try cropPixels(renderModel(rig.board), to: boardCrop)
            effect.removeFromSuperview()
            let settled = try cropPixels(renderModel(rig.board), to: boardCrop)
            let first = try MistakeImagePixels(transient), last = try MistakeImagePixels(settled)
            for (name, color) in [("outline", UIColor(CapyPalette.markOutline)), ("red", UIColor(CapyPalette.life))] {
                let before = first.mask(matching: color).filter { $0 }.count
                let after = last.mask(matching: color).filter { $0 }.count
                XCTAssertGreaterThan(after, 8, "The actual board must contain a readable \(name) stroke.")
                XCTAssertEqual(Double(before), Double(after), accuracy: max(12, Double(after) * 0.18),
                    "\(size)x\(size), \(side)pt: the transition \(name) stroke must retain the final board's visual weight.")
            }
            attach(transient, name: "mistake-transition-red-x-\(size)-\(Int(side))")
            attach(settled, name: "mistake-board-red-x-\(size)-\(Int(side))")
        }
    }

    @MainActor func testReducedMotionUsesDistinctStaticHeartAndXWithoutAnyShake() async throws {
        let rig = try MistakePresentationRig(reduceMotion: true); defer { rig.close() }
        let effect = try rig.mistake()
        XCTAssertTrue(layers(effect.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        let heart = renderModel(effect)
        attach(heart, name: "mistake-reduced-static-split-heart")
        try await Task.sleep(nanoseconds: 440_000_000)
        XCTAssertNotNil(effect.superview)
        XCTAssertTrue(layers(effect.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        let cross = renderModel(effect)
        attach(cross, name: "mistake-reduced-static-outlined-x")
        let heartMask = try MistakeImagePixels(heart).mask(matching: UIColor(CapyPalette.life))
        let crossMask = try MistakeImagePixels(cross).mask(matching: UIColor(CapyPalette.life))
        XCTAssertEqual(heartMask.count, crossMask.count)
        let shapeChanges = zip(heartMask, crossMask).filter { pair in pair.0 != pair.1 }.count
        XCTAssertGreaterThan(shapeChanges, heartMask.count / 30,
            "Meaning changes through the red symbol's geometry, not only its color.")
        try await Task.sleep(nanoseconds: 420_000_000)
        XCTAssertNil(effect.superview)
        XCTAssertEqual((rig.board.accessibilityElements?.first as? UIAccessibilityElement)?.accessibilityValue, "error")
    }
}
