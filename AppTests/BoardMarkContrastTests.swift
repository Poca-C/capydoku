import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

private struct RenderedMarkPixels {
    let width: Int
    let height: Int
    let scale: CGFloat
    let bytes: [UInt8]

    init(_ image: UIImage) throws {
        let source = try XCTUnwrap(image.cgImage)
        let pixelWidth = source.width, pixelHeight = source.height
        width = pixelWidth; height = pixelHeight; scale = image.scale
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return true
        }
        XCTAssertTrue(rendered)
        bytes = pixels
    }

    func rgb(x: Int, y: Int) -> [Double] {
        let start = (max(0, min(height - 1, y)) * width + max(0, min(width - 1, x))) * 4
        return (0..<3).map { Double(bytes[start + $0]) / 255 }
    }
    func rgb(at point: CGPoint) -> [Double] { rgb(x: Int(point.x * scale), y: Int(point.y * scale)) }
    static func luminance(_ color: [Double]) -> Double {
        zip(color, [0.2126, 0.7152, 0.0722]).reduce(0) {
            $0 + $1.1 * ($1.0 <= 0.04045 ? $1.0 / 12.92 : pow(($1.0 + 0.055) / 1.055, 2.4))
        }
    }
    static func contrast(_ first: [Double], _ second: [Double]) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Local readability targets: Original [244, 306] requires readable white Xs
