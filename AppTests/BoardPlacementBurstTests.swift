import XCTest
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor
private final class PlacementBurstRig {
    let board = PuzzleGridUIView(frame: CGRect(x: 20, y: 140, width: 320, height: 320))
    let window: UIWindow
    let previousWindow: UIWindow?
    var id = UUID()
    var found: Set<Int> = []
    var errors: Set<Int> = []
    var lives = 3, score = 0
    var latestSubmissionSucceeded: Bool?
    var deferredSubmit: ((Int) -> Void)?
    var callbacks = 0
    var foundCallbacks: [Int] = [], scoreCallbacks: [Int] = []
    var locked = false, hidden = false, enabled = true, reduced = false
    var preview: Set<Int> = []
    let regions = [0, 0, 1, 1, 0, 0, 0, 1, 2, 3, 0, 1, 3, 3, 3, 1]
    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.addSubview(board); refresh(); board.layoutIfNeeded()
    }
    func refresh() {
        board.configure(size: 4, regions: regions, found: found, marks: [], errors: errors, preview: preview,
            sessionID: id, lives: lives, score: score, latestSubmissionSucceeded: latestSubmissionSucceeded,
            effectsEnabled: enabled, reduceMotion: reduced,
            tutorialTargets: [], locked: locked, hideAccessibility: hidden,
            onToggle: { [weak self] _ in self?.callbacks += 1 },
            onSubmit: { [weak self] cell in self?.callbacks += 1; self?.deferredSubmit?(cell) },
            onMark: { [weak self] _ in self?.callbacks += 1 },
            onFoundFeedback: { [weak self] cell, _ in self?.foundCallbacks.append(cell) },
            onScoreFeedback: { [weak self] amount, _ in self?.scoreCallbacks.append(amount) })
    }
    func refresh(_ session: GameSession) {
        id = session.id; found = session.found; errors = session.errors
        lives = session.lives; score = session.score; refresh()
    }
    var bursts: [BoardPlacementBurstView] { board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardPlacementBurstView } }
    func close() {
        board.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
        previousWindow?.makeKeyAndVisible()
    }
}

final class BoardPlacementBurstTests: XCTestCase {
    @MainActor private func make(side: CGFloat, size: Int, cell: Int) -> BoardPlacementBurstView {
        let boardRect = CGRect(x: 7, y: 7, width: side - 14, height: side - 14)
        let unit = boardRect.width / CGFloat(size)
        let cellRect = CGRect(x: 7 + CGFloat(cell % size) * unit, y: 7 + CGFloat(cell / size) * unit, width: unit, height: unit)
        return BoardPlacementBurstView(cellIndex: cell, frame: CGRect(x: 0, y: 0, width: side, height: side),
            boardRect: boardRect, cellRect: cellRect, regionColor: UIColor(CapyPalette.regionColors[4]))
    }

    @MainActor private func animations(_ root: CALayer) -> [CAAnimation] {
        (root.animationKeys() ?? []).compactMap { root.animation(forKey: $0) } + (root.sublayers ?? []).flatMap(animations)
    }

