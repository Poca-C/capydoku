import XCTest
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class BoardRefreshRig {
    let window: UIWindow
    let board = PuzzleGridUIView(frame: CGRect(x: 20, y: 100, width: 320, height: 320))
    private let previous: UIWindow?
    var size = 10
    var regions = (0..<100).map { $0 / 10 }
    var sessionID = UUID()
    var entranceID: UUID?
    var found = Set<Int>(), marks = Set<Int>(), errors = Set<Int>(), preview = Set<Int>(), targets = Set<Int>()
    var action: String?
    var locked = false, hidden = false, effectsEnabled = false
    var language = AppLanguage.simplifiedChinese
    var score = 0, lives = 3
    var onToggle: (Int) -> Void = { _ in }
    var onSubmit: (Int) -> Void = { _ in }

    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
        refresh(); controller.view.addSubview(board); board.layoutIfNeeded()
    }
    func refresh() {
        board.configure(size: size, regions: regions, found: found, marks: marks, errors: errors, preview: preview,
            sessionID: sessionID, entranceID: entranceID, lives: lives, score: score, effectsEnabled: effectsEnabled,
            reduceMotion: true, tutorialTargets: targets, tutorialAction: action, locked: locked,
            hideAccessibility: hidden, language: language, onToggle: onToggle, onSubmit: onSubmit, onMark: { _ in })
    }
    func cells() throws -> [UIAccessibilityElement] { try XCTUnwrap(board.accessibilityElements as? [UIAccessibilityElement]) }
    func close() {
        board.cancelPresentation(); board.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
    }
}

final class BoardRefreshEfficiencyTests: XCTestCase {
    @MainActor func testUnchangedAndHUDOnlyConfigurationsKeepActionsAndPixelsButAlwaysReplaceCallbacks() throws {
        let rig = try BoardRefreshRig(); defer { rig.close() }
        let elements = try rig.cells(), action = try XCTUnwrap(elements[37].accessibilityCustomActions?.first)
        let before = rig.board.refreshDiagnostics
        for index in 0..<500 {
            rig.score = index; rig.lives = index.isMultiple(of: 2) ? 2 : 3
            rig.refresh()
        }
        let after = rig.board.refreshDiagnostics
        XCTAssertEqual(after.configurations - before.configurations, 500)
        XCTAssertEqual(after.accessibilityPasses, before.accessibilityPasses)
        XCTAssertEqual(after.updatedAccessibilityCells, before.updatedAccessibilityCells)
        XCTAssertEqual(after.customActionsCreated, before.customActionsCreated)
        XCTAssertEqual(after.displayInvalidations, before.displayInvalidations)
        XCTAssertTrue(try rig.cells()[37] === elements[37])
        XCTAssertTrue(try rig.cells()[37].accessibilityCustomActions?.first === action)
        var firstCallback = 0, currentCallback = 0, currentSubmit = 0
        rig.onToggle = { _ in firstCallback += 1 }; rig.refresh()
        rig.onToggle = { _ in currentCallback += 1 }; rig.onSubmit = { _ in currentSubmit += 1 }; rig.refresh()
        XCTAssertTrue(rig.board.activate(index: 37, submit: false))
        XCTAssertTrue(rig.board.activate(index: 38, submit: true))
        XCTAssertEqual(firstCallback, 0); XCTAssertEqual(currentCallback, 1); XCTAssertEqual(currentSubmit, 1)
    }

