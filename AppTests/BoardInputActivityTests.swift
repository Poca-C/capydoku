import XCTest
import UIKit
@testable import Capydoku

final class BoardInputActivityTests: XCTestCase {
    @MainActor func testTapWaitStaysBusyUntilEveryRecognizerResets() {
        let activity = BoardInputActivity()
        let single = UUID(), double = UUID(), pan = UUID()
        let ownerID = activity.ownerID
        var changes: [Bool] = []
        activity.onChange = { owner, busy in
            XCTAssertEqual(owner, ownerID)
            changes.append(busy)
        }

        activity.begin(single); activity.begin(double); activity.begin(pan)
        // Finger-up can fail the pan while the tap recognizers are still
        // waiting for the system double-tap decision. It must not release us.
        activity.end(pan)
        XCTAssertTrue(activity.isBusy)
        XCTAssertEqual(changes, [true])
        activity.begin(double) // A second touch in the same recognition attempt.
        activity.end(double)
        XCTAssertTrue(activity.isBusy, "The dependent single-tap attempt still owns its barrier")
        activity.end(single)
        XCTAssertFalse(activity.isBusy)
        XCTAssertEqual(changes, [true, false])
    }

    @MainActor func testPanOutlivesBothFailedTapRecognizersAndDuplicateResets() {
        let activity = BoardInputActivity()
        let single = UUID(), double = UUID(), pan = UUID()
        var changes: [Bool] = []
        activity.onChange = { _, busy in changes.append(busy) }
        activity.begin(single); activity.begin(double); activity.begin(pan)
        activity.end(single); activity.end(double); activity.end(double)
        XCTAssertTrue(activity.isBusy)
        XCTAssertEqual(changes, [true])
        activity.end(pan); activity.end(pan)
        XCTAssertEqual(changes, [true, false])
    }

    @MainActor func testCancelledOldBoardCannotReleaseReplacementBoard() {
        let old = BoardInputActivity(), replacement = BoardInputActivity()
        let oldRecognizer = UUID(), replacementRecognizer = UUID()
        var owners = Set<UUID>()
        let receive: (UUID, Bool) -> Void = { owner, busy in
            if busy { owners.insert(owner) } else { owners.remove(owner) }
        }
        old.onChange = receive; replacement.onChange = receive
        old.begin(oldRecognizer); replacement.begin(replacementRecognizer)
        XCTAssertEqual(owners.count, 2)
        old.cancelAll(); old.end(oldRecognizer); old.cancelAll()
        XCTAssertEqual(owners, [replacement.ownerID])
        replacement.end(replacementRecognizer)
        XCTAssertTrue(owners.isEmpty)
    }

    @MainActor func testNormalBoardUpdatesPreserveActivityButLockCancelsIt() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let board = PuzzleGridUIView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        window.addSubview(board)
        defer { board.removeFromSuperview() }
        let session = UUID(), recognizer = UUID()
        var changes: [Bool] = []
        let receive: (UUID, Bool) -> Void = { _, busy in changes.append(busy) }
        configure(board, session: session, receive: receive)
        XCTAssertEqual(board.gestureRecognizers?.count, 2)
        XCTAssertTrue(board.gestureRecognizers?.allSatisfy(\.isEnabled) == true)
        // Inject the ledger transition, not a fabricated UITouch. Actual
        // recognizer timing and the dependency relationship need UI tests.
        board.inputActivity.begin(recognizer)
        configure(board, session: session, marks: [0], receive: receive)
        XCTAssertTrue(board.inputActivity.isBusy)
        XCTAssertEqual(changes, [true])
        configure(board, session: session, locked: true, marks: [0], receive: receive)
        XCTAssertFalse(board.inputActivity.isBusy)
        XCTAssertTrue(board.gestureRecognizers?.allSatisfy { !$0.isEnabled } == true)
        XCTAssertEqual(changes, [true, false])
        configure(board, session: session, receive: receive)
        XCTAssertTrue(board.gestureRecognizers?.allSatisfy(\.isEnabled) == true)
        board.inputActivity.begin(recognizer); board.inputActivity.end(recognizer)
        XCTAssertEqual(changes, [true, false, true, false])
    }

    @MainActor func testReplacingSessionCancelsOldAttemptAndKeepsBoardOwnerStable() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let board = PuzzleGridUIView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        window.addSubview(board)
        defer { board.removeFromSuperview() }
        let owner = board.inputActivity.ownerID
        var changes: [Bool] = []
        let receive: (UUID, Bool) -> Void = { id, busy in
            XCTAssertEqual(id, owner)
            changes.append(busy)
        }
        configure(board, session: UUID(), receive: receive)
        board.inputActivity.begin(UUID())
        configure(board, session: UUID(), receive: receive)
        XCTAssertFalse(board.inputActivity.isBusy)
        XCTAssertEqual(board.inputActivity.ownerID, owner)
        XCTAssertEqual(changes, [true, false])
        XCTAssertTrue(board.gestureRecognizers?.allSatisfy(\.isEnabled) == true)
    }

    @MainActor func testLeavingWindowAndDismantlingReleaseOnlyOnce() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let board = PuzzleGridUIView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        window.addSubview(board)
        var changes: [Bool] = []
        configure(board, session: UUID()) { _, busy in changes.append(busy) }
        board.inputActivity.begin(UUID())
        board.removeFromSuperview()
        PuzzleBoardView.dismantleUIView(board, coordinator: ())
        XCTAssertFalse(board.inputActivity.isBusy)
        XCTAssertEqual(changes, [true, false])
        XCTAssertTrue(board.gestureRecognizers?.allSatisfy { !$0.isEnabled } == true)
    }

    @MainActor private func configure(_ board: PuzzleGridUIView, session: UUID,
                                      locked: Bool = false, marks: Set<Int> = [],
                                      receive: @escaping (UUID, Bool) -> Void) {
        board.configure(size: 4, regions: (0..<16).map { $0 / 4 }, found: [], marks: marks,
                        errors: [], preview: [], sessionID: session, lives: 3,
                        tutorialTargets: [], locked: locked,
                        onToggle: { _ in }, onSubmit: { _ in }, onMark: { _ in },
                        onInputActivityChange: receive)
    }
}

