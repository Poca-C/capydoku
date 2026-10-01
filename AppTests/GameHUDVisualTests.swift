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

    /// Real late-board scenes for proximity and rapid score replacement review.
    /// Final snapshots occur after the moving interval; these are broad phases,
    /// not a frame-rate or precise callback-latency benchmark.
    @MainActor func testDenseLocalScoresInActualRootStayAssociatedAndReadable() async throws {
        var samples: [[String: Any]] = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (level, reduced) in [(6, true), (6, false), (111, true), (111, false)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dense-score-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true; model.start(level: level)
            let solution = try XCTUnwrap(model.session).puzzle.solution
            let pending = level == 6 ? 2 : 1
            for index in solution.dropLast(pending) { model.submit(index) }
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            let surround = UIWindow(windowScene: scene); surround.frame = scene.coordinateSpace.bounds
            let backdrop = UIViewController(); backdrop.view.backgroundColor = .black
            surround.rootViewController = backdrop; surround.windowLevel = UIWindow.Level(rawValue: 1)
            surround.isHidden = false; window.windowLevel = UIWindow.Level(rawValue: 2)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
            var frames: [String: CGRect] = [:]
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model)
                .environment(\.scenePhase, .active).environment(\.capyLayoutObserver, { frames[$0] = $1 }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil
                surround.isHidden = true; surround.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
            let initial = try XCTUnwrap(model.session), boardFrame = try XCTUnwrap(frames["puzzle_board"])
            let elements = try XCTUnwrap(board.accessibilityElements as? [UIAccessibilityElement])
            let cells = elements.map { board.convert($0.accessibilityFrameInContainerSpace, to: window) }
            var lastAmount = 0
            for index in solution.suffix(pending) {
                let oldScore = model.session!.score
                XCTAssertTrue(board.activate(index: index, submit: true))
                lastAmount = model.session!.score - oldScore
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            for _ in 0..<10 where frames["local_score_\(lastAmount)"] == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let badge = try XCTUnwrap(frames["local_score_\(lastAmount)"]), source = cells[solution.last!]
            samples.append(["level": level, "reduced": reduced, "amount": lastAmount,
                "sourceFrame": NSCoder.string(for: source), "labelFrame": NSCoder.string(for: badge),
                "centerDistanceInCells": hypot(badge.midX - source.midX, badge.midY - source.midY) / source.width])
            XCTAssertEqual(model.session?.status, .won); XCTAssertEqual(model.session?.found, Set(solution))
            XCTAssertEqual(model.session?.lives, initial.lives)
            XCTAssertEqual(frames["puzzle_board"], boardFrame)
            for cell in cells.enumerated() where solution.contains(cell.offset) {
                XCTAssertFalse(badge.intersects(cell.element), "Latest score must not cover any character.")
            }
            let accepted = model.session
            model.submit(solution.last!); XCTAssertEqual(model.session, accepted)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            let a = XCTAttachment(image: image); a.name = "dense-score-L\(level)-reduced-\(reduced)"
            a.lifetime = .keepAlways; add(a)
        }
        let data = try JSONSerialization.data(withJSONObject: ["samples": samples,
            "boundary": "Real Root320x568 viewport;150ms requested intervals and final layout observations. Static reduced-motion collisions and natural final-flight frames are visually reviewed; no compositor phase or actual input latency is inferred."], options: [.prettyPrinted, .sortedKeys])
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        a.name = "dense-score-root-geometry"; a.lifetime = .keepAlways; add(a)
    }

    @MainActor func testLocalScoreFitsActualRootWithoutCoveringItsCharacterAtBoardEdges() async throws {
        var samples: [[String: Any]] = []
        for (width, level, reduced) in [(CGFloat(402), 6, false), (CGFloat(320), 101, false), (CGFloat(320), 101, true), (CGFloat(320), 47, false)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("score-placement-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true; model.start(level: level)
            if level == 47 {
                for index in try XCTUnwrap(model.session).puzzle.solution.dropLast() { model.submit(index) }
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: width == 320 ? 568 : 874)
            var frames: [String: CGRect] = [:]
            var firstLayoutTimes: [String: TimeInterval] = [:]
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model)
                .environment(\.scenePhase, .active)
                .environment(\.capyLayoutObserver, { key, frame in
                    frames[key] = frame
                    if key.hasPrefix("local_score"), firstLayoutTimes[key] == nil {
                        firstLayoutTimes[key] = ProcessInfo.processInfo.systemUptime
                    }
                }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
            let initial = try XCTUnwrap(model.session), boardBefore = try XCTUnwrap(frames["puzzle_board"])
            let elements = try XCTUnwrap(board.accessibilityElements as? [UIAccessibilityElement])
            let measured = elements.map { board.convert($0.accessibilityFrameInContainerSpace, to: window) }
            let indices = level == 47 ? [try XCTUnwrap(initial.puzzle.solution.last)] : [try XCTUnwrap(initial.puzzle.solution.first), initial.puzzle.solution[1], try XCTUnwrap(initial.puzzle.solution.last)]
            for (step, index) in indices.enumerated() {
                let prior = try XCTUnwrap(model.session)
                let submittedAt = ProcessInfo.processInfo.systemUptime
                XCTAssertTrue(board.activate(index: index, submit: true))
                let accepted = try XCTUnwrap(model.session), amount = accepted.score - prior.score
                XCTAssertGreaterThan(amount, 0)
                try await Task.sleep(nanoseconds: 120_000_000)
                // Read the laid-out badge after its asynchronous accepted-event
                // delivery; the initial 120ms sleep is not a compositor clock.
                for _ in 0..<15 where frames["local_score_\(amount)"] == nil {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                if frames["local_score_\(amount)"] == nil {
                    let full = measured.reduce(CGRect.null) { $0.union($1) }
                    let attempt = CellScorePlacement.anchored(amount: amount, cellFrame: measured[index], boardFrame: full,
                                                              avoiding: accepted.found.map { measured[$0] })
                    let diagnostic: [String: Any] = ["level": level, "amount": amount, "index": index,
                        "board": NSCoder.string(for: full), "source": NSCoder.string(for: measured[index]),
                        "found": accepted.found.sorted(), "layoutPossible": attempt != nil,
                        "observedLabels": frames.keys.filter { $0.hasPrefix("local_score") },
                        "notice": model.notice ?? "", "error": model.errorMessage ?? ""]
                    let data = try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
                    let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    a.name = "local-score-missing-diagnostic"; a.lifetime = .keepAlways; add(a)
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
                    let shot = XCTAttachment(image: image); shot.name = "local-score-missing-root"; shot.lifetime = .keepAlways; add(shot)
                }
                let label = try XCTUnwrap(frames["local_score_\(amount)"])
                samples.append(["level": level, "width": width, "reduced": reduced, "cell": index, "amount": amount,
                    "layoutObservedAfterSubmissionMs": (try XCTUnwrap(firstLayoutTimes["local_score_\(amount)"]) - submittedAt) * 1000,
                    "beforeCaptureAfterSubmissionMs": (ProcessInfo.processInfo.systemUptime - submittedAt) * 1000])
                let cell = measured[index]
                XCTAssertFalse(label.intersects(cell), "The complete laid-out score badge must leave the accepted character visible.")
                for found in accepted.found {
                    let foundCell = measured[found]
                    XCTAssertFalse(label.intersects(foundCell), "The new badge must also preserve earlier characters.")
                }
                XCTAssertTrue(boardBefore.contains(label), "Edge placement cannot spill into rules, Combo or tools.")
                XCTAssertGreaterThan(label.width, 20); XCTAssertGreaterThanOrEqual(label.height, 22)
                XCTAssertLessThanOrEqual(label.height, 28.5)
                XCTAssertEqual(frames["puzzle_board"], boardBefore)
                XCTAssertEqual(model.session, accepted)
                XCTAssertEqual(accepted.lives, initial.lives)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                let a = XCTAttachment(image: image)
                a.name = "local-score-L\(level)-\(Int(width))pt-reduced-\(reduced)-\(level == 47 ? "final" : step == 0 ? "top" : step == 1 ? "nearby" : "bottom")"
                a.lifetime = .keepAlways; add(a)
                // The second source arrives before the first badge's 0.72s
                // cleanup; no forced clock or animation seek is involved.
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            try await Task.sleep(nanoseconds: 800_000_000)
            XCTAssertEqual(model.session?.found, initial.found.union(indices))
        }
        let data = try JSONSerialization.data(withJSONObject: ["samples": samples,
            "boundary": "Process-relative layout-observer timings are not visible frame or touch latency measurements; snapshots are taken afterward. Initial120ms wait is followed by up to300ms for async layout."], options: [.prettyPrinted, .sortedKeys])
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        a.name = "local-score-root-layout-timing"; a.lifetime = .keepAlways; add(a)
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
        let happyFace = try XCTUnwrap(layers(happy.layer).first { $0.name == "found-face-happy" })
        let happyImage = try XCTUnwrap(happyFace.presentation()?.contents) as AnyObject
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
