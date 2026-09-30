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
        XCTAssertEqual(board.gestureRecognizers?.count, 3)
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
