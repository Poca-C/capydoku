import XCTest
import SwiftUI
import UIKit
@testable import Capydoku

final class ResultAccessibilityFocusTests: XCTestCase {
    @MainActor func testFreshAndRestoredResultEachRequestFocusOnceAndVisualStagesNeverRequestItAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("result-focus-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true; model.start(level: 6)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        var requests: [String] = []
        let host = UIHostingController(rootView: RootView(reduceMotionOverride: false,
            focusRequestObserver: { requests.append($0) }).environmentObject(model).environment(\.scenePhase, .active))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        requests.removeAll()
        for cell in try XCTUnwrap(model.session).puzzle.solution { model.submit(cell) }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(requests, ["next_level"], "Entering the result requests its already available primary action once")
        // Any user navigation after the initial request is safe only if no
        // subsequent automatic request occurs at the character/title stages.
        requests.removeAll()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(requests.isEmpty, "Decoration timing must never take focus away from a control the user selected")
        requests.removeAll()
        model.flushPendingSaves()
        let restoredModel = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        restoredModel.startOrContinue()
        let restoredHost = UIHostingController(rootView: RootView(reduceMotionOverride: false,
            focusRequestObserver: { requests.append($0) }).environmentObject(restoredModel).environment(\.scenePhase, .active))
        window.rootViewController = restoredHost; window.makeKeyAndVisible()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(restoredModel.session?.id, model.session?.id)
        XCTAssertEqual(requests, ["next_level"], "Restoring a completed session still establishes an initial modal focus")
        requests.removeAll()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(requests.isEmpty)
        restoredModel.flushPendingSaves()
    }
}