    @MainActor func testCellChangesUpdateOnlyAffectedSpokenStateAndStillInvalidateTheBoard() throws {
        let rig = try BoardRefreshRig(); defer { rig.close() }
        let elements = try rig.cells(), untouchedAction = try XCTUnwrap(elements[20].accessibilityCustomActions?.first)
        var before = rig.board.refreshDiagnostics
        rig.marks = [37]; rig.refresh()
        XCTAssertEqual(elements[37].accessibilityValue, "marked")
        XCTAssertEqual(rig.board.refreshDiagnostics.updatedAccessibilityCells - before.updatedAccessibilityCells, 1)
        XCTAssertEqual(rig.board.refreshDiagnostics.customActionsCreated - before.customActionsCreated, 2)
        XCTAssertEqual(rig.board.refreshDiagnostics.displayInvalidations - before.displayInvalidations, 1)
        XCTAssertTrue(elements[20].accessibilityCustomActions?.first === untouchedAction)
        before = rig.board.refreshDiagnostics
        rig.found = [47]; rig.errors = [58]; rig.refresh()
        XCTAssertEqual(elements[47].accessibilityValue, "found"); XCTAssertNil(elements[47].accessibilityCustomActions)
        XCTAssertEqual(elements[58].accessibilityValue, "error")
        XCTAssertEqual(rig.board.refreshDiagnostics.updatedAccessibilityCells - before.updatedAccessibilityCells, 2)
        before = rig.board.refreshDiagnostics
        rig.marks = []; rig.errors = []; rig.refresh()
        XCTAssertEqual(elements[37].accessibilityValue, "empty"); XCTAssertEqual(elements[58].accessibilityValue, "empty")
        XCTAssertEqual(rig.board.refreshDiagnostics.updatedAccessibilityCells - before.updatedAccessibilityCells, 2)
        XCTAssertTrue(elements[20].accessibilityCustomActions?.first === untouchedAction)
    }

    @MainActor func testPreviewTutorialLanguageLockAndVisibilityRemainImmediate() throws {
        let rig = try BoardRefreshRig(); defer { rig.close() }
        let elements = try rig.cells()
        rig.preview = [1, 2]; rig.refresh()
        XCTAssertTrue(elements[1].accessibilityHint?.contains(rig.language.text("Hint preview.")) == true)
        rig.preview = []; rig.targets = [4]; rig.action = "tap"; rig.refresh()
        XCTAssertFalse(elements[1].accessibilityHint?.contains(rig.language.text("Hint preview.")) == true)
        XCTAssertTrue(elements[4].accessibilityHint?.contains(rig.language.text("Tutorial target.")) == true)
        let firstGuide = try XCTUnwrap(rig.board.subviews.flatMap(\.subviews).first { $0 is BoardTutorialGuideView })
        rig.action = "doubleTap"; rig.refresh()
        let secondGuide = try XCTUnwrap(rig.board.subviews.flatMap(\.subviews).first { $0 is BoardTutorialGuideView })
        XCTAssertFalse(firstGuide === secondGuide, "Tutorial action changes still rebuild the actual guide")
        var before = rig.board.refreshDiagnostics
        rig.language = .english; rig.refresh()
        XCTAssertEqual(elements[4].accessibilityLabel, "Row 1, column 5, region 1")
        XCTAssertEqual(rig.board.refreshDiagnostics.updatedAccessibilityCells - before.updatedAccessibilityCells, 100)
        before = rig.board.refreshDiagnostics
        rig.locked = true; rig.refresh()
        XCTAssertTrue(elements.allSatisfy { $0.accessibilityCustomActions == nil && $0.accessibilityTraits.contains(.notEnabled) })
        XCTAssertTrue(elements[4].accessibilityHint?.contains("Read-only board preview.") == true)
        XCTAssertEqual(rig.board.refreshDiagnostics.updatedAccessibilityCells - before.updatedAccessibilityCells, 100)
        before = rig.board.refreshDiagnostics
        rig.hidden = true; rig.refresh(); XCTAssertTrue(try rig.cells().isEmpty)
        rig.hidden = false; rig.refresh()
        XCTAssertTrue(try rig.cells()[4] === elements[4])
        XCTAssertEqual(rig.board.refreshDiagnostics.updatedAccessibilityCells, before.updatedAccessibilityCells)
        rig.locked = false; rig.refresh(); XCTAssertNotNil(elements[4].accessibilityCustomActions)
    }

