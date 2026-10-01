import XCTest
import UIKit
@testable import Capydoku

private struct ExpressionPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: UIImage) throws {
        let bitmap = try XCTUnwrap(image.cgImage)
        width = bitmap.width; height = bitmap.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: bitmap.width, height: bitmap.height,
                bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
            return true
        }
        XCTAssertTrue(drawn); bytes = data
    }

    func rgba(x: Int, y: Int) -> [UInt8] { Array(bytes[((y * width + x) * 4)..<((y * width + x) * 4 + 4)]) }

    var alphaBounds: CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 16 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

final class CapyExpressionTests: XCTestCase {
    @MainActor func testValidatedBuiltInBoundsAvoidScanningAndPreserveEveryRenderedPixel() throws {
        let lookup: (String) -> UIImage? = { UIImage(named: $0) }
        let optimized = CapyExpressionImageCache(contentBounds: CapyExpressionSheetMetrics.bounds, load: lookup)
        let reference = CapyExpressionImageCache(load: lookup)
        for expression in CapyFaceExpression.allCases {
            let actual = try ExpressionPixels(XCTUnwrap(optimized.image(for: expression)))
            let expected = try ExpressionPixels(XCTUnwrap(reference.image(for: expression)))
            XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
            XCTAssertTrue(actual.bytes == expected.bytes, "The optimization must not change even one rendered pixel for \(expression)")
        }
        XCTAssertEqual(optimized.alphaScanCount, 0)
        XCTAssertEqual(reference.alphaScanCount, 4)
    }

    @MainActor func testSameSizedReplacementCannotReuseStaleBuiltInBounds() throws {
        let replacement = image(size: CGSize(width: 1254, height: 1254)) { context in
            context.setFillColor(UIColor.blue.cgColor)
            context.fill(CGRect(x: 240, y: 230, width: 80, height: 60))
        }
        XCTAssertNil(CapyExpressionSheetMetrics.bounds(in: try XCTUnwrap(replacement.cgImage)))
        let lookup: (String) -> UIImage? = { $0 == "CapyFaceExpressions" ? replacement : nil }
        let optimized = CapyExpressionImageCache(contentBounds: CapyExpressionSheetMetrics.bounds, load: lookup)
        let reference = CapyExpressionImageCache(load: lookup)
        let actual = try ExpressionPixels(XCTUnwrap(optimized.image(for: .neutral)))
        let expected = try ExpressionPixels(XCTUnwrap(reference.image(for: .neutral)))
        XCTAssertTrue(actual.bytes == expected.bytes)
        XCTAssertEqual(optimized.alphaScanCount, 1)
        XCTAssertTrue(optimized.image(for: .neutral) === optimized.image(for: .neutral))
        XCTAssertEqual(optimized.alphaScanCount, 1, "Replacement assets retain the ordinary once-per-expression cache")
    }

