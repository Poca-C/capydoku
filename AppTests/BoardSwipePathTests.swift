import XCTest
import UIKit
import UIKit.UIGestureRecognizerSubclass
@testable import Capydoku

/// Injects recognizer samples into the actual native board handler. These tests
/// exercise its path/geometry and callbacks, not UIKit's touch recognition timing.
@MainActor private final class SampledPanRecognizer: UIPanGestureRecognizer {
    var sampleState: UIGestureRecognizer.State = .possible
    var sampleLocation = CGPoint.zero
    var sampleTranslation = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { sampleState }
        set { sampleState = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { sampleLocation }
    override func translation(in view: UIView?) -> CGPoint { sampleTranslation }
}

@MainActor private final class SwipePathRig {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let board = PuzzleGridUIView(frame: CGRect(x: 0, y: 0, width: 334, height: 334))
    let pan = SampledPanRecognizer()
    var marked: [Int] = []
    var beganCount = 0
    var endedCancelled: [Bool] = []
    private var origin = CGPoint.zero
    private let sessionID = UUID()
    private let found: Set<Int>
    var tutorialTargets = Set<Int>()
    var tutorialStepID: String?

    init(found: Set<Int> = []) {
        self.found = found
        window.addSubview(board)
        refresh()
        board.layoutIfNeeded()
    }

    func refresh() {
        board.configure(size: 4, regions: (0..<16).map { $0 / 4 }, found: found,
                        marks: Set(marked), errors: [], preview: [], sessionID: sessionID, lives: 3,
                        effectsEnabled: false, tutorialTargets: tutorialTargets,
                        tutorialAction: tutorialStepID == nil ? nil : "exclude", tutorialStepID: tutorialStepID, locked: false,
                        onToggle: { _ in XCTFail("A pan must not invoke the tap callback.") },
                        onSubmit: { _ in XCTFail("A pan must not submit a capybara.") },
                        onMark: { [weak self] in self?.marked.append(contentsOf: $0) },
                        onBeginSwipe: { [weak self] in self?.beganCount += 1 },
                        onEndSwipe: { [weak self] in self?.endedCancelled.append($0) })
    }

    func center(_ index: Int) -> CGPoint {
        let element = board.accessibilityElements![index] as! UIAccessibilityElement
        let frame = element.accessibilityFrameInContainerSpace
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func begin(at index: Int, horizontal: Bool) {
        origin = center(index)
        send(.began, to: CGPoint(x: origin.x + (horizontal ? 20 : 0),
                                y: origin.y + (horizontal ? 0 : 20)))
    }

    func begin(from origin: CGPoint, to location: CGPoint) {
        self.origin = origin
        send(.began, to: location)
    }

    func send(_ state: UIGestureRecognizer.State, to index: Int) { send(state, to: center(index)) }

    func send(_ state: UIGestureRecognizer.State, to location: CGPoint) {
        pan.sampleState = state
        pan.sampleLocation = location
        pan.sampleTranslation = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        let selector = NSSelectorFromString("pan:")
        XCTAssertTrue(board.responds(to: selector))
        _ = board.perform(selector, with: pan)
    }

    func close() { board.removeFromSuperview() }
}

final class BoardSwipePathTests: XCTestCase {
    @MainActor func testTeachingStrokeStopsAtItsOwnTargetsBeforeDelayedUIRefresh() {
        let rig = SwipePathRig(); defer { rig.close() }
        rig.tutorialTargets = [0, 1]; rig.tutorialStepID = "attempt:v3:first"; rig.refresh()
        rig.begin(at: 0, horizontal: true)
        rig.send(.changed, to: 1)
        // Deliberately withhold configure: a SwiftUI coalesced update must not
        // let the still-held finger start work belonging to the next instruction.
        rig.send(.changed, to: 2); rig.send(.ended, to: 3)
        XCTAssertEqual(rig.marked, [0, 1]); XCTAssertEqual(rig.endedCancelled, [false])
        rig.tutorialTargets = [2, 3]; rig.tutorialStepID = "attempt:v3:second"; rig.refresh()
        rig.send(.changed, to: 3)
        XCTAssertEqual(rig.marked, [0, 1], "A stale sample cannot become a new gesture after a step change.")
        rig.begin(at: 2, horizontal: true); rig.send(.ended, to: 3)
        XCTAssertEqual(rig.marked, [0, 1, 2, 3]); XCTAssertEqual(rig.beganCount, 2)
    }

    @MainActor func testTeachingIdentityChangeCancelsPartialStrokeButSameStepRefreshDoesNot() {
        let rig = SwipePathRig(); defer { rig.close() }
        rig.tutorialTargets = [0, 1, 2]; rig.tutorialStepID = "attempt:v3:old"; rig.refresh()
        rig.begin(at: 0, horizontal: true)
        rig.refresh(); rig.send(.changed, to: 1)
        XCTAssertEqual(rig.marked, [0, 1], "Saving a partial swipe within one step must keep it alive.")
        rig.tutorialTargets = [2, 3]; rig.tutorialStepID = "attempt:v3:new"; rig.refresh()
        rig.send(.changed, to: 2); rig.send(.ended, to: 3)
        XCTAssertEqual(rig.marked, [0, 1]); XCTAssertEqual(rig.endedCancelled, [true])
        rig.begin(at: 2, horizontal: true); rig.send(.ended, to: 3)
        XCTAssertEqual(rig.marked, [0, 1, 2, 3]); XCTAssertEqual(rig.endedCancelled, [true, false])
    }

