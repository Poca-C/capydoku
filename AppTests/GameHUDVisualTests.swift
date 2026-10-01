import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

final class GameHUDVisualTests: XCTestCase {
    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private func layers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(layers)
    }

    @MainActor func testCurrentLevelSixRootCapturesHappyScoreAndVisibleConflictWithoutChangingCommittedGame() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hud-current-pack-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.settings.language = .simplifiedChinese
        model.progress.tutorialCompleted = true
        model.start(level: 6)
        let initial = try XCTUnwrap(model.session)
        XCTAssertEqual(initial.puzzle.id, 6)
        XCTAssertEqual(initial.status, .playing)
        XCTAssertGreaterThan(initial.lives, 1)
        XCTAssertTrue(initial.found.isEmpty)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        var frames: [String: CGRect] = [:]
        let host = UIHostingController(rootView: RootView(reduceMotionOverride: false)
            .environmentObject(model).environment(\.scenePhase, .active)
            .environment(\.capyLayoutObserver, { frames[$0] = $1 }))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
            model.flushPendingSaves()
            try? FileManager.default.removeItem(at: directory)
        }
        func capture(_ name: String) throws {
            var drawn = false
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                drawn = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
            }
            XCTAssertTrue(drawn)
            XCTAssertGreaterThan(Set(try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data).count, 16)
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
        let solutionCell = try XCTUnwrap(initial.puzzle.solution.first)
        model.submit(solutionCell)
        let accepted = try XCTUnwrap(model.session)
        XCTAssertEqual(accepted.found, [solutionCell])
        XCTAssertGreaterThan(accepted.score, initial.score)
        XCTAssertEqual(accepted.lives, initial.lives)
        try await Task.sleep(nanoseconds: 120_000_000)
        let happy = try XCTUnwrap(descendants(board).compactMap { $0 as? BoardCellFeedbackView }
            .first { $0.cellIndex == solutionCell && $0.kind == .found })
        let happyImage = try XCTUnwrap(layers(happy.layer).first { $0.name == "found-face-happy" }?.contents) as AnyObject
        XCTAssertTrue(happyImage === CapyExpressionArtwork.image(.happy)?.cgImage)
        try capture("current-level-6-happy-local-score-120ms")
        XCTAssertEqual(model.session, accepted, "Happy artwork and local score text only acknowledge the accepted move.")

        try await Task.sleep(nanoseconds: 700_000_000)
        let wrongCell = try XCTUnwrap(initial.puzzle.regions.indices.first { cell in
            !initial.puzzle.solution.contains(cell) && !VisibleConflictAnalysis.conflicts(
                size: initial.puzzle.size, regions: initial.puzzle.regions,
                candidate: cell, found: accepted.found).isEmpty
        })
        let expected = VisibleConflictAnalysis.conflicts(size: initial.puzzle.size,
            regions: initial.puzzle.regions, candidate: wrongCell, found: accepted.found)
        model.submit(wrongCell)
        let mistaken = try XCTUnwrap(model.session)
        XCTAssertEqual(mistaken.lives, accepted.lives - 1)
        XCTAssertEqual(mistaken.found, accepted.found)
        XCTAssertEqual(mistaken.score, accepted.score)
        XCTAssertTrue(mistaken.errors.contains(wrongCell))
        model.submit(wrongCell)
        XCTAssertEqual(model.session, mistaken, "A duplicated delivery cannot deduct life again while feedback is starting.")

        try await Task.sleep(nanoseconds: 120_000_000)
        let conflict = try XCTUnwrap(descendants(board).compactMap { $0 as? BoardConflictFeedbackView }.first)
        XCTAssertEqual(conflict.candidate, wrongCell)
        XCTAssertEqual(conflict.conflicts, expected)
        XCTAssertEqual(conflict.connections.count, expected.count)
        XCTAssertFalse(conflict.isUserInteractionEnabled)
        XCTAssertTrue(descendants(board).compactMap { $0 as? BoardMistakeFeedbackView }.contains { $0.cellIndex == wrongCell })
        let rulesFrame = try XCTUnwrap(frames["rule_strip"])
        let livesFrame = try XCTUnwrap(frames["lives"])
        let boardFrame = try XCTUnwrap(frames["puzzle_board"])
        XCTAssertGreaterThan(rulesFrame.height, 0)
        XCTAssertGreaterThan(livesFrame.height, 0)
        XCTAssertLessThanOrEqual(rulesFrame.maxY, boardFrame.minY)
        XCTAssertLessThan(livesFrame.maxY, boardFrame.minY)
        try capture("current-level-6-rules-links-heart-loss-120ms")
        XCTAssertEqual(model.session, mistaken)

        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertTrue(descendants(board).compactMap { $0 as? BoardConflictFeedbackView }.isEmpty)
        XCTAssertTrue(descendants(board).compactMap { $0 as? BoardMistakeFeedbackView }.isEmpty)
        XCTAssertEqual(model.session, mistaken, "Animation completion must not alter the answer, score, life or marks.")
        XCTAssertEqual(model.session?.puzzle, initial.puzzle, "This capture uses the current packaged level without a fixture substitution.")
        try capture("current-level-6-conflict-settled-no-extra-deduction")
    }
}
