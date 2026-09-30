import XCTest

/// Tests use the checked-in Level 1 pack, not a test-only answer injected into the app.
/// demo-connected-v2, seed 11400714819535654101, 4×4, solution [1, 7, 8, 14].
/// If that fixture intentionally changes, update these expectations with Resources/levels.json.
final class CapydokuUITests: XCTestCase {
    private var app: XCUIApplication!
    private let solution = [1, 7, 8, 14]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launchGame() {
        app.launchArguments = ["-ui-testing", "-reset-demo", "-skip-tutorial", "-level", "1"]
        app.launch()
        XCTAssertTrue(cell(0).waitForExistence(timeout: 15), "The packaged first puzzle should load.")
        XCTAssertEqual(app.staticTexts["level_title"].label, "Level 1")
    }

    private func cell(_ index: Int) -> XCUIElement { app.buttons["cell_\(index)"] }

    private func expectValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 4,
                             file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Expected \(element.identifier) value \(value), got \(element.value ?? "nil")", file: file, line: line)
    }

    private func boardValues(count: Int = 16) -> [String] {
        (0..<count).map { cell($0).value as? String ?? "missing" }
    }

    private func tapButton(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Button \(id) should exist", file: file, line: line)
        // Scroll through the outer margin. Swiping on the board would mark puzzle cells.
        for _ in 0..<3 where !button.isHittable {
            let above = button.frame.maxY < app.frame.minY + 120
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: above ? 0.30 : 0.82))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: above ? 0.82 : 0.34)))
        }
        XCTAssertTrue(button.isHittable, "Button \(id) should be reachable", file: file, line: line)
        button.tap()
    }

    private func drag(from start: Int, to end: Int) {
        let origin = cell(start).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = cell(end).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.05, thenDragTo: destination)
    }

    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHomeTutorialSkipAndDoubleTapDoesNotLeakAMark() {
        app.launchArguments = ["-ui-testing", "-reset-demo"]
        app.launch()
        XCTAssertTrue(app.buttons["play"].waitForExistence(timeout: 15))
        attachScreen("Home")
        tapButton("play")
        XCTAssertTrue(app.staticTexts["tutorial_title"].waitForExistence(timeout: 5))
        tapButton("skip_tutorial")
        XCTAssertTrue(app.buttons["hint"].waitForExistence(timeout: 5))

        cell(0).tap()
        expectValue(cell(0), "marked")
        cell(0).tap()
        expectValue(cell(0), "empty")
        cell(1).doubleTap()
        expectValue(cell(1), "found")
        XCTAssertEqual(app.staticTexts["score"].label, "100")
        expectValue(app.otherElements["lives"], "3")
        XCTAssertEqual(boardValues(), (0..<16).map { $0 == 1 ? "found" : "empty" }, "Finding a capy must not auto-mark neighbors or leak the first tap.")
        cell(1).doubleTap()
        XCTAssertEqual(app.staticTexts["score"].label, "100", "Repeated confirmation must not award score again.")
        attachScreen("First capy found")
    }

    func testGuidedTutorialCoversRulesTapUndoBothSwipesAndFind() {
        app.launchArguments = ["-ui-testing", "-reset-demo", "-level", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["tutorial_title"].waitForExistence(timeout: 15))
        cell(0).tap()
        expectValue(cell(0), "empty")
        for _ in 0..<4 { tapButton("tutorial_next") }
        XCTAssertTrue(app.staticTexts["tutorial_title"].label.contains("Tap to mark"))
        cell(0).tap()
        expectValue(cell(0), "marked")
        XCTAssertTrue(app.staticTexts["tutorial_title"].label.contains("undo"))
        cell(0).tap()
        expectValue(cell(0), "empty")
        XCTAssertTrue(app.staticTexts["tutorial_title"].label.contains("row"))
        drag(from: 2, to: 3)
        expectValue(cell(2), "marked")
        expectValue(cell(3), "marked")
        XCTAssertTrue(app.staticTexts["tutorial_title"].label.contains("column"))
        drag(from: 0, to: 4)
        expectValue(cell(0), "marked")
        expectValue(cell(4), "marked")
        XCTAssertTrue(app.staticTexts["tutorial_title"].label.contains("Double-tap"))
        cell(1).doubleTap()
        expectValue(cell(1), "found")
        XCTAssertTrue(app.buttons["hint"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["tutorial_title"].exists)
        expectValue(app.otherElements["lives"], "3")
    }

    func testHorizontalAndVerticalSwipesOnlyAddMarks() {
        launchGame()
        drag(from: 0, to: 3)
        expectValue(cell(3), "marked")
        XCTAssertEqual(boardValues(), (0..<16).map { $0 < 4 ? "marked" : "empty" })
        drag(from: 3, to: 0)
        expectValue(cell(0), "marked")
        XCTAssertEqual(boardValues(), (0..<16).map { $0 < 4 ? "marked" : "empty" }, "Swiping existing marks must not toggle them off.")
        drag(from: 0, to: 12)
        expectValue(cell(12), "marked")
        let expected = Set([0, 1, 2, 3, 4, 8, 12])
        XCTAssertEqual(boardValues(), (0..<16).map { expected.contains($0) ? "marked" : "empty" })
        expectValue(app.otherElements["lives"], "3")
    }

    func testDiagonalSwipeDoesNotChangeBoard() {
        launchGame()
        drag(from: 0, to: 15)
        XCTAssertEqual(boardValues(), Array(repeating: "empty", count: 16), "Diagonal swipes must not become row or column marks.")
        cell(0).tap()
        expectValue(cell(0), "marked", timeout: 5)
    }

    func testHintPreviewAndClosePreserveBoard() {
        launchGame()
        let before = boardValues()
        tapButton("hint")
        XCTAssertTrue(app.buttons["hint_close"].waitForExistence(timeout: 5))
        XCTAssertEqual(boardValues(), before, "Preview must not modify the saved marks.")
        tapButton("hint_close")
        XCTAssertTrue(app.buttons["direct"].waitForExistence(timeout: 5))
        XCTAssertEqual(boardValues(), before, "Closing a preview must not apply its marks.")
        expectValue(app.otherElements["lives"], "3")
    }

    func testHintApplyAddsExclusionsWithoutRevealingOrLosingLives() {
        launchGame()
        tapButton("hint")
        tapButton("hint_apply")
        XCTAssertTrue(app.buttons["direct"].waitForExistence(timeout: 5))
        let after = boardValues()
        XCTAssertTrue(after.contains("marked"), "Apply should add the preview's exclusions.")
        XCTAssertFalse(after.contains("found"))
        XCTAssertFalse(after.contains("error"))
        for index in solution { XCTAssertEqual(after[index], "empty", "Hints must never exclude a solution cell.") }
        expectValue(app.otherElements["lives"], "3")
    }

    func testDirectToolAndRestartKeepUsedToolUsed() {
        launchGame()
        tapButton("direct")
        XCTAssertEqual(boardValues().filter { $0 == "found" }.count, 1)
        XCTAssertEqual(app.staticTexts["score"].label, "100")
        XCTAssertTrue(boardValues().allSatisfy { $0 == "empty" || $0 == "found" })
        tapButton("restart")
        XCTAssertTrue(app.alerts["Restart this puzzle?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Restart"].tap()
        expectValue(cell(0), "empty")
        XCTAssertEqual(boardValues(), Array(repeating: "empty", count: 16))
        XCTAssertEqual(app.staticTexts["score"].label, "0")
        tapButton("direct")
        XCTAssertTrue(app.buttons["run_reward"].waitForExistence(timeout: 5), "A restart must not regenerate the free direct tool.")
    }

    func testSolveEntirePuzzleAndAdvance() {
        launchGame()
        for index in solution {
            cell(index).doubleTap()
            expectValue(cell(index), "found")
        }
        XCTAssertTrue(app.staticTexts["win_result"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["score"].label, "520")
        attachScreen("Level complete")
        tapButton("next_level")
        let next = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Level 2"), object: app.staticTexts["level_title"])
        XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 5), .completed)
        XCTAssertEqual(boardValues(), Array(repeating: "empty", count: 16))
        expectValue(app.otherElements["lives"], "3")
    }

    func testLoseAndSimulatedRevivePreservesBoard() {
        launchGame()
        cell(1).doubleTap()
        expectValue(cell(1), "found")
        for (offset, index) in [0, 2, 3].enumerated() {
            cell(index).doubleTap()
            if offset == 1 {
                XCTAssertTrue(app.staticTexts["found_count"].label.contains("One heart left"), "The last-life reminder should be shown.")
            }
            expectValue(cell(index), "error")
            expectValue(app.otherElements["lives"], String(2 - offset))
            if offset == 0 {
                let mistake = cell(index).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                mistake.tap()
                mistake.doubleTap()
                expectValue(cell(index), "error")
                expectValue(app.otherElements["lives"], "2")
            }
        }
        XCTAssertTrue(app.staticTexts["loss_result"].waitForExistence(timeout: 5))
        let before = boardValues()
        tapButton("revive")
        tapButton("run_reward")
        XCTAssertTrue(app.alerts.buttons["OK"].waitForExistence(timeout: 8))
        app.alerts.buttons["OK"].tap()
        expectValue(app.otherElements["lives"], "3")
        XCTAssertEqual(boardValues(), before)
        XCTAssertTrue(app.buttons["direct"].exists)
    }

    func testBackgroundAndRelaunchRestoreSamePuzzleAndState() {
        launchGame()
        cell(0).tap()
        expectValue(cell(0), "marked")
        cell(1).doubleTap()
        expectValue(cell(1), "found")
        cell(2).doubleTap()
        expectValue(cell(2), "error")
        let before = boardValues()
        let score = app.staticTexts["score"].label
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(cell(1).waitForExistence(timeout: 5))
        XCTAssertEqual(boardValues(), before)
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        tapButton("play")
        XCTAssertTrue(cell(0).waitForExistence(timeout: 5))
        XCTAssertEqual(boardValues(), before)
        XCTAssertEqual(app.staticTexts["score"].label, score)
        expectValue(app.otherElements["lives"], "2")
        XCTAssertEqual(app.staticTexts["level_title"].label, "Level 1")
    }

    func testSettingsStayIndependentAndPersist() {
        app.launchArguments = ["-ui-testing", "-reset-demo"]
        app.launch()
        tapButton("settings")
        let music = app.switches["music_toggle"]
        XCTAssertTrue(music.waitForExistence(timeout: 5))
        let initialMusic = music.value as? String
        let others = ["sound_toggle", "voice_toggle", "haptics_toggle"]
        let before = others.map { app.switches[$0].value as? String }
        // SwiftUI exposes the entire Form row as a switch; hit its actual trailing control.
        music.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        expectValue(music, initialMusic == "1" ? "0" : "1")
        XCTAssertEqual(others.map { app.switches[$0].value as? String }, before, "Each preference should be independent.")
        let saved = music.value as? String
        tapButton("settings_done")
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        tapButton("settings")
        XCTAssertTrue(music.waitForExistence(timeout: 5))
        XCTAssertEqual(music.value as? String, saved)
        XCTAssertEqual(others.map { app.switches[$0].value as? String }, before)
    }

    func testDailyClaimIsGrantedOnceAndPersists() {
        app.launchArguments = ["-ui-testing", "-reset-demo"]
        app.launch()
        tapButton("check_in")
        XCTAssertEqual(app.staticTexts["bonus_inventory"].label, "0 hints · 0 finds")
        tapButton("claim_reward")
        XCTAssertTrue(app.alerts.buttons["OK"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(app.staticTexts["bonus_inventory"].label, "1 hints · 0 finds")
        XCTAssertFalse(app.buttons["claim_reward"].isEnabled)
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        tapButton("check_in")
        XCTAssertEqual(app.staticTexts["bonus_inventory"].label, "1 hints · 0 finds")
        XCTAssertFalse(app.buttons["claim_reward"].isEnabled, "Relaunching must not allow a second claim on the same UTC day.")
    }

    private func launchAndSolveLevel150(extraArguments: [String] = []) {
        // Checked-in v2 Level 150, seed 13006768117413479694, 10×10.
        app.launchArguments = ["-ui-testing", "-reset-demo", "-skip-tutorial"] + extraArguments + ["-level", "150"]
        app.launch()
        XCTAssertTrue(cell(99).waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["level_title"].label, "Level 150")
        for index in [8, 10, 22, 35, 41, 54, 66, 73, 87, 99] {
            cell(index).doubleTap()
            expectValue(cell(index), "found")
        }
        XCTAssertTrue(app.staticTexts["win_result"].waitForExistence(timeout: 5))
    }

    func testLevel150AdvancesToGenerated151AndRestoresSameBoard() {
        launchAndSolveLevel150()
        tapButton("next_level")
        let next = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Level 151"), object: app.staticTexts["level_title"])
        XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 15), .completed)
        XCTAssertTrue(cell(35).exists)
        XCTAssertFalse(cell(36).exists, "The first recovery board in the local lab should be 6×6.")
        cell(0).tap()
        expectValue(cell(0), "marked")
        let before = boardValues(count: 36)
        let regions = (0..<36).map { cell($0).label }
        attachScreen("Generated level 151")
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        tapButton("play")
        XCTAssertTrue(cell(35).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["level_title"].label, "Level 151")
        XCTAssertEqual(boardValues(count: 36), before)
        XCTAssertEqual((0..<36).map { cell($0).label }, regions, "Every region label must restore along with the player's marks.")
    }

    func testGenerationFailureKeepsCompletedLevel150Intact() {
        launchAndSolveLevel150(extraArguments: ["-generation-candidate-limit", "0"])
        XCTAssertFalse(app.alerts.firstMatch.exists, "Failure injection must not produce an invalid session save.")
        tapButton("next_level")
        XCTAssertTrue(app.alerts.buttons["OK"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Generation stopped safely")).firstMatch.exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(app.staticTexts["level_title"].label, "Level 150")
        XCTAssertTrue(app.staticTexts["win_result"].exists)
        XCTAssertEqual(boardValues(count: 100).filter { $0 == "found" }.count, 10)
        tapButton("home")
        XCTAssertTrue(app.buttons["play"].waitForExistence(timeout: 5))
        tapButton("play")
        XCTAssertEqual(app.staticTexts["level_title"].label, "Level 150")
        XCTAssertTrue(app.staticTexts["win_result"].exists)
        XCTAssertEqual(boardValues(count: 100).filter { $0 == "found" }.count, 10)
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        tapButton("play")
        XCTAssertEqual(app.staticTexts["level_title"].label, "Level 150")
        XCTAssertTrue(app.staticTexts["win_result"].exists, "The pre-failure board must also survive a cold restart.")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