    @MainActor func testResizeRegionAndSessionChangesRefreshGeometryAndDoNotReuseStaleCellState() throws {
        let rig = try BoardRefreshRig(); defer { rig.close() }
        let elements = try rig.cells(), originalFrame = elements[99].accessibilityFrameInContainerSpace
        let beforeResize = rig.board.refreshDiagnostics
        rig.board.bounds.size = CGSize(width: 210, height: 210); rig.board.setNeedsLayout(); rig.board.layoutIfNeeded()
        XCTAssertNotEqual(elements[99].accessibilityFrameInContainerSpace, originalFrame)
        XCTAssertLessThanOrEqual(elements[99].accessibilityFrameInContainerSpace.maxX, rig.board.bounds.maxX)
        XCTAssertEqual(rig.board.refreshDiagnostics.geometryCellUpdates - beforeResize.geometryCellUpdates, 100)
        XCTAssertEqual(rig.board.refreshDiagnostics.customActionsCreated, beforeResize.customActionsCreated)
        let beforeRegion = rig.board.refreshDiagnostics
        rig.regions = Array(repeating: 7, count: 100); rig.refresh()
        XCTAssertTrue(elements[0].accessibilityLabel?.contains("8") == true)
        XCTAssertEqual(rig.board.refreshDiagnostics.updatedAccessibilityCells - beforeRegion.updatedAccessibilityCells, 100)
        rig.marks = [0]; rig.refresh()
        let beforeSession = rig.board.refreshDiagnostics
        rig.sessionID = UUID(); rig.marks = []; rig.refresh()
        XCTAssertEqual(elements[0].accessibilityValue, "empty")
        XCTAssertEqual(rig.board.refreshDiagnostics.updatedAccessibilityCells - beforeSession.updatedAccessibilityCells, 100)
        rig.size = 6; rig.regions = (0..<36).map { $0 / 6 }; rig.sessionID = UUID(); rig.refresh(); rig.board.layoutIfNeeded()
        let small = try rig.cells(); XCTAssertEqual(small.count, 36)
        XCTAssertFalse(small[0] === elements[0])
        XCTAssertTrue(small[35].accessibilityLabel?.contains("6") == true)
        XCTAssertEqual(small[35].accessibilityFrameInContainerSpace.maxX, 203, accuracy: 0.001)
    }

    @MainActor func testUIViewDiagnosticRecordsNoChangeAndSingleCellConfigureCostWithoutADeviceTimingClaim() throws {
        let rig = try BoardRefreshRig(); defer { rig.close() }
        func samples(_ update: (Int) -> Void) -> [Double] {
            (0..<200).map { index in
                update(index)
                let start = DispatchTime.now().uptimeNanoseconds; rig.refresh()
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }.sorted()
        }
        let before = rig.board.refreshDiagnostics
        let unchanged = samples { _ in }
        let idle = rig.board.refreshDiagnostics
        let changed = samples { index in rig.marks = index.isMultiple(of: 2) ? [55] : [] }
        let final = rig.board.refreshDiagnostics
        XCTAssertEqual(idle.updatedAccessibilityCells, before.updatedAccessibilityCells)
        XCTAssertEqual(idle.displayInvalidations, before.displayInvalidations)
        XCTAssertEqual(final.updatedAccessibilityCells - idle.updatedAccessibilityCells, 200)
        XCTAssertEqual(final.displayInvalidations - idle.displayInvalidations, 200)
        let record: [String: Any] = [
            "scope": "Actual PuzzleGridUIView configure on the test host; no display commit; simulator timing is not physical iPhone frame timing",
            "boardSize": 10, "sampleCountPerCase": 200,
            "unchangedMedianMs": unchanged[100], "unchangedP95Ms": unchanged[190],
            "singleCellMedianMs": changed[100], "singleCellP95Ms": changed[190],
            "unchangedAccessibilityCells": idle.updatedAccessibilityCells - before.updatedAccessibilityCells,
            "changedAccessibilityCells": final.updatedAccessibilityCells - idle.updatedAccessibilityCells,
            "unchangedDisplayRequests": idle.displayInvalidations - before.displayInvalidations,
            "changedDisplayRequests": final.displayInvalidations - idle.displayInvalidations
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "board-refresh-actual-uiview-efficiency-diagnostic"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
