import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class DirectToolRootMeasurements {
    var frames: [String: CGRect] = [:]
}

private struct DirectToolRootHarness: View {
    @ObservedObject var model: AppModel
    let reduced: Bool
    let observe: (String, CGRect) -> Void
    var body: some View {
        RootView(reduceMotionOverride: reduced).environmentObject(model)
            .environment(\.scenePhase, .active)
            .environment(\.capyLayoutObserver, observe)
    }
}

@MainActor private final class DirectToolRootRig {
    let directory: URL
    let model: AppModel
    let measurements = DirectToolRootMeasurements()
    let host: UIHostingController<DirectToolRootHarness>
    let window: UIWindow
    let previous: UIWindow?

    init(level: Int, width: CGFloat, reduced: Bool, remaining: Int) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("direct-root-" + UUID().uuidString)
        model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true
        model.start(level: level)
        let puzzle = try XCTUnwrap(model.session).puzzle
        for cell in puzzle.solution.dropLast(remaining) { model.submit(cell) }
        // Keep real existing exclusions on the board, so a tool cannot silently
        // remove them or introduce additional marks around its revealed animal.
        for cell in puzzle.regions.indices.filter({ !puzzle.solution.contains($0) }).prefix(3) {
            model.toggle(cell)
        }
        let measured = measurements
        host = UIHostingController(rootView: DirectToolRootHarness(model: model, reduced: reduced,
            observe: { measured.frames[$0] = $1 }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: width == 320 ? 568 : 874)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true; window.rootViewController = nil
        previous?.makeKeyAndVisible()
        model.flushPendingSaves()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// These fixtures invoke the real current-pack tool transaction and Root board
/// callbacks. Captures use the running presentation clock; no layer is paused,
/// no animation is removed, and no synthetic timestamp manufactures a frame.
final class DirectToolRevealVisualTests: XCTestCase {
    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor private func board(in rig: DirectToolRootRig) throws -> PuzzleGridUIView {
        try XCTUnwrap(descendants(rig.host.view).compactMap { $0 as? PuzzleGridUIView }.first)
    }

    @MainActor private func effects(in rig: DirectToolRootRig) -> [DirectToolRevealUIView] {
        descendants(rig.host.view).compactMap { $0 as? DirectToolRevealUIView }
    }

    @MainActor private func capture(_ rig: DirectToolRootRig, _ name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = rig.window.screen.scale; format.preferredRange = .standard
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: rig.window.bounds, format: format).image { _ in
            drawn = rig.window.drawHierarchy(in: rig.window.bounds, afterScreenUpdates: false)
        }
        XCTAssertTrue(drawn, "The actual Root window must produce a usable capture.")
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return bytes
    }

    @MainActor private func assertToolInkAvoidsOccupiedTiles(_ rig: DirectToolRootRig,
                                                            name: String) throws {
        let board = try board(in: rig)
        let effect = try XCTUnwrap(effects(in: rig).first, "The test must inspect the actual Root tool receipt.")
        XCTAssertFalse(effect.isUserInteractionEnabled)
        let session = try XCTUnwrap(rig.model.session)
        let scale = rig.window.screen.scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale; format.opaque = false; format.preferredRange = .standard
        // Only this existing decoration is rendered onto transparency. This
        // excludes normal board artwork, pop/ring, floating scores and tint,
        // so none of those legitimate pixels can be misreported as tool ink.
        let liveLayer = effect.layer.presentation() ?? effect.layer
        let image = UIGraphicsImageRenderer(bounds: effect.bounds, format: format).image {
            liveLayer.render(in: $0.cgContext)
        }
        let bitmap = try XCTUnwrap(image.cgImage)
        let allBytes = try rgba(bitmap)
        let opaquePixels = stride(from: 3, to: allBytes.count, by: 4).filter { allBytes[$0] > 0 }.count
        XCTAssertGreaterThan(opaquePixels, 0, "Hiding the whole confirmation is not a valid protection fix.")
        let attachment = XCTAttachment(image: image)
        attachment.name = name + "-actual-tool-layer"
        attachment.lifetime = .keepAlways; add(attachment)
        var diagnostics: [[String: Any]] = []
        for index in session.found.union(session.marks).union(session.errors).sorted() {
            let element = try XCTUnwrap(board.accessibilityElements?[index] as? UIAccessibilityElement)
            let cell = effect.convert(element.accessibilityFrameInContainerSpace, from: board)
            let gap = max(1.1, min(2, cell.width * 0.028))
            // Compare only complete native pixels inside the painted tile.
            // One pixel at its border belongs to mask antialiasing; the face
            // and X are farther inside and remain covered by this assertion.
            let tile = cell.insetBy(dx: gap + 1 / scale, dy: gap + 1 / scale)
            let minX = ceil(tile.minX * scale), minY = ceil(tile.minY * scale)
            let crop = CGRect(x: minX, y: minY,
                width: max(0, floor(tile.maxX * scale) - minX),
                height: max(0, floor(tile.maxY * scale) - minY))
            XCTAssertGreaterThan(crop.width, 0); XCTAssertGreaterThan(crop.height, 0)
            let pixels = try rgba(try XCTUnwrap(bitmap.cropping(to: crop)))
            let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
            let covered = alpha.filter { $0 > 0 }.count
            XCTAssertEqual(covered, 0, "\(name) cell \(index): tool ink must not cross a visible portrait or X.")
            diagnostics.append(["cell": index, "paintedTile": [tile.minX, tile.minY, tile.width, tile.height],
                "coveredPixels": covered, "maximumAlpha": Int(alpha.max() ?? 0)])
        }
        let data = try JSONSerialization.data(withJSONObject: ["scale": scale, "visibleToolPixels": opaquePixels,
            "occupiedTiles": diagnostics], options: [.prettyPrinted, .sortedKeys])
        let diagnostic = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        diagnostic.name = name + "-pixel-coverage"; diagnostic.lifetime = .keepAlways; add(diagnostic)
    }

    @MainActor func testActualRootDirectReceiptProtectsCurrentPackFacesAndAcceptsImmediateMoves() async throws {
        // Root is hosted below the app's loading gate. Run the same bundled
        // preparation that real startup finishes before accepting gameplay.
        try await BundledStartupResources().prepare()
        for (level, width) in [(6, CGFloat(402)), (63, CGFloat(320)), (101, CGFloat(320))] {
            for reduced in [false, true] {
                let rig = try DirectToolRootRig(level: level, width: width, reduced: reduced, remaining: 3)
                defer { rig.close() }
                try await Task.sleep(nanoseconds: 620_000_000)
                let before = try XCTUnwrap(rig.model.session), inventory = rig.model.progress.availableDirect
                XCTAssertGreaterThan(inventory, 0)
                let nativeBoard = try board(in: rig)
                rig.model.direct()
                let accepted = try XCTUnwrap(rig.model.session)
                let receipt = try XCTUnwrap(rig.model.directRevealFeedback)
                XCTAssertEqual(accepted.id, before.id); XCTAssertEqual(accepted.status, .playing)
                XCTAssertEqual(accepted.found.subtracting(before.found), [receipt.cell])
                XCTAssertEqual(rig.model.progress.availableDirect, inventory - 1)
                XCTAssertEqual(accepted.marks, before.marks, "Direct answer must not auto-fill surrounding X marks.")
                XCTAssertEqual(accepted.errors, before.errors); XCTAssertEqual(accepted.lives, before.lives)
                XCTAssertGreaterThan(accepted.score, before.score)
                let name = "direct-root-L\(level)-\(Int(width))-reduced-\(reduced)"
                try await Task.sleep(nanoseconds: 120_000_000)
                capture(rig, name + "-natural-120ms")
                try assertToolInkAvoidsOccupiedTiles(rig, name: name + "-initial")
                XCTAssertEqual(rig.model.session, accepted)

                let mark = try XCTUnwrap(accepted.puzzle.regions.indices.first {
                    !accepted.puzzle.solution.contains($0) && !accepted.marks.contains($0)
                })
                XCTAssertTrue(nativeBoard.activate(index: mark, submit: false))
                XCTAssertTrue(try XCTUnwrap(rig.model.session).marks.contains(mark), "Tool decoration cannot delay a real mark.")
                // Let Root receive the newly occupied cell while the same tool
                // effect is still alive, then verify its updated clipping too.
                try await Task.sleep(nanoseconds: 40_000_000)
                try assertToolInkAvoidsOccupiedTiles(rig, name: name + "-new-mark")
                XCTAssertTrue(nativeBoard.activate(index: mark, submit: false))
                XCTAssertEqual(rig.model.session?.marks, accepted.marks)
                let nextAnimal = try XCTUnwrap(accepted.puzzle.solution.first { !accepted.found.contains($0) })
                XCTAssertTrue(nativeBoard.activate(index: nextAnimal, submit: true))
                let continued = try XCTUnwrap(rig.model.session)
                XCTAssertEqual(continued.found, accepted.found.union([nextAnimal]))
                XCTAssertEqual(continued.status, .playing); XCTAssertEqual(continued.lives, before.lives)
                XCTAssertEqual(continued.marks, accepted.marks)
                XCTAssertEqual(rig.model.progress.availableDirect, inventory - 1)
                capture(rig, name + "-immediate-continued-state")

                try await Task.sleep(nanoseconds: 760_000_000)
                XCTAssertTrue(effects(in: rig).isEmpty, "The finite receipt must leave no live Root decoration.")
                XCTAssertEqual(rig.model.session, continued)
                XCTAssertEqual(rig.model.session?.puzzle, before.puzzle)
            }
        }
    }

    @MainActor func testActualRootFinalDirectCommitsWinAndImmediateNextClearsItsReceipt() async throws {
        try await BundledStartupResources().prepare()
        for (level, width) in [(6, CGFloat(402)), (63, CGFloat(320)), (101, CGFloat(320))] {
            for reduced in [false, true] {
                let rig = try DirectToolRootRig(level: level, width: width, reduced: reduced, remaining: 1)
                defer { rig.close() }
                try await Task.sleep(nanoseconds: 620_000_000)
                let before = try XCTUnwrap(rig.model.session), inventory = rig.model.progress.availableDirect
                XCTAssertGreaterThan(inventory, 0)
                rig.model.direct()
                let won = try XCTUnwrap(rig.model.session)
                XCTAssertEqual(won.status, .won); XCTAssertEqual(won.found.count, won.puzzle.size)
                XCTAssertEqual(won.marks, before.marks); XCTAssertEqual(won.lives, before.lives)
                XCTAssertEqual(rig.model.progress.availableDirect, inventory - 1)
                let name = "direct-final-L\(level)-\(Int(width))-reduced-\(reduced)"
                try await Task.sleep(nanoseconds: 120_000_000)
                XCTAssertNotNil(rig.measurements.frames["result_primary_action"], "Next remains available before tool decoration expires.")
                if !reduced { XCTAssertFalse(effects(in: rig).isEmpty, name + ": final tool receipt must reach the board.") }
                capture(rig, name + "-win-before-receipt-expiry")
                rig.model.next()
                let next = try XCTUnwrap(rig.model.session)
                XCTAssertNotEqual(next.id, won.id); XCTAssertEqual(next.puzzle.id, level + 1)
                XCTAssertEqual(next.status, .playing); XCTAssertTrue(next.found.isEmpty)
                XCTAssertEqual(next.score, 0); XCTAssertNil(rig.model.directRevealFeedback)
                try await Task.sleep(nanoseconds: 120_000_000)
                XCTAssertTrue(effects(in: rig).isEmpty, "The old tool cannot remain on the next level.")
                let nativeBoard = try board(in: rig)
                let mark = try XCTUnwrap(next.puzzle.regions.indices.first { !next.puzzle.solution.contains($0) })
                XCTAssertTrue(nativeBoard.activate(index: mark, submit: false))
                let playing = try XCTUnwrap(rig.model.session)
                XCTAssertEqual(playing.marks, [mark]); XCTAssertEqual(playing.score, 0)
                capture(rig, name + "-next-level-first-mark")
                try await Task.sleep(nanoseconds: 650_000_000)
                XCTAssertTrue(effects(in: rig).isEmpty, "Old cleanup/callback work cannot recreate a receipt in another session.")
                XCTAssertEqual(rig.model.session, playing)
            }
        }
    }

    @MainActor func testDirectReceiptRejectsInvalidGeometryWithoutPublishingAnEffect() {
        let sessionID = UUID()
        let cell = CGRect(x: 72, y: 104, width: 24, height: 24)
        let board = CGRect(x: 24, y: 56, width: 192, height: 192)
        let destination = CGPoint(x: cell.midX, y: cell.midY)
        let origin = CGPoint(x: 80, y: 280)
        let cases: [(String, CGRect, CGRect?)] = [
            ("infinite cell", .infinite, board),
            ("null cell", .null, board),
            ("NaN cell", CGRect(x: CGFloat.nan, y: 104, width: 24, height: 24), board),
            ("empty cell", CGRect(x: destination.x, y: destination.y, width: 0, height: 24), board),
            ("too small cell", CGRect(x: destination.x - 2, y: destination.y - 2, width: 4, height: 4), board),
            ("destination outside cell", cell.offsetBy(dx: 40, dy: 0), board),
            ("infinite board", cell, .infinite),
            ("null board", cell, .null),
            ("NaN board", cell, CGRect(x: 24, y: CGFloat.nan, width: 192, height: 192)),
            ("empty board", cell, CGRect(x: 24, y: 56, width: 0, height: 192)),
            ("board does not contain cell", cell, CGRect(x: 0, y: 0, width: 24, height: 24))
        ]
        for (name, source, area) in cases {
            let presentation = GameRewardPresentation()
            presentation.bind(sessionID: sessionID, score: 700)
            presentation.directReveal(.init(sessionID: sessionID, cell: 18), origin: origin,
                destination: destination, cellFrame: source, boardFrame: area, reduceMotion: true)
            XCTAssertNil(presentation.toolReveal, name)
        }
        let presentation = GameRewardPresentation()
        presentation.bind(sessionID: sessionID, score: 700)
        presentation.directReveal(.init(sessionID: sessionID, cell: 18), origin: origin,
            destination: destination, cellFrame: cell, boardFrame: board, reduceMotion: true)
        XCTAssertNotNil(presentation.toolReveal, "Rejecting invalid geometry must not suppress a valid receipt.")
        // A malformed size must be rejected before calculating size * size.
        for size in [0, -1, 3, 11, Int.max] {
            XCTAssertEqual(presentation.toolReveal?.occupiedCells([0, 18], size: size), [cell])
        }
    }

    @MainActor func testHostedReducedReceiptNearDuplicateTargetCannotReopenItsProtectedPixels() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 360)
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        window.rootViewController = controller; window.makeKeyAndVisible()
        let effect = DirectToolRevealUIView(frame: window.bounds)
        controller.view.addSubview(effect)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let cell = CGRect(x: 144.25, y: 152.5, width: 17.6, height: 17.6)
        let nearDuplicate = cell.offsetBy(dx: 1e-10, dy: -1e-10)
        XCTAssertNotEqual(cell, nearDuplicate, "The fixture must reproduce differing conversion/reconstruction results.")
        let reveal = GameRewardPresentation.ToolReveal(id: UUID(), origin: CGPoint(x: 72, y: 310),
            destination: CGPoint(x: cell.midX, y: cell.midY), cellFrame: cell,
            boardFrame: CGRect(x: 72.25, y: 72.5, width: 176, height: 176), reduceMotion: true)
        effect.configure(reveal: reveal, protectedCells: [nearDuplicate, nearDuplicate])
        effect.setNeedsLayout(); effect.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 30_000_000)
        let format = UIGraphicsImageRendererFormat()
        let scale = window.screen.scale
        format.scale = scale; format.opaque = false; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: effect.bounds, format: format).image { effect.layer.render(in: $0.cgContext) }
        let bitmap = try XCTUnwrap(image.cgImage)
        let allBytes = try rgba(bitmap)
        XCTAssertTrue(stride(from: 3, to: allBytes.count, by: 4).contains { allBytes[$0] > 0 },
            "The four corners must remain visible outside the protected target.")
        let tile = cell.insetBy(dx: 1.1 + 1 / scale, dy: 1.1 + 1 / scale)
        let x = ceil(tile.minX * scale), y = ceil(tile.minY * scale)
        let crop = CGRect(x: x, y: y, width: floor(tile.maxX * scale) - x, height: floor(tile.maxY * scale) - y)
        let pixels = try rgba(try XCTUnwrap(bitmap.cropping(to: crop)))
        XCTAssertFalse(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 },
            "Nearly coincident mask holes must not cancel through even-odd filling and expose tool ink in the target.")
        // In reduced motion the lens is intentionally absent. Also rasterize
        // the actual installed mask, so this test detects reopened interiors
        // even if a particular stationary corner does not reach those pixels.
        let mask = try XCTUnwrap(effect.layer.mask)
        let maskImage = UIGraphicsImageRenderer(bounds: effect.bounds, format: format).image { mask.render(in: $0.cgContext) }
        let maskBitmap = try XCTUnwrap(maskImage.cgImage)
        let maskPixels = try rgba(try XCTUnwrap(maskBitmap.cropping(to: crop)))
        XCTAssertFalse(stride(from: 3, to: maskPixels.count, by: 4).contains { maskPixels[$0] > 0 },
            "The actual mask itself must keep the complete target interior closed to tool drawing.")
        XCTAssertTrue((effect.layer.animationKeys() ?? []).isEmpty)
        XCTAssertTrue((effect.layer.sublayers ?? []).allSatisfy { ($0.animationKeys() ?? []).isEmpty },
            "Reduced motion is a stationary receipt, with no hidden flight or tracing animation.")
        let attachment = XCTAttachment(image: image)
        attachment.name = "direct-reduced-near-duplicate-target-native-pixels"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
