import XCTest
import SwiftUI
import CapydokuCore
@testable import Capydoku

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
