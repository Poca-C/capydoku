import XCTest
import SwiftUI
import CapydokuCore
@testable import Capydoku

@MainActor private final class HintApplyDisplayObserver: NSObject {
    private var link: CADisplayLink?
    private let observe: () -> Void
    init(observe: @escaping () -> Void) {
        self.observe = observe
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func tick() { observe() }
    func stop() { link?.invalidate(); link = nil }
}

/// Synthetic copy stresses the real imported-configuration rendering path; it is
/// deliberately confined to the test bundle and never added to product startup.
final class OriginalUIContractTests: XCTestCase {
    private let title = "You were so close to finding every Capybara!"
    private let revive = "Continue this puzzle with your progress and all discovered Capybaras"
    private let restart = "Restart this puzzle from the beginning and try a different approach"

    @MainActor func testLongHintPreviewCanBeReadWithoutCoveringBoardOrChangingMarks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hint-copy-layout-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        defer { model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory) }
        model.progress.settings.language = .english
        model.progress.tutorialCompleted = true
        model.start(level: 1)
        model.showHint()
        let originalUse = try XCTUnwrap(model.progress.activeHintUse)
        // A test-only long explanation exercises the saved-preview rendering
        // path. It makes no claim about missing frozen-reference hint wording.
        let explanation = Array(repeating: "Every highlighted cell conflicts with the remaining candidates. Check its row, column, colored region and all touching neighbors before applying these marks.", count: 4).joined(separator: "\n\n")
        model.progress.activeHintUse?.hint = PuzzleHint(cells: originalUse.hint.cells,
            explanation: explanation, rule: originalUse.hint.rule)
        model.screen = .game // Restore the current saved preview without spending a second use.
        let before = try XCTUnwrap(model.session)
        let host = UIHostingController(rootView: RootView().environmentObject(model)
            .environment(\.scenePhase, .active).dynamicTypeSize(.accessibility5))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.overrideUserInterfaceStyle = .light
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        host.view.frame = window.bounds
        try await Task.sleep(nanoseconds: 180_000_000)
        host.view.layoutIfNeeded()
        func capture(_ name: String) throws {
            var drawn = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                drawn = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drawn)
            XCTAssertGreaterThan(Set(try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data).count, 16)
            let attachment = XCTAttachment(image: image); attachment.name = name
            attachment.lifetime = .keepAlways; add(attachment)
        }
        try capture("long-hint-accessibility5-top")
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let allViews = descendants(host.view)
        let board = try XCTUnwrap(allViews.first { $0.accessibilityIdentifier == "puzzle_board" })
        let boardFrame = board.convert(board.bounds, to: window)
        let scroll = try XCTUnwrap(allViews.compactMap { $0 as? UIScrollView }.first {
            $0.contentSize.height > $0.bounds.height + 10
        }, "The full long explanation needs a readable scrolling viewport; it must not overflow the fixed header.")
        let scrollFrame = scroll.convert(scroll.bounds, to: window)
        XCTAssertGreaterThanOrEqual(scrollFrame.minY, window.safeAreaInsets.top + 44)
        XCTAssertLessThanOrEqual(scrollFrame.maxY, boardFrame.minY)
        XCTAssertEqual(boardFrame.width, boardFrame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(boardFrame.width, 190)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        try await Task.sleep(nanoseconds: 60_000_000)
        host.view.layoutIfNeeded()
        try capture("long-hint-accessibility5-bottom")
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        XCTAssertEqual(model.session, before, "Reading and scrolling a preview must not change the game.")
        XCTAssertEqual(model.progress.activeHintUse?.id, originalUse.id)
        XCTAssertTrue(model.closeHint())
        XCTAssertEqual(model.session, before, "Closing a long preview still must not apply marks.")
    }

    @MainActor func testHintTextRespectsAllDynamicTypeSizesInBothLanguages() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("Hosting size measurement requires iOS 16.") }
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
                                       .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        let hint = PuzzleHint(cells: [0], explanation: "A found capybara excludes other cells in its row, column and colored region, plus every touching cell, including diagonals.", rule: "Known capybara")
        for language in [AppLanguage.english, .simplifiedChinese] {
            let heights = sizes.map { size -> CGFloat in
                let host = UIHostingController(rootView: HintPanel(hint: hint)
                    .environment(\.appLanguage, language).dynamicTypeSize(size).frame(width: 350))
                let measured = host.sizeThatFits(in: CGSize(width: 350, height: 10_000))
                XCTAssertTrue(measured.height.isFinite)
                XCTAssertLessThanOrEqual(measured.width, 350)
                return measured.height
            }
            for index in 1..<heights.count { XCTAssertGreaterThanOrEqual(heights[index], heights[index - 1]) }
            XCTAssertGreaterThan(try XCTUnwrap(heights.last), heights[3] * 2,
                                 "Hint text must follow the requested accessibility size, rather than remain fixed at 13pt.")
        }
    }

    @MainActor func testActualRootLongHintApplyKeepsVisibleMarkFeedbackAfterNaturalLayout() async throws {
        // Root is below the real app's loading gate. Match that preparation so
        // a first atlas decode cannot consume the short feedback observation.
        try await BundledStartupResources().prepare()
        let explanation = Array(repeating: "Every highlighted cell conflicts with the remaining candidates. Check its row, column, colored region and all touching neighbors before applying these marks.", count: 4).joined(separator: "\n\n")

        for size in [CGSize(width: 320, height: 568), CGSize(width: 402, height: 874)] {
            for reduced in [false, true] {
                let name = "long-hint-apply-\(Int(size.width))-reduced-\(reduced)"
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name + UUID().uuidString)
                let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
                model.progress.settings.language = .english
                model.progress.tutorialCompleted = true
                model.start(level: 1)
                let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model)
                    .environment(\.scenePhase, .active).dynamicTypeSize(.accessibility5))
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first(where: \.isKeyWindow)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: size)
                window.overrideUserInterfaceStyle = .light
                window.rootViewController = host; window.makeKeyAndVisible()
                host.view.frame = window.bounds
                defer {
                    window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                    model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
                }
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                @discardableResult func capture(_ label: String) -> UIImage {
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = window.screen.scale; format.preferredRange = .standard
                    var drawn = false
                    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                        drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                    }
                    XCTAssertTrue(drawn)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = name + "-" + label; attachment.lifetime = .keepAlways; add(attachment)
                    return image
                }
                // All geometry below comes from normal Root updates and the
                // run loop. Never force configure/layout ordering in this test.
                try await Task.sleep(nanoseconds: 620_000_000)
                let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
                let playingSize = board.bounds.size
                model.showHint()
                let originalUse = try XCTUnwrap(model.progress.activeHintUse)
                // Same synthetic saved-preview fixture as the long-copy test
                // above. Only the explanation changes; cells/rule/use stay real.
                model.progress.activeHintUse?.hint = PuzzleHint(cells: originalUse.hint.cells,
                    explanation: explanation, rule: originalUse.hint.rule)
                model.screen = .game
                try await Task.sleep(nanoseconds: 250_000_000)
                let previewSize = board.bounds.size
                let before = try XCTUnwrap(model.session)
                let inventory = model.progress.availableHints
                let targets = Set(originalUse.hint.cells).subtracting(before.marks)
                XCTAssertFalse(targets.isEmpty)
                XCTAssertEqual(model.progress.activeHintUse?.id, originalUse.id)
                XCTAssertNotNil(model.hint)
                if size.width > 360 {
                    XCTAssertLessThan(previewSize.width, playingSize.width - 10,
                                      "The ordinary-screen fixture must actually shrink the board for its long preview.")
                }
                capture("preview-before-apply")

                struct Sample {
                    let elapsed: Double
                    let boardSize: CGSize
                    let cells: Set<Int>
                    let strokeEnds: [Double]
                    let drawingAnimationCount: Int
                }
                var samples: [Sample] = []
                let started = CACurrentMediaTime()
                let observer = HintApplyDisplayObserver {
                    let effects = descendants(board).compactMap { $0 as? BoardCellFeedbackView }.filter {
                        $0.kind == .markAdded && targets.contains($0.cellIndex) && $0.window === window &&
                        !$0.isHidden && $0.alpha > 0 && !$0.bounds.isEmpty &&
                        ($0.layer.presentation()?.opacity ?? $0.layer.opacity) > 0
                    }
                    let strokes = effects.flatMap { ($0.layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer } }
                    samples.append(Sample(elapsed: CACurrentMediaTime() - started, boardSize: board.bounds.size,
                        cells: Set(effects.map(\.cellIndex)),
                        strokeEnds: strokes.map { Double(($0.presentation() as? CAShapeLayer)?.strokeEnd ?? $0.strokeEnd) },
                        drawingAnimationCount: strokes.reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }))
                }
                defer { observer.stop() }
                model.applyHint()
                let applied = try XCTUnwrap(model.session)
                XCTAssertNil(model.hint); XCTAssertNil(model.progress.activeHintUse)
                XCTAssertEqual(applied.marks, before.marks.union(targets), "Apply commits all suggested X marks immediately.")
                XCTAssertEqual(applied.found, before.found); XCTAssertEqual(applied.errors, before.errors)
                XCTAssertEqual(applied.lives, before.lives); XCTAssertEqual(applied.score, before.score)
                XCTAssertEqual(model.progress.availableHints, inventory, "Apply cannot spend the preview a second time.")

                // Observe actual display opportunities without screenshot
                // readback, layer time offsets or forced layout in the window.
                try await Task.sleep(nanoseconds: 75_000_000)
                observer.stop()
                let captureElapsed = CACurrentMediaTime() - started
                let afterImage = capture("after-apply-natural-\(Int(captureElapsed * 1_000))ms")
                let restored = samples.filter {
                    abs($0.boardSize.width - playingSize.width) < 0.5 &&
                    abs($0.boardSize.height - playingSize.height) < 0.5
                }
                XCTAssertFalse(restored.isEmpty, "\(name): Root must naturally restore its playing layout.")
                if reduced {
                    XCTAssertTrue(restored.filter { !$0.cells.isEmpty }.allSatisfy { $0.drawingAnimationCount == 0 },
                                  "Reduced motion keeps a static confirmation rather than an animated stroke.")
                    // A reduced-motion cover is optional: its final X is the
                    // same as the committed board. Check real window pixels,
                    // not the presence of an unnecessary decoration view.
                    let bitmap = try XCTUnwrap(afterImage.cgImage)
                    for index in targets.sorted() {
                        let cell = try XCTUnwrap(board.accessibilityElements?[index] as? UIAccessibilityElement)
                        let frame = board.convert(cell.accessibilityFrameInContainerSpace, to: window)
                        let center = CGRect(x: floor(frame.midX * afterImage.scale),
                            y: floor(frame.midY * afterImage.scale), width: 1, height: 1)
                        let pixel = try XCTUnwrap(bitmap.cropping(to: center))
                        var rgba = [UInt8](repeating: 0, count: 4)
                        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
                            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
                        }
                        XCTAssertTrue(rendered)
                        XCTAssertTrue(rgba.prefix(3).allSatisfy { $0 > 235 } && rgba[3] > 250,
                                      "\(name) cell \(index): the actual window must already show the white center of the committed X.")
                    }
                } else {
                    XCTAssertTrue(restored.contains { $0.cells == targets },
                                  "\(name): committed X feedback must survive the preview-to-board layout handoff for a real display frame.")
                    XCTAssertTrue(restored.contains { $0.cells == targets && $0.strokeEnds.contains { $0 > 0 && $0 < 1 } },
                                  "\(name): the visible feedback must include the actual drawing stroke, not only final-state X marks.")
                }
                let rows: [[String: Any]] = samples.map {
                    ["elapsedSeconds": $0.elapsed, "boardSize": [$0.boardSize.width, $0.boardSize.height],
                     "visibleMarkAddedCells": $0.cells.sorted(), "presentationStrokeEnds": $0.strokeEnds,
                     "drawingAnimationCount": $0.drawingAnimationCount]
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "fixture": name, "source": "Existing long-copy saved-preview fixture; original hint cells/rule/use retained",
                    "playingSize": [playingSize.width, playingSize.height],
                    "previewSize": [previewSize.width, previewSize.height], "targets": targets.sorted(),
                    "screenshotRequestedAfterSeconds": captureElapsed, "displayLinkSamples": rows,
                    "boundary": "Actual Root; no manual configure/layout or CA clock changes. Display-link observations precede screenshot readback."
                ], options: [.prettyPrinted, .sortedKeys])
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = name + "-natural-handoff"; attachment.lifetime = .keepAlways; add(attachment)

                try await Task.sleep(nanoseconds: 220_000_000)
                XCTAssertEqual(model.session, applied, "Finite feedback cannot change the committed board.")
                XCTAssertTrue(descendants(board).compactMap { $0 as? BoardCellFeedbackView }.filter { $0.kind == .markAdded }.isEmpty)
                let nextMark = try XCTUnwrap(applied.puzzle.regions.indices.first {
                    !applied.found.contains($0) && !applied.marks.contains($0)
                })
                XCTAssertTrue(board.activate(index: nextMark, submit: false))
                XCTAssertTrue(try XCTUnwrap(model.session).marks.contains(nextMark), "Apply must leave normal board input available.")
            }
        }
    }

    @MainActor func testLongFailureCopyKeepsNaturalButtonHeightAndMinimumTouchSize() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("Hosting size measurement requires iOS 16.") }
        func measured(_ text: String, compact: Bool = false) -> CGSize {
            let host = UIHostingController(rootView:
                CapyButton(text, action: {}).buttonStyle(CapyButtonStyle(compact: compact))
                    .environment(\.appLanguage, .english).dynamicTypeSize(.large).frame(width: 280))
            return host.sizeThatFits(in: CGSize(width: 280, height: 2_000))
        }
        let short = measured("Play On"), long = measured(revive), other = measured(restart)
        for size in [short, long, other, measured("OK", compact: true)] {
            XCTAssertGreaterThanOrEqual(size.width, 44)
            XCTAssertGreaterThanOrEqual(size.height, 44)
            XCTAssertLessThanOrEqual(size.width, 280)
        }
        XCTAssertGreaterThan(long.height, short.height + 20, "Long labels must wrap and grow, rather than truncate into a fixed-height capsule.")
        XCTAssertGreaterThan(other.height, short.height + 20)
    }

    @MainActor func testLongImportedFailureRendersInTheActualResultPanel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
        var row = try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: url))
        row.failure.title = title; row.failure.reviveButtonTitle = revive; row.failure.restartButtonTitle = restart
        row.revive.freeCount = 1
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.settings.language = .english
        model.config = DemoConfig(referenceGameplay: row)
        model.progress.tutorialCompleted = true; model.start(level: 1)
        let puzzle = try XCTUnwrap(model.session).puzzle
        for cell in puzzle.regions.indices.filter({ !puzzle.solution.contains($0) }).prefix(row.startingLives) { model.submit(cell) }
        XCTAssertEqual(model.session?.status, .lost)
        XCTAssertEqual(model.session?.config.referenceGameplay?.failure.title, title)
        XCTAssertTrue(model.reviveAvailable)
        let host = UIHostingController(rootView: RootView().environmentObject(model))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        // Let SwiftUI complete one layout transaction; no reference animation timing is assumed.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        host.view.layoutIfNeeded()
        var didDraw = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            didDraw = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(didDraw)
        let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 16, "A blank screenshot is not valid evidence of the configured layout.")
        let evidence = XCTAttachment(image: image)
        evidence.name = "Long imported failure copy on current device"
        evidence.lifetime = .keepAlways; add(evidence)
        func scrollViews(in view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scroll = try XCTUnwrap(scrollViews(in: host.view).first { $0.contentSize.height > $0.bounds.height + 10 })
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        host.view.layoutIfNeeded()
        let bottom = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let bottomEvidence = XCTAttachment(image: bottom)
        bottomEvidence.name = "Long imported failure copy scrolled to restart"
        bottomEvidence.lifetime = .keepAlways; add(bottomEvidence)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.session?.status, .lost, "Measuring or rendering the result must not restart or revive the session.")
    }
}