    @MainActor func testExpandedArcsCrossCellEdgesButKeepEveryRotatingParticleInsideAllBoardSizes() throws {
        for size in 4...10 {
            for side: CGFloat in [190, 340] {
                let boardRect = CGRect(x: 7, y: 7, width: side - 14, height: side - 14)
                for cell in [0, size - 1, size * (size - 1), size * size - 1, size * (size / 2) + size / 2] {
                    let burst = make(side: side, size: size, cell: cell)
                    XCTAssertEqual(burst.trajectories.count, 12)
                    for (index, arc) in burst.trajectories.enumerated() {
                        XCTAssertEqual(arc.count, 21)
                        let radius = burst.particleRadii[index]
                        for point in arc {
                            XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                            XCTAssertTrue(boardRect.contains(CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)))
                        }
                    }
                    if cell == size * (size / 2) + size / 2 {
                        let unit = boardRect.width / CGFloat(size)
                        let cellRect = CGRect(x: 7 + CGFloat(cell % size) * unit, y: 7 + CGFloat(cell / size) * unit, width: unit, height: unit)
                        XCTAssertGreaterThan(burst.trajectories.filter { $0.contains { !cellRect.contains($0) } }.count, 6,
                            "A celebration must visibly expand beyond its source cell, not remain another local ring")
                    }
                    let pieces = try XCTUnwrap(burst.layer.sublayers).compactMap { $0 as? CAShapeLayer }
                    XCTAssertEqual(pieces.filter { $0.name?.hasPrefix("placement-region-") == true }.map(\.fillColor),
                                   Array(repeating: UIColor(CapyPalette.regionColors[4]).cgColor, count: 6))
                    XCTAssertFalse(burst.isUserInteractionEnabled); XCTAssertTrue(burst.accessibilityElementsHidden)
                    XCTAssertEqual(burst.backgroundColor, .clear)
                }
            }
        }
    }

    @MainActor func testOnlyNewCommittedFindsCreateBurstsAndRapidUpdatesKeepAtMostTwo() throws {
        let rig = try PlacementBurstRig(); defer { rig.close() }
        XCTAssertTrue(rig.bursts.isEmpty)
        for cell in [1, 7, 8] { rig.found.insert(cell); rig.refresh() }
        XCTAssertEqual(Set(rig.bursts.map(\.cellIndex)), [7, 8])
        let ids = rig.bursts.map(ObjectIdentifier.init)
        for _ in 0..<10 { rig.refresh() }
        XCTAssertEqual(rig.bursts.map(ObjectIdentifier.init), ids, "Unchanged SwiftUI refreshes must neither replay nor reset cleanup")
        XCTAssertEqual(rig.callbacks, 0); XCTAssertEqual(rig.found, [1, 7, 8])
        rig.id = UUID(); rig.refresh()
        XCTAssertTrue(rig.bursts.isEmpty, "A restored/new-session snapshot containing finds has no new celebration event")
        let restored = try PlacementBurstRig(); defer { restored.close() }
        restored.found = [1, 7]; restored.id = UUID(); restored.refresh()
        XCTAssertTrue(restored.bursts.isEmpty)
    }

    @MainActor func testCoalescedCorrectThenMistakeCancelsOldAndNewPositiveDecorationButNextCorrectStillResponds() throws {
        for reduced in [false, true] {
            for hasPreviousFind in [false, true] {
                let rig = try PlacementBurstRig(); defer { rig.close() }
                rig.reduced = reduced
                let puzzle = Puzzle(id: 1, size: 4, regions: rig.regions, solution: [1, 7, 8, 14],
                    seed: 11400714819535654101, generatorVersion: "original-pipeline-v3", difficulty: "easy")
                var session = GameSession(puzzle: puzzle)
                rig.refresh(session)
                if hasPreviousFind {
                    _ = session.submit(cell: 1); rig.refresh(session)
                }
                let previousEffects = rig.board.subviews.flatMap(\.subviews).filter {
                    ($0 as? BoardCellFeedbackView)?.kind == .found || $0 is BoardPlacementBurstView
                }
                let previousFoundCallbacks = rig.foundCallbacks, previousScoreCallbacks = rig.scoreCallbacks

                // Two real accepted actions arrive before the next UIView update.
                // The later mistake owns this frame, while both committed state
                // changes remain visible on the board and score counter.
                _ = session.submit(cell: 7)
                let earned = session.score
                _ = session.submit(cell: 0)
                rig.refresh(session)
                XCTAssertEqual(session.score, earned); XCTAssertEqual(session.lives, 2)
                XCTAssertEqual(session.found, hasPreviousFind ? [1, 7] : [7])
                XCTAssertEqual(rig.found, session.found); XCTAssertEqual(rig.score, earned)
                XCTAssertTrue(rig.bursts.isEmpty, "A coalesced correct action must not rebuild particles after damage cancels them.")
                XCTAssertFalse(rig.board.subviews.flatMap(\.subviews).contains { ($0 as? BoardCellFeedbackView)?.kind == .found },
                    "The happy pop, ring and local heart must also yield to the latest mistake.")
                XCTAssertTrue(rig.board.subviews.flatMap(\.subviews).contains { $0 is BoardMistakeFeedbackView })
                XCTAssertTrue(previousEffects.allSatisfy { $0.superview == nil && animations($0.layer).isEmpty })
                XCTAssertEqual(rig.foundCallbacks, previousFoundCallbacks)
                XCTAssertEqual(rig.scoreCallbacks, previousScoreCallbacks)
                rig.refresh(session)
                XCTAssertTrue(rig.bursts.isEmpty, "An ordinary refresh must not replay the suppressed reward.")

                _ = session.submit(cell: 8); rig.refresh(session)
                XCTAssertEqual(rig.foundCallbacks, previousFoundCallbacks + [8])
                XCTAssertEqual(rig.scoreCallbacks, previousScoreCallbacks + [session.score - earned])
                XCTAssertTrue(rig.board.subviews.flatMap(\.subviews).contains { ($0 as? BoardCellFeedbackView)?.kind == .found })
                XCTAssertEqual(rig.bursts.map(\.cellIndex), reduced ? [] : [8])
                XCTAssertEqual(rig.callbacks, 0, "Presentation may not submit, mark or toggle another gameplay action.")
            }
        }
    }

    @MainActor func testCoalescedMoveOrderUsesLatestModelResultAndNeverReplaysOnOrdinaryRefresh() throws {
        for reduced in [false, true] {
            for lastSucceeded in [false, true] {
                let rig = try PlacementBurstRig(); defer { rig.close() }
                rig.reduced = reduced
                let puzzle = Puzzle(id: 1, size: 4, regions: rig.regions, solution: [1, 7, 8, 14],
                    seed: 11400714819535654101, generatorVersion: "original-pipeline-v3", difficulty: "easy")
                var session = GameSession(puzzle: puzzle)
                rig.refresh(session)
                _ = session.submit(cell: 1); rig.latestSubmissionSucceeded = true; rig.refresh(session)
                let older = rig.board.subviews.flatMap(\.subviews).filter {
                    ($0 as? BoardCellFeedbackView)?.kind == .found || $0 is BoardPlacementBurstView
                }
                let beforeScore = session.score
                for cell in lastSucceeded ? [0, 7] : [7, 0] { _ = session.submit(cell: cell) }
                rig.latestSubmissionSucceeded = session.combo > 0
                rig.refresh(session)
                XCTAssertEqual(session.lives, 2); XCTAssertEqual(session.found, [1, 7])
                XCTAssertEqual((rig.board.accessibilityElements?[1] as? UIAccessibilityElement)?.accessibilityValue, "found")
                XCTAssertEqual((rig.board.accessibilityElements?[7] as? UIAccessibilityElement)?.accessibilityValue, "found")
                XCTAssertEqual((rig.board.accessibilityElements?[0] as? UIAccessibilityElement)?.accessibilityValue, "error")
                XCTAssertTrue(older.allSatisfy { $0.superview == nil && animations($0.layer).isEmpty })
                let current = rig.board.subviews.flatMap(\.subviews)
                XCTAssertEqual(current.compactMap { $0 as? BoardCellFeedbackView }.filter { $0.kind == .found }.map(\.cellIndex), lastSucceeded ? [7] : [])
                XCTAssertEqual(current.compactMap { $0 as? BoardMistakeFeedbackView }.map(\.cellIndex), lastSucceeded ? [] : [0])
                XCTAssertEqual(rig.bursts.map(\.cellIndex), lastSucceeded && !reduced ? [7] : [])
                XCTAssertEqual(rig.foundCallbacks, lastSucceeded ? [1, 7] : [1])
                XCTAssertEqual(rig.scoreCallbacks, lastSucceeded ? [beforeScore, session.score - beforeScore] : [beforeScore])
                let identities = current.map(ObjectIdentifier.init)
                rig.refresh(session)
                XCTAssertEqual(rig.board.subviews.flatMap(\.subviews).map(ObjectIdentifier.init), identities,
                    "A clock/layout refresh must preserve the current presentation without replaying either action.")
                XCTAssertEqual(rig.foundCallbacks, lastSucceeded ? [1, 7] : [1])
            }
        }
    }

    @MainActor func testCoalescedOrderFallsBackToActualPendingSubmissionAndUnknownOrderPrefersDamage() throws {
        for source in ["pending", "unknown"] {
            for lastSucceeded in [false, true] {
                let rig = try PlacementBurstRig(); defer { rig.close() }
                let puzzle = Puzzle(id: 1, size: 4, regions: rig.regions, solution: [1, 7, 8, 14],
                    seed: 11400714819535654101, generatorVersion: "original-pipeline-v3", difficulty: "easy")
                var session = GameSession(puzzle: puzzle)
                rig.refresh(session)
                rig.deferredSubmit = { cell in _ = session.submit(cell: cell) }
                for cell in lastSucceeded ? [0, 7] : [7, 0] {
                    if source == "pending" { XCTAssertTrue(rig.board.activate(index: cell, submit: true)) }
                    else { _ = session.submit(cell: cell) }
                }
                rig.refresh(session)
                let shouldCelebrate = source == "pending" && lastSucceeded
                XCTAssertEqual(rig.bursts.map(\.cellIndex), shouldCelebrate ? [7] : [])
                XCTAssertEqual(rig.foundCallbacks, shouldCelebrate ? [7] : [])
                XCTAssertEqual(rig.board.subviews.flatMap(\.subviews).compactMap { $0 as? BoardMistakeFeedbackView }.map(\.cellIndex), shouldCelebrate ? [] : [0])
                XCTAssertEqual(session.found, [7]); XCTAssertEqual(session.lives, 2)
                let ids = rig.board.subviews.flatMap(\.subviews).map(ObjectIdentifier.init)
                rig.refresh(session)
                XCTAssertEqual(rig.board.subviews.flatMap(\.subviews).map(ObjectIdentifier.init), ids)
                XCTAssertEqual(rig.callbacks, source == "pending" ? 2 : 0)
            }
        }
    }

    @MainActor func testCoalescedMistakeThenFinalCorrectKeepsLastCellAndWholeBoardVictory() throws {
        let rig = try PlacementBurstRig(); defer { rig.close() }
        let puzzle = Puzzle(id: 1, size: 4, regions: rig.regions, solution: [1, 7, 8, 14],
            seed: 11400714819535654101, generatorVersion: "original-pipeline-v3", difficulty: "easy")
        var session = GameSession(puzzle: puzzle)
        rig.refresh(session)
        for cell in [1, 7, 8] { _ = session.submit(cell: cell) }
        rig.latestSubmissionSucceeded = true; rig.refresh(session)
        _ = session.submit(cell: 0); _ = session.submit(cell: 14)
        rig.locked = true; rig.hidden = true
        rig.latestSubmissionSucceeded = session.combo > 0; rig.refresh(session)
        XCTAssertEqual(session.status, .won); XCTAssertEqual(session.lives, 2)
        XCTAssertEqual(session.found, [1, 7, 8, 14])
        let current = rig.board.subviews.flatMap(\.subviews)
        XCTAssertEqual(current.compactMap { $0 as? BoardCellFeedbackView }.filter { $0.kind == .found }.map(\.cellIndex), [14])
        XCTAssertEqual(rig.bursts.map(\.cellIndex), [14])
        XCTAssertEqual(current.compactMap { $0 as? BoardSceneFeedbackView }.map(\.kind), [.victory])
        XCTAssertFalse(current.contains { $0 is BoardMistakeFeedbackView })
        XCTAssertEqual(rig.foundCallbacks, [1, 7, 8, 14])
        let ids = current.map(ObjectIdentifier.init)
        rig.refresh(session)
        XCTAssertEqual(rig.board.subviews.flatMap(\.subviews).map(ObjectIdentifier.init), ids)
        XCTAssertEqual(rig.foundCallbacks, [1, 7, 8, 14])
    }

    @MainActor func testCoveringBackgroundPolicyAndBoardReplacementCancelWithoutGameplayCallbacks() throws {
        for boundary in ["lock", "hidden", "preview", "disabled", "reduced", "background", "power", "resize", "remove"] {
            let rig = try PlacementBurstRig(); defer { rig.close() }
            rig.found = [1]; rig.refresh(); XCTAssertEqual(rig.bursts.count, 1, boundary)
            let burst = try XCTUnwrap(rig.bursts.first)
            switch boundary {
            case "lock": rig.locked = true; rig.refresh()
            case "hidden": rig.hidden = true; rig.refresh()
            case "preview": rig.preview = [0]; rig.refresh()
            case "disabled": rig.enabled = false; rig.refresh()
            case "reduced": rig.reduced = true; rig.refresh()
            case "background": NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            case "power": NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            case "resize": rig.board.frame.size = CGSize(width: 280, height: 280); rig.board.layoutIfNeeded()
            default: rig.board.removeFromSuperview()
            }
            XCTAssertTrue(rig.bursts.isEmpty, boundary); XCTAssertTrue(animations(burst.layer).isEmpty, boundary)
            XCTAssertEqual(rig.found, [1]); XCTAssertEqual(rig.callbacks, 0)
            if boundary == "background" { NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil) }
        }
        let reduced = try PlacementBurstRig(); defer { reduced.close() }
        reduced.reduced = true; reduced.refresh(); reduced.found = [1]; reduced.refresh()
        XCTAssertTrue(reduced.bursts.isEmpty)
    }

    @MainActor func testFiniteCleanupAndReplayedInstanceCannotBeRemovedByOldDeadline() async throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        let burst = make(side: 320, size: 4, cell: 5)
        host.addSubview(burst); burst.play()
        XCTAssertTrue(animations(burst.layer).allSatisfy { $0.duration == burst.duration && $0.repeatCount == 0 })
        try await Task.sleep(nanoseconds: 300_000_000)
        burst.removeFromSuperview(); XCTAssertTrue(animations(burst.layer).isEmpty)
        host.addSubview(burst); burst.play()
        try await Task.sleep(nanoseconds: 390_000_000)
        XCTAssertTrue(burst.superview === host)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(burst.superview); XCTAssertTrue(animations(burst.layer).isEmpty)
    }

    @MainActor func testActualBoardCapturesExpandingAndFallingParticlesThenCleanBoard() async throws {
        let rig = try PlacementBurstRig(); defer { rig.close() }
        rig.found = [1]; rig.refresh()
        for (delay, name) in [(100_000_000, "placement-burst-100ms"), (180_000_000, "placement-burst-280ms"),
                              (200_000_000, "placement-burst-480ms"), (250_000_000, "placement-burst-730ms-clean")] {
            try await Task.sleep(nanoseconds: UInt64(delay))
            let image = UIGraphicsImageRenderer(bounds: rig.board.bounds).image {
                (rig.board.layer.presentation() ?? rig.board.layer).render(in: $0.cgContext)
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertTrue(rig.bursts.isEmpty); XCTAssertEqual(rig.found, [1]); XCTAssertEqual(rig.callbacks, 0)
    }
}