/// and functional text but does not prescribe numerical contrast thresholds.
/// Use the actual native board and actual full result view, not a palette mock.
final class BoardMarkContrastTests: XCTestCase {
    @MainActor private func capture(_ view: UIView, name: String) throws -> UIImage {
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn)
        XCTAssertGreaterThan(Set(try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data).count, 16)
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return image
    }

    private func attachMetrics(_ rows: [[String: Any]], name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testActualTenByTenMarksKeepReadableEdgesAndDistinctCentersAcrossEveryRegionColor() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.overrideUserInterfaceStyle = .light
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        var metrics = [[String: Any]]()
        // A synthetic drawing fixture assigns one palette color per column.
        // It is deliberately not an accepted gameplay puzzle or solver fixture.
        for side: CGFloat in [190, 340] {
            let board = PuzzleGridUIView(frame: CGRect(x: 16, y: 120, width: side, height: side))
            controller.view.addSubview(board)
            defer { board.removeFromSuperview() }
            func configure(_ kind: String) {
                let all = Set(0..<100)
                board.configure(size: 10, regions: (0..<100).map { $0 % 10 }, found: [],
                    marks: kind == "solid" ? all : [], errors: kind == "error" ? all : [],
                    preview: kind == "preview" ? all : [], effectsEnabled: false,
                    tutorialTargets: [], locked: kind == "preview", onToggle: { _ in }, onSubmit: { _ in }, onMark: { _ in })
                board.layoutIfNeeded()
            }
            configure("blank")
            try await Task.sleep(nanoseconds: 100_000_000)
            let blank = try RenderedMarkPixels(capture(board, name: "palette-10x10-\(Int(side))pt-blank"))
            let cells = try XCTUnwrap(board.accessibilityElements as? [UIAccessibilityElement])
            let frames = cells.prefix(10).map(\.accessibilityFrameInContainerSpace)
            for kind in ["solid", "preview", "error"] {
                configure(kind)
                try await Task.sleep(nanoseconds: 50_000_000)
                let rendered = try RenderedMarkPixels(capture(board, name: "palette-10x10-\(Int(side))pt-\(kind)"))
                for (region, frame) in frames.enumerated() {
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    let background = blank.rgb(at: center), core = rendered.rgb(at: center)
                    // Inspect a central interior square. Cell gaps, rounded
                    // corners and the outside canvas cannot satisfy the check.
                    let interior = frame.insetBy(dx: frame.width * 0.22, dy: frame.height * 0.22)
                    var darkBoundaryPixels = 0
                    var maximumBoundaryContrast = 1.0
                    for y in Int(ceil(interior.minY * rendered.scale))..<Int(floor(interior.maxY * rendered.scale)) {
                        for x in Int(ceil(interior.minX * rendered.scale))..<Int(floor(interior.maxX * rendered.scale)) {
                            let color = rendered.rgb(x: x, y: y)
                            guard RenderedMarkPixels.luminance(color) < RenderedMarkPixels.luminance(background) else { continue }
                            let ratio = RenderedMarkPixels.contrast(color, background)
                            maximumBoundaryContrast = max(maximumBoundaryContrast, ratio)
                            if ratio >= 3 { darkBoundaryPixels += 1 }
                        }
                    }
                    metrics.append(["boardSidePt": Int(side), "kind": kind, "region": region,
                                    "backgroundRGB": background, "centerRGB": core,
                                    "maxDarkBoundaryContrast": maximumBoundaryContrast,
                                    "darkBoundaryPixelsAtLeast3": darkBoundaryPixels])
                    XCTAssertGreaterThanOrEqual(darkBoundaryPixels, 8,
                        "\(side)pt \(kind) region \(region): actual X needs a visible contrasting boundary; local target 3:1.")
                    if kind == "solid" { XCTAssertTrue(core.allSatisfy { $0 > 0.94 }, "Solid marks remain white.") }
                    if kind == "preview" {
                        for channel in 0..<3 { XCTAssertEqual(core[channel], background[channel], accuracy: 2.0 / 255, "Preview remains hollow rather than becoming a committed X.") }
                    }
                    if kind == "error" { XCTAssertTrue(core[0] > 0.8 && core[1] < 0.35 && core[2] < 0.35, "Errors remain red, not white or hollow.") }
                }
            }
        }
        try attachMetrics(metrics, name: "actual-board-pixel-contrast-local-targets")
    }

    @MainActor func testActualFreeReviveBadgeTextIsReadableInBothLanguagesWithoutChangingTheLostGame() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
        var row = try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: fixture))
        row.revive.freeCount = 1
        var metrics = [[String: Any]]()
        for language in [AppLanguage.english, .simplifiedChinese] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("free-badge-contrast-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.settings.language = language; model.progress.tutorialCompleted = true
            model.config = DemoConfig(referenceGameplay: row); model.start(level: 1)
            let puzzle = try XCTUnwrap(model.session).puzzle
            for cell in puzzle.regions.indices.filter({ !puzzle.solution.contains($0) }).prefix(row.startingLives) { model.submit(cell) }
            let original = try XCTUnwrap(model.session)
            XCTAssertEqual(original.status, .lost); XCTAssertTrue(model.reviveAvailable); XCTAssertFalse(model.reviveNeedsVideo)
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: true).environmentObject(model).environment(\.scenePhase, .active))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds; window.overrideUserInterfaceStyle = .light
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(nanoseconds: 180_000_000)
            host.view.layoutIfNeeded()
            let image = try capture(host.view, name: "actual-free-revive-\(language.rawValue)")
            let pixels = try RenderedMarkPixels(image)
            // Derive the flat green badge from the actual rendered image. The
            // dimmed board does not have a saturated green region in this L1.
            var frequency: [Int: Int] = [:]
            for index in stride(from: 0, to: pixels.bytes.count, by: 4) {
                let r = Int(pixels.bytes[index]), g = Int(pixels.bytes[index + 1]), b = Int(pixels.bytes[index + 2])
                if g > 65 && Double(g) > Double(max(r, b)) * 1.6 { frequency[(r << 16) | (g << 8) | b, default: 0] += 1 }
            }
            let key = try XCTUnwrap(frequency.max(by: { $0.value < $1.value })?.key)
            let fill = [Double((key >> 16) & 255), Double((key >> 8) & 255), Double(key & 255)].map { $0 / 255 }
            var left = pixels.width, right = 0, top = pixels.height, bottom = 0
            for y in 0..<pixels.height { for x in 0..<pixels.width {
                let index = (y * pixels.width + x) * 4
                if ((Int(pixels.bytes[index]) << 16) | (Int(pixels.bytes[index + 1]) << 8) | Int(pixels.bytes[index + 2])) == key {
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                }
            } }
            XCTAssertGreaterThan(right - left, 30 * Int(pixels.scale))
            var brightPixels = 0
            for y in top...bottom { for x in left...right {
                if pixels.rgb(x: x, y: y).allSatisfy({ $0 > 0.97 }) { brightPixels += 1 }
            } }
            XCTAssertGreaterThan(brightPixels, 50, "The actual badge must contain white label glyphs, not only an empty green capsule.")
            let ratio = RenderedMarkPixels.contrast([1, 1, 1], fill)
            metrics.append(["language": language.rawValue, "renderedFillRGB": fill, "whiteGlyphPixels": brightPixels,
                            "contrast": ratio, "badgePixelBounds": [left, top, right, bottom]])
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "15pt functional text uses a local 4.5:1 readability target; Original [306] gives no numeric threshold.")
            XCTAssertEqual(model.session, original, "Rendering must not revive, restart or change the board.")
        }
        try attachMetrics(metrics, name: "actual-free-badge-pixel-contrast-local-targets")
    }
}