    @MainActor func testHorizontalSwipeMarksPassedCellsOnlyOnceIncludingReverseTravel() {
        let rig = SwipePathRig(); defer { rig.close() }
        rig.begin(at: 0, horizontal: true)
        rig.send(.changed, to: 2)
        rig.send(.changed, to: 1)
        rig.send(.ended, to: 3)
        XCTAssertEqual(rig.marked, [0, 1, 2, 3])
        XCTAssertEqual(rig.beganCount, 1)
        XCTAssertEqual(rig.endedCancelled, [false])
    }

    @MainActor func testVerticalSwipeMarksPassedCellsOnlyOnceIncludingReverseTravel() {
        let rig = SwipePathRig(); defer { rig.close() }
        rig.begin(at: 0, horizontal: false)
        rig.send(.changed, to: 8)
        rig.send(.changed, to: 4)
        rig.send(.ended, to: 12)
        XCTAssertEqual(rig.marked, [0, 4, 8, 12])
        XCTAssertEqual(rig.beganCount, 1)
        XCTAssertEqual(rig.endedCancelled, [false])
    }

    @MainActor func testHorizontalTurnStopsWithoutProjectingOrRestartingOnReentry() {
        let rig = SwipePathRig(); defer { rig.close() }
        rig.begin(at: 0, horizontal: true)
        rig.send(.changed, to: 1)
        rig.send(.changed, to: 6) // Another row; never mark projected cell 2.
        rig.send(.changed, to: 7)
        rig.send(.changed, to: 3) // Reentering the original row is still this stroke.
        rig.send(.ended, to: 3)
        XCTAssertEqual(rig.marked, [0, 1], "Previously traversed cells stay marked; a turn cannot create projected Xs.")
        XCTAssertEqual(rig.beganCount, 1)
        XCTAssertEqual(rig.endedCancelled, [true])
        rig.begin(at: 2, horizontal: true)
        rig.send(.ended, to: 3)
        XCTAssertEqual(rig.marked, [0, 1, 2, 3], "A new touch may begin a new legal stroke.")
        XCTAssertEqual(rig.endedCancelled, [true, false])
    }

    @MainActor func testVerticalTurnStopsWithoutProjectingOrRestartingOnReentry() {
        let rig = SwipePathRig(); defer { rig.close() }
        rig.begin(at: 0, horizontal: false)
        rig.send(.changed, to: 4)
        rig.send(.changed, to: 9) // Another column; never mark projected cell 8.
        rig.send(.changed, to: 13)
        rig.send(.changed, to: 12)
        rig.send(.ended, to: 12)
        XCTAssertEqual(rig.marked, [0, 4])
        XCTAssertEqual(rig.beganCount, 1)
        XCTAssertEqual(rig.endedCancelled, [true])
    }

    @MainActor func testFoundCapybaraCannotStartEitherAxisOfSwipe() {
        for horizontal in [true, false] {
            let rig = SwipePathRig(found: [0]); defer { rig.close() }
            rig.begin(at: 0, horizontal: horizontal)
            rig.send(.changed, to: horizontal ? 2 : 8)
            rig.send(.ended, to: horizontal ? 3 : 12)
            XCTAssertTrue(rig.marked.isEmpty)
            XCTAssertEqual(rig.beganCount, 0)
            XCTAssertTrue(rig.endedCancelled.isEmpty)
        }
    }

    @MainActor func testLegalSwipeCanCrossFoundCellWithoutOverwritingIt() {
        let rig = SwipePathRig(found: [1]); defer { rig.close() }
        rig.begin(at: 0, horizontal: true)
        rig.send(.ended, to: 3)
        XCTAssertEqual(rig.marked, [0, 2, 3])
        XCTAssertEqual(rig.endedCancelled, [false])
    }

    @MainActor func testInitiallyDiagonalSwipeDoesNotBecomeAnAxisSwipeLater() {
        let rig = SwipePathRig(); defer { rig.close() }
        rig.begin(from: rig.center(0), to: rig.center(5))
        rig.send(.changed, to: 3)
        rig.send(.ended, to: 3)
        XCTAssertTrue(rig.marked.isEmpty)
        XCTAssertEqual(rig.beganCount, 0)
        XCTAssertTrue(rig.endedCancelled.isEmpty)
    }

    @MainActor func testLeavingBoardStopsStrokeAndReentryCannotFillTheGap() {
        let rig = SwipePathRig(); defer { rig.close() }
        rig.begin(at: 0, horizontal: true)
        rig.send(.changed, to: 1)
        rig.send(.changed, to: CGPoint(x: rig.board.bounds.maxX + 10, y: rig.center(0).y))
        rig.send(.ended, to: 3)
        XCTAssertEqual(rig.marked, [0, 1])
        XCTAssertEqual(rig.endedCancelled, [true])
    }

    @MainActor func testBeginningOutsideBoardNeverCreatesMarksAfterEntering() {
        let rig = SwipePathRig(); defer { rig.close() }
        rig.begin(from: CGPoint(x: -10, y: rig.center(0).y), to: rig.center(0))
        rig.send(.changed, to: 2)
        rig.send(.ended, to: 3)
        XCTAssertTrue(rig.marked.isEmpty)
        XCTAssertEqual(rig.beganCount, 0)
    }

    @MainActor func testCancelledStrokeKeepsPriorMarksAndEndsFeedbackOnlyOnce() {
        let rig = SwipePathRig(); defer { rig.close() }
        rig.begin(at: 0, horizontal: true)
        rig.send(.changed, to: 1)
        rig.send(.cancelled, to: 2)
        rig.send(.changed, to: 3)
        rig.send(.ended, to: 3)
        XCTAssertEqual(rig.marked, [0, 1])
        XCTAssertEqual(rig.endedCancelled, [true])
    }
}
