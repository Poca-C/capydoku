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

    @MainActor func testLongFailureCopyKeepsNaturalButtonHeightAndMinimumTouchSize() throws {
        guard #available(iOS 16.0, *) else { throw XCTSkip("Hosting size measurement requires iOS 16.") }
        func measured(_ text: String, compact: Bool = false) -> CGSize {
            let host = UIHostingController(rootView:
                CapyButton(text, action: {}).buttonStyle(CapyButtonStyle(compact: compact)).frame(width: 280))
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
