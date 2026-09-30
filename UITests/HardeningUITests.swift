import XCTest

/// Regression coverage for interrupted onboarding and interactions that cross UI boundaries.
/// Uses the archived v2 level pack explicitly (solution 1, 7, 8, 14); answers are never injected.
final class HardeningUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(tutorial: Bool = false) {
        app.launchArguments = ["-ui-testing", "-legacy-fixture", "-reset-demo", "-level", "1"]
        if !tutorial { app.launchArguments.append("-skip-tutorial") }
        app.launch()
        XCTAssertTrue(cell(0).waitForExistence(timeout: 15))
    }

    private func cell(_ index: Int) -> XCUIElement { app.buttons["cell_\(index)"] }
    private func values() -> [String] { (0..<16).map { cell($0).value as? String ?? "missing" } }

    private func expectValue(_ element: XCUIElement, _ value: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed,
                       "Expected \(element.identifier) = \(value); received \(element.value ?? "nil")", file: file, line: line)
    }

    private func expectStep(_ number: Int, file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "\(number)/9 ·"),
            object: app.staticTexts["tutorial_title"])
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed,
                       "The onboarding should be at step \(number).", file: file, line: line)
    }

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing \(id)", file: file, line: line)
        // Keep scrolling touches outside the interactive board.
        for _ in 0..<3 where !button.isHittable {
            let above = button.frame.maxY < app.frame.minY + 120
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: above ? 0.30 : 0.82))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: above ? 0.82 : 0.34)))
        }
        XCTAssertTrue(button.isHittable, "Unreachable \(id)", file: file, line: line)
        button.tap()
    }

    private func drag(from start: Int, to end: Int) {
        cell(start).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: cell(end).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    }

    private func relaunchAndContinue() {
        app.terminate()
        app.launchArguments = ["-ui-testing", "-legacy-fixture"]
        app.launch()
        tap("play")
        XCTAssertTrue(cell(0).waitForExistence(timeout: 5))
    }

    func testTutorialRestoresAtReadUndoVerticalSwipeAndFindThenStaysCompleted() {
        launch(tutorial: true)
        // All nine steps run. Four persisted checkpoints exercise both read-only and
        // already-mutated boards without paying for a fresh launch at every sentence.
        let interruptionSteps: Set<Int> = [4, 6, 8, 9]
        for step in 1...9 {
            expectStep(step)
            if interruptionSteps.contains(step) {
                let before = values()
                let score = app.staticTexts["score"].label
                relaunchAndContinue()
                expectStep(step)
                XCTAssertEqual(values(), before, "Restoring step \(step) must preserve its partial board.")
                XCTAssertEqual(app.staticTexts["score"].label, score)
                expectValue(app.otherElements["lives"], "3")
            }
            switch step {
            case 1...4:
                // Rule explanation screens must not accept guesses.
                cell(0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
                expectValue(cell(0), "empty")
                tap("tutorial_next")
            case 5:
                cell(0).tap()
                expectValue(cell(0), "marked")
            case 6:
                cell(0).tap()
                expectValue(cell(0), "empty")
            case 7:
                drag(from: 2, to: 3)
                expectValue(cell(2), "marked")
                expectValue(cell(3), "marked")
            case 8:
                drag(from: 0, to: 4)
                expectValue(cell(0), "marked")
                expectValue(cell(4), "marked")
            default:
                cell(1).doubleTap()
                expectValue(cell(1), "found")
            }
        }
        XCTAssertTrue(app.buttons["hint"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["tutorial_title"].exists)
        let completed = values()
        relaunchAndContinue()
        XCTAssertFalse(app.staticTexts["tutorial_title"].exists, "Completed onboarding must not reopen on launch.")
        XCTAssertEqual(values(), completed)
        XCTAssertEqual(app.staticTexts["score"].label, "100")
        expectValue(app.otherElements["lives"], "3")
    }

    func testMixedBackToBackGesturesNeverRepeatDamageOrScore() {
        launch()
        cell(0).tap()
        expectValue(cell(0), "marked") // Establish two gestures, rather than an ambiguous triple-tap.
        cell(0).doubleTap()
        expectValue(cell(0), "error")
        let errorPoint = cell(0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        errorPoint.tap()
        expectValue(cell(0), "empty")
        errorPoint.doubleTap()
        expectValue(cell(0), "error")
        cell(1).doubleTap()
        let foundPoint = cell(1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        foundPoint.doubleTap()
        drag(from: 0, to: 3)
        cell(3).tap()
        cell(7).doubleTap()
        let secondFound = cell(7).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        secondFound.tap()
        secondFound.doubleTap()
        expectValue(cell(7), "found")
        expectValue(app.otherElements["lives"], "1")
        XCTAssertEqual(app.staticTexts["score"].label, "220")
        let expected = (0..<16).map { index in
            index == 0 ? "error" : [1, 7].contains(index) ? "found" : index == 2 ? "marked" : "empty"
        }
        XCTAssertEqual(values(), expected, "Separate wrong submissions deduct separate lives; duplicate confirmations of found cells do not score again.")
    }

    func testSwipeStopsWhenFingerLeavesBoard() {
        launch()
        let first = cell(0).frame
        let last = cell(3).frame
        let origin = cell(0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Predominantly horizontal: cross the top edge near column 2, then keep
        // dragging outside the board toward its far right. Columns 3–4 are never entered.
        let outside = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: last.maxX + 8 - app.frame.minX,
                     dy: first.minY - first.height - app.frame.minY))
        origin.press(forDuration: 0.05, thenDragTo: outside)
        expectValue(cell(0), "marked")
        expectValue(cell(3), "empty")
        XCTAssertFalse(values().contains("found"))
        XCTAssertFalse(values().contains("error"))
        expectValue(app.otherElements["lives"], "3")
        // A later gesture starts cleanly rather than continuing the cancelled stroke.
        cell(15).tap()
        expectValue(cell(15), "marked")
        expectValue(cell(3), "empty")
    }

    func testSettingsAndDismissedHintCannotApplyOrRestoreAConsumedPreview() {
        launch()
        cell(0).tap()
        expectValue(cell(0), "marked")
        cell(1).doubleTap()
        expectValue(cell(1), "found")
        let before = values()
        let score = app.staticTexts["score"].label
        tap("hint")
        XCTAssertTrue(app.buttons["hint_apply"].waitForExistence(timeout: 5))
        XCTAssertEqual(values(), before)
        XCTAssertFalse(app.buttons["settings"].exists, "The modal hint replaces settings with its close action.")
        cell(2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(values(), before, "The preview must freeze board input.")
        tap("hint_close")
        tap("settings")
        let sound = app.descendants(matching: .any).matching(identifier: "sound_toggle").firstMatch
        XCTAssertTrue(sound.waitForExistence(timeout: 5))
        let previousSound = sound.value as? String
        sound.tap()
        expectValue(sound, previousSound == "1" ? "0" : "1")
        tap("settings_done")
        XCTAssertTrue(app.buttons["hint"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["hint_apply"].exists, "Closed previews must expose no stale Apply action.")
        XCTAssertEqual(values(), before)
        XCTAssertEqual(app.staticTexts["score"].label, score)
        relaunchAndContinue()
        XCTAssertFalse(app.buttons["hint_apply"].exists)
        XCTAssertEqual(values(), before)
        XCTAssertEqual(app.buttons["hint"].value as? String, "Video reward", "Closing or relaunching must not refund the consumed hint.")
        tap("hint")
        XCTAssertTrue(app.buttons["hint_apply"].waitForExistence(timeout: 8))
        tap("hint_close")
        XCTAssertTrue(app.buttons["hint"].waitForExistence(timeout: 5))
        XCTAssertEqual(values(), before)
        XCTAssertEqual(app.staticTexts["score"].label, score)
        expectValue(app.otherElements["lives"], "3")
    }
    private func selectRewardScenario(_ title: String) {
        tap("settings")
        app.staticTexts["settings_title"].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["debug_done"].waitForExistence(timeout: 5))
        tap("reward_scenario")
        app.buttons[title].tap()
        tap("debug_done")
    }

    func testRewardWithoutCallbackTimesOutAndCanRetry() {
        launch()
        tap("hint"); tap("hint_close")
        selectRewardScenario("No callback (timeout)")
        tap("hint")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "timed out")).firstMatch.exists)
        alert.buttons["OK"].tap()
        XCTAssertFalse(app.buttons["hint_apply"].exists)
        selectRewardScenario("Success")
        tap("hint")
        XCTAssertTrue(app.buttons["hint_apply"].waitForExistence(timeout: 5))
        tap("hint_close")
        XCTAssertEqual(values(), Array(repeating: "empty", count: 16))
        expectValue(app.otherElements["lives"], "3")
    }

}