/// Deterministic contact intervals exercise the same decision object used by
/// the native recognizer; native touch delivery is covered separately in UI tests.
final class BoardTapDecisionTests: XCTestCase {
    @MainActor func testDifferentCellCommitsPreviousAtFingerDownAndSameCellDoubleNeverLeaksASingle() {
        var time = 0.0
        var jobs: [DispatchWorkItem] = []
        let route = BoardTapDecision(now: { time }, schedule: { _, work in jobs.append(work) })
        var singles: [Int] = [], doubles: [Int] = [], previews: [Int?] = [], busy: [Bool] = []
        route.onSingle = { singles.append($0) }; route.onDouble = { doubles.append($0) }
        route.onPreview = { previews.append($0) }; route.onBusy = { busy.append($0) }
        route.contactBegan(cell: 2); route.acceptedTap(cell: 2)
        XCTAssertTrue(singles.isEmpty); XCTAssertEqual(route.pendingCell, 2)
        time = 0.06; route.contactBegan(cell: 3)
        XCTAssertEqual(singles, [2], "The previous tap commits before the new finger lifts.")
        route.acceptedTap(cell: 3)
        time = 0.12; route.contactBegan(cell: 3)
        time = 0.15; route.acceptedTap(cell: 3)
        XCTAssertEqual(singles, [2]); XCTAssertEqual(doubles, [3]); XCTAssertNil(route.pendingCell)
        jobs.forEach { $0.perform() }
        XCTAssertEqual(singles, [2]); XCTAssertEqual(doubles, [3], "Cancelled deadlines cannot write a late X.")
        XCTAssertEqual(busy, [true, false, true, false])
        XCTAssertNil(previews.last!)
    }

    @MainActor func testPendingSingleHasBoundedDeadlineAndLateSameCellStartsAnotherSingle() {
        var time = 10.0
        var jobs: [(TimeInterval, DispatchWorkItem)] = []
        let route = BoardTapDecision(now: { time }, schedule: { jobs.append(($0, $1)) })
        var singles: [Int] = [], doubles: [Int] = []
        route.onSingle = { singles.append($0) }; route.onDouble = { doubles.append($0) }
        route.acceptedTap(cell: 7)
        XCTAssertEqual(jobs.first?.0, 0.30)
        // Even if the main queue has not run the expired job yet, a late next
        // touch must not turn two independent singles into an answer submission.
        time = 10.31; route.contactBegan(cell: 7); route.acceptedTap(cell: 7)
        XCTAssertEqual(singles, [7]); XCTAssertTrue(doubles.isEmpty)
        jobs[0].1.perform(); XCTAssertEqual(singles, [7])
        time = 10.62; jobs[1].1.perform()
        XCTAssertEqual(singles, [7, 7]); XCTAssertNil(route.pendingCell)
    }

    @MainActor func testSecondContactBecomingPanPreservesEarlierTapAndLifecycleCancelDiscardsPending() {
        var time = 0.0
        var jobs: [DispatchWorkItem] = []
        let route = BoardTapDecision(now: { time }, schedule: { _, work in jobs.append(work) })
        var singles: [Int] = [], doubles: [Int] = []
        route.onSingle = { singles.append($0) }; route.onDouble = { doubles.append($0) }
        route.acceptedTap(cell: 4)
        time = 0.10; route.contactBegan(cell: 4)
        jobs[0].perform(); XCTAssertTrue(singles.isEmpty, "A valid second contact owns the pending decision.")
        route.contactCancelled()
        XCTAssertEqual(singles, [4]); XCTAssertTrue(doubles.isEmpty)
        route.acceptedTap(cell: 5); route.cancel(); route.contactCancelled()
        jobs.forEach { $0.perform() }
        XCTAssertEqual(singles, [4]); XCTAssertNil(route.pendingCell)
    }
}