    @MainActor func testExpressionPreparationMeasurementUsesActualBundledPixels() throws {
        let sheet = try XCTUnwrap(UIImage(named: "CapyFaceExpressions"))
        let fallback = UIImage(named: "CapyFace")
        let lookup: (String) -> UIImage? = { $0 == "CapyFaceExpressions" ? sheet : fallback }
        var referenceSamples: [Double] = [], optimizedSamples: [Double] = []
        for iteration in 0..<8 {
            for optimized in iteration.isMultiple(of: 2) ? [false, true] : [true, false] {
                let cache = CapyExpressionImageCache(contentBounds: optimized ? CapyExpressionSheetMetrics.bounds : nil, load: lookup)
                let begin = ProcessInfo.processInfo.systemUptime
                for expression in CapyFaceExpression.allCases { XCTAssertNotNil(cache.image(for: expression)) }
                let milliseconds = (ProcessInfo.processInfo.systemUptime - begin) * 1_000
                if optimized { optimizedSamples.append(milliseconds) } else { referenceSamples.append(milliseconds) }
                XCTAssertEqual(cache.alphaScanCount, optimized ? 0 : 4)
            }
        }
        func summary(_ samples: [Double]) -> [String: Any] {
            let sorted = samples.sorted()
            return ["samplesMilliseconds": samples, "medianMilliseconds": (sorted[3] + sorted[4]) / 2,
                    "p95Milliseconds": sorted[7]]
        }
        let report: [String: Any] = ["method": "Actual UIKit normalization of all four expressions from the same bundled image; fresh cache each pass, alternating execution order. Includes the optimized whole-image validation hash. UIImage resource decode is already warm. No hardware frame-rate or audio latency claim.",
            "reference": summary(referenceSamples), "optimized": summary(optimizedSamples)]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("EXPRESSION_PREPARATION_DIAGNOSTIC " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "expression-preparation-cost"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func image(size: CGSize, draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
    }

    @MainActor private func allLayers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(allLayers)
    }

    @MainActor func testQuadrantsAreDistinctCachedAndTransparentMarginsDoNotShiftAnchors() throws {
        let colors: [UIColor] = [.red, .green, .blue, .yellow]
        let offsets = [CGPoint(x: 2, y: 12), CGPoint(x: 21, y: 5), CGPoint(x: 8, y: 24), CGPoint(x: 15, y: 1)]
        let sheet = image(size: CGSize(width: 80, height: 80)) { context in
            for index in 0..<4 {
                context.setFillColor(colors[index].cgColor)
                context.fill(CGRect(x: CGFloat(index % 2) * 40 + offsets[index].x,
                    y: CGFloat(index / 2) * 40 + offsets[index].y, width: 14, height: 10))
            }
        }
        var loads: [String: Int] = [:]
        let cache = CapyExpressionImageCache { name in
            loads[name, default: 0] += 1
            return name == "CapyFaceExpressions" ? sheet : nil
        }
        var bounds: [CGRect] = []
        for (index, expression) in CapyFaceExpression.allCases.enumerated() {
            let result = try XCTUnwrap(cache.image(for: expression))
            XCTAssertTrue(result === cache.image(for: expression), "Repeated draws reuse the processed image")
            let pixels = try ExpressionPixels(result)
            XCTAssertEqual(pixels.width, 512); XCTAssertEqual(pixels.height, 512)
            let center = pixels.rgba(x: 256, y: 256)
            let expected: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
            XCTAssertEqual(center, expected[index], "Visual top-left, top-right, bottom-left, bottom-right must map to the declared expression order")
            XCTAssertEqual(pixels.rgba(x: 0, y: 0)[3], 0)
            let content = try XCTUnwrap(pixels.alphaBounds); bounds.append(content)
            XCTAssertEqual(content.midX, 256, accuracy: 1.5); XCTAssertEqual(content.midY, 256, accuracy: 1.5)
            XCTAssertEqual(content.width / content.height, 1.4, accuracy: 0.025, "Normalize placement without stretching the character")
        }
        XCTAssertTrue(bounds.allSatisfy { $0 == bounds[0] })
        XCTAssertEqual(loads["CapyFaceExpressions"], 1); XCTAssertEqual(loads["CapyFace"], 1)
    }

    @MainActor func testMissingMalformedOrEmptySheetUsesFallbackAndMissingBundleStaysNil() throws {
        let fallback = image(size: CGSize(width: 12, height: 12)) { context in
            context.setFillColor(UIColor.brown.cgColor); context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        let malformed = image(size: CGSize(width: 5, height: 4)) { _ in }
        let empty = image(size: CGSize(width: 8, height: 8)) { _ in }
        for sheet: UIImage? in [nil, malformed, empty] {
            let cache = CapyExpressionImageCache { $0 == "CapyFace" ? fallback : sheet }
            for expression in CapyFaceExpression.allCases { XCTAssertTrue(cache.image(for: expression) === fallback) }
        }
        var count = 0
        let missing = CapyExpressionImageCache { _ in count += 1; return nil }
        for _ in 0..<3 { for expression in CapyFaceExpression.allCases { XCTAssertNil(missing.image(for: expression)) } }
        XCTAssertEqual(count, 2, "A missing bundle must not trigger a new resource lookup every board draw")
    }

    @MainActor func testBundledExpressionsHaveConsistentVisibleAnchorsAndTransparentCanvas() throws {
        XCTAssertNotNil(UIImage(named: "CapyFaceExpressions"), "The Demo must bundle its original generated expression sheet")
        var frames: [UIImage] = [], contentBounds: [CGRect] = []
        for expression in CapyFaceExpression.allCases {
            let frame = try XCTUnwrap(CapyExpressionArtwork.image(expression)); frames.append(frame)
            let pixels = try ExpressionPixels(frame), content = try XCTUnwrap(pixels.alphaBounds)
            contentBounds.append(content)
            XCTAssertEqual(content.midX, 256, accuracy: 3); XCTAssertEqual(content.midY, 256, accuracy: 3)
            XCTAssertGreaterThan(content.width, 460)
            XCTAssertLessThan(content.width, 490)
            XCTAssertEqual(pixels.rgba(x: 0, y: 0)[3], 0)
            XCTAssertEqual(pixels.rgba(x: 511, y: 511)[3], 0)
        }
        let neutral = try XCTUnwrap(contentBounds.first)
        for content in contentBounds {
            XCTAssertEqual(content.width, neutral.width, accuracy: 6)
            XCTAssertEqual(content.height, neutral.height, accuracy: 10)
        }
        // Keep a visual attachment so QA sees the runtime-normalized output,
        // including the tile showing through all transparent corners.
        let preview = image(size: CGSize(width: 360, height: 360)) { context in
            for (index, frame) in frames.enumerated() {
                let rect = CGRect(x: (index % 2) * 180, y: (index / 2) * 180, width: 180, height: 180)
                context.setFillColor(UIColor(CapyPalette.regionColors[index]).cgColor); context.fill(rect)
                frame.draw(in: rect.insetBy(dx: 8, dy: 8))
            }
        }
        let attachment = XCTAttachment(image: preview); attachment.name = "capy-expressions-runtime-normalized"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testFeedbackUsesHappyAndStartledImagesAndRemovalClearsAnimations() throws {
        let rect = CGRect(x: 0, y: 0, width: 72, height: 72), host = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let found = BoardCellFeedbackView(cellIndex: 1, kind: .found, frame: rect, tileColor: .cyan, reduceMotion: false)
        let mistake = BoardMistakeFeedbackView(cellIndex: 2, frame: rect, tileColor: .cyan, reduceMotion: false)
        host.addSubview(found); host.addSubview(mistake); found.play(); mistake.play()
        let happy = try XCTUnwrap(allLayers(found.layer).first { $0.name == "found-face-happy" }?.contents) as AnyObject
        let startled = try XCTUnwrap(allLayers(mistake.layer).first { $0.name == "mistake-face-startled" }?.contents) as AnyObject
        XCTAssertTrue(happy === CapyExpressionArtwork.image(.happy)?.cgImage)
        XCTAssertTrue(startled === CapyExpressionArtwork.image(.startled)?.cgImage)
        XCTAssertFalse(allLayers(mistake.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        found.removeFromSuperview(); mistake.removeFromSuperview()
        for view in [found, mistake] as [UIView] {
            XCTAssertTrue(allLayers(view.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        }
    }

    @MainActor func testCompanionReactionNeverInterceptsInputAndHasNoIdleAnimation() async throws {
        let rect = CGRect(x: 0, y: 0, width: 72, height: 72), host = UIView(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        let view = CapyFaceExpressionView(cellIndex: 4, expression: .startled, frame: rect, tileColor: .cyan, reduceMotion: false)
        host.addSubview(view); view.play()
        XCTAssertEqual(view.expression, .startled)
        XCTAssertFalse(view.isUserInteractionEnabled); XCTAssertTrue(view.accessibilityElementsHidden)
        XCTAssertTrue(host.hitTest(CGPoint(x: 36, y: 36), with: nil) === host)
        XCTAssertTrue(allLayers(view.layer).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(view.superview)
        let blink = CapyFaceExpressionView(cellIndex: 4, expression: .blink, frame: rect, tileColor: .cyan, reduceMotion: true)
        XCTAssertEqual(blink.expression, .neutral, "Reduced motion omits decorative blinking")
        host.addSubview(blink); blink.play()
        try await Task.sleep(nanoseconds: 240_000_000)
        XCTAssertNil(blink.superview)
    }

    @MainActor func testRemovedReactionAndMistakeCannotFireOldCleanupAfterReattachment() async throws {
        let rect = CGRect(x: 0, y: 0, width: 72, height: 72), host = UIView(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        let reaction = CapyFaceExpressionView(cellIndex: 0, expression: .blink, frame: rect, tileColor: .cyan, reduceMotion: false)
        let mistake = BoardMistakeFeedbackView(cellIndex: 0, frame: rect, tileColor: .cyan, reduceMotion: true)
        host.addSubview(reaction); reaction.play(); reaction.removeFromSuperview(); host.addSubview(reaction)
        host.addSubview(mistake); mistake.play(); mistake.removeFromSuperview(); host.addSubview(mistake)
        let states = allLayers(mistake.layer).map(\.opacity)
        try await Task.sleep(nanoseconds: 860_000_000)
        XCTAssertTrue(reaction.superview === host); XCTAssertTrue(mistake.superview === host)
        XCTAssertEqual(allLayers(mistake.layer).map(\.opacity), states, "The cancelled reduced-motion transition cannot change a reused view")
        reaction.removeFromSuperview(); mistake.removeFromSuperview()
    }
}
