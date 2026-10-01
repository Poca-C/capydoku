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
    var callbacks = 0
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
        board.configure(size: 4, regions: regions, found: found, marks: [], errors: [], preview: preview,
            sessionID: id, lives: 3, effectsEnabled: enabled, reduceMotion: reduced,
            tutorialTargets: [], locked: locked, hideAccessibility: hidden,
            onToggle: { [weak self] _ in self?.callbacks += 1 },
            onSubmit: { [weak self] _ in self?.callbacks += 1 }, onMark: { [weak self] _ in self?.callbacks += 1 })
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
