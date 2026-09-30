import XCTest

/// Fixture-based gesture regressions use the archived v2 pack via -legacy-fixture.
/// Tutorial, challenge-transition and visual evidence cases explicitly run the current pack.
/// demo-connected-v2, seed 11400714819535654101, 4×4, solution [1, 7, 8, 14].
/// If that fixture intentionally changes, update these expectations with Resources/levels.json.
final class CapydokuUITests: XCTestCase {
    private var app: XCUIApplication!
    private let solution = [1, 7, 8, 14]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(); app.launchEnvironment["CAPYDOKU_UI_LANGUAGE"] = "en"
    }

    private func launchGame() {
        app.launchArguments = ["-ui-testing", "-legacy-fixture", "-reset-demo", "-skip-tutorial", "-level", "1"]
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
        app.launchArguments = ["-ui-testing", "-legacy-fixture", "-reset-demo"]
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
        // Current original-pipeline-v3 L1, seed 11400714819535654101.
        // Region 3 is the singleton at cell 8. Its rule conflicts derive the
        // teaching path: tap/undo 0, row swipe 4→5, column swipe 9→13, find 8.
        app.launchArguments = ["-ui-testing", "-reset-demo", "-level", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["tutorial_title"].waitForExistence(timeout: 15))
        // Singleton 8 proves the animal; its five neighbors add the most exclusions,
        // followed by two new row exclusions and one new column exclusion.
        for rule in ["One per region", "Give them space", "One per row", "One per column"] {
            XCTAssertTrue(app.staticTexts["tutorial_title"].label.contains(rule))
            attachScreen("v2-current-board-\(rule)")
            cell(0).tap()
            expectValue(cell(0), "empty", timeout: 5)
            tapButton("tutorial_next")
        }
        XCTAssertTrue(app.staticTexts["tutorial_title"].label.contains("Tap to mark"))
        cell(0).tap()
        expectValue(cell(0), "marked")
        XCTAssertTrue(app.staticTexts["tutorial_title"].label.contains("undo"))
        cell(0).tap()
        expectValue(cell(0), "empty")
        XCTAssertTrue(app.staticTexts["tutorial_title"].label.contains("row"))
        drag(from: 4, to: 5)
        expectValue(cell(4), "marked")
        expectValue(cell(5), "marked")
        XCTAssertTrue(app.staticTexts["tutorial_title"].label.contains("column"))
        drag(from: 9, to: 13)
        expectValue(cell(9), "marked")
        expectValue(cell(13), "marked")
        XCTAssertTrue(app.staticTexts["tutorial_title"].label.contains("Double-tap"))
        cell(8).doubleTap()
        expectValue(cell(8), "found")
        XCTAssertTrue(app.buttons["hint"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["tutorial_title"].exists)
        expectValue(app.otherElements["lives"], "3")
        XCTAssertEqual(boardValues(), (0..<16).map { $0 == 8 ? "found" : [4, 5, 9, 13].contains($0) ? "marked" : "empty" })
        attachScreen("Current Level 1 guided tutorial complete")
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

    func testSwipeCannotStartOnFoundCapybaraAndNextValidStrokeStillWorks() {
        launchGame()
        cell(1).doubleTap()
        expectValue(cell(1), "found")
        let before = boardValues()
        drag(from: 1, to: 3)
        XCTAssertEqual(boardValues(), before)
        drag(from: 1, to: 13)
        XCTAssertEqual(boardValues(), before)
        drag(from: 0, to: 3)
        expectValue(cell(3), "marked")
        XCTAssertEqual(boardValues(), (0..<16).map { $0 == 1 ? "found" : [0, 2, 3].contains($0) ? "marked" : "empty" })
        expectValue(app.otherElements["lives"], "3")
        XCTAssertEqual(app.staticTexts["score"].label, "100")
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

    func testToolsResumeAfterNativeTapDoubleTapAndPanRecognizersFinish() {
        // Exercises the real UIKit recognizers. Policy tests separately cover
        // a competing tool request while any recognizer is still pending.
        for kind in ["single", "double", "horizontal", "vertical", "diagonal", "outside"] {
            launchGame()
            switch kind {
            case "single": cell(0).tap(); expectValue(cell(0), "marked")
            case "double": cell(1).doubleTap(); expectValue(cell(1), "found")
            case "horizontal": drag(from: 0, to: 3); expectValue(cell(3), "marked")
            case "vertical": drag(from: 0, to: 12); expectValue(cell(12), "marked")
            case "diagonal": drag(from: 0, to: 15); XCTAssertEqual(boardValues(), Array(repeating: "empty", count: 16))
            default:
                cell(0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45)))
            }
            let before = boardValues()
            tapButton("hint")
            XCTAssertTrue(app.buttons["hint_apply"].waitForExistence(timeout: 5), "Completed \(kind) must release the input gate.")
            tapButton("hint_close")
            XCTAssertEqual(boardValues(), before)
            // The second use is the zero-inventory, simulated-ad path.
            tapButton("hint")
            XCTAssertTrue(app.buttons["hint_apply"].waitForExistence(timeout: 8), "\(kind) must not leave advertisements permanently blocked.")
            tapButton("hint_close")
            XCTAssertEqual(boardValues(), before)
        }
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

    func testCurrentPackHintRestoresAfterTerminationAndApplyStaysSaved() {
        app.launchArguments = ["-ui-testing", "-reset-demo", "-skip-tutorial", "-level", "1"]
        app.launch()
        XCTAssertTrue(cell(0).waitForExistence(timeout: 15))
        let before = boardValues()
        tapButton("hint")
        XCTAssertTrue(app.buttons["hint_apply"].waitForExistence(timeout: 5))
        let explanation = app.staticTexts["hint_explanation"].label
        XCTAssertEqual(boardValues(), before)
        attachScreen("029 Current pack hint before termination")

        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["play"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["hint_apply"].exists, "Recovery on Home does not display a hint.")
        tapButton("play")
        XCTAssertTrue(app.buttons["hint_apply"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["hint_explanation"].label, explanation)
        XCTAssertEqual(boardValues(), before, "Restoring the same preview must not apply any X marks.")
        attachScreen("029 Same hint restored on Continue")
        tapButton("hint_apply")
        XCTAssertTrue(app.buttons["hint"].waitForExistence(timeout: 5))
        let applied = boardValues()
        XCTAssertNotEqual(applied, before)
        XCTAssertFalse(applied.contains("found"))
        XCTAssertEqual(app.buttons["hint"].value as? String, "Video reward", "Restoring and applying the preview spends only the original hint.")
        expectValue(app.otherElements["lives"], "3")

        app.terminate(); app.launch(); tapButton("play")
        XCTAssertTrue(app.buttons["hint"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["hint_apply"].exists, "A completed Apply cannot reopen after relaunch.")
        XCTAssertEqual(boardValues(), applied)
        XCTAssertEqual(app.buttons["hint"].value as? String, "Video reward")
    }

    func testDirectToolAndRestartKeepUsedToolUsed() {
        launchGame()
        tapButton("direct")
        XCTAssertEqual(boardValues().filter { $0 == "found" }.count, 1)
        XCTAssertEqual(app.staticTexts["score"].label, "100")
        XCTAssertTrue(boardValues().allSatisfy { $0 == "empty" || $0 == "found" })
        tapButton("settings")
        tapButton("restart")
        expectValue(cell(0), "empty")
        XCTAssertEqual(boardValues(), Array(repeating: "empty", count: 16))
        XCTAssertEqual(app.staticTexts["score"].label, "0")
        XCTAssertEqual(app.buttons["direct"].value as? String, "Video reward", "A restart must not regenerate the free direct tool.")
        tapButton("direct")
        let revealed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.boardValues().filter { $0 == "found" }.count == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [revealed], timeout: 8), .completed, "The depleted tool must automatically run its demo reward and reveal once.")
    }

    func testSolveEntirePuzzleAndAdvance() {
        launchGame()
        for index in solution {
            cell(index).doubleTap()
            if index != solution.last { expectValue(cell(index), "found") }
        }
        XCTAssertTrue(app.staticTexts["win_result"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["win_result"].value as? String, "Level 1. Score 520. 4 of 4 found.")
        XCTAssertFalse(cell(0).exists, "The completed board must not leak beneath its modal result.")
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
                XCTAssertTrue(app.descendants(matching: .any)["found_count"].label.contains("One heart left"), "The last-life reminder should be shown.")
            }
            if offset < 2 {
                expectValue(cell(index), "error")
                expectValue(app.otherElements["lives"], String(2 - offset))
            }
            if offset == 0 {
                let mistake = cell(index).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                mistake.tap()
                expectValue(cell(index), "empty")
                mistake.tap()
                expectValue(cell(index), "marked")
                expectValue(app.otherElements["lives"], "2")
            }
        }
        XCTAssertTrue(app.staticTexts["loss_result"].waitForExistence(timeout: 5))
        XCTAssertFalse(cell(0).exists)
        let before = (0..<16).map { $0 == 1 ? "found" : $0 == 0 ? "marked" : [2, 3].contains($0) ? "error" : "empty" }
        tapButton("revive")
        expectValue(app.otherElements["lives"], "3", timeout: 8)
        XCTAssertFalse(app.alerts.firstMatch.exists, "A successful revival resumes this board without an additional confirmation popup.")
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
        app.launchArguments = ["-ui-testing", "-legacy-fixture"]
        app.launch()
        tapButton("play")
        XCTAssertTrue(cell(0).waitForExistence(timeout: 5))
        XCTAssertEqual(boardValues(), before)
        XCTAssertEqual(app.staticTexts["score"].label, score)
        expectValue(app.otherElements["lives"], "2")
        XCTAssertEqual(app.staticTexts["level_title"].label, "Level 1")
    }

    func testSettingsStayIndependentAndPersist() {
        app.launchArguments = ["-ui-testing", "-legacy-fixture", "-reset-demo"]
        app.launch()
        tapButton("settings")
        let music = app.descendants(matching: .any).matching(identifier: "music_toggle").firstMatch
        XCTAssertTrue(music.waitForExistence(timeout: 5))
        let initialMusic = music.value as? String
        let others = ["sound_toggle", "voice_toggle", "haptics_toggle"]
        let before = others.map { app.descendants(matching: .any).matching(identifier: $0).firstMatch.value as? String }
        // The original design uses four compact icon buttons with custom ON/OFF sliders.
        music.tap()
        expectValue(music, initialMusic == "1" ? "0" : "1")
        XCTAssertEqual(others.map { app.descendants(matching: .any).matching(identifier: $0).firstMatch.value as? String }, before, "Each preference should be independent.")
        let saved = music.value as? String
        attachScreen("Settings functional ON and OFF contrast English")
        tapButton("settings_done")
        app.terminate()
        app.launchArguments = ["-ui-testing", "-legacy-fixture"]
        app.launch()
        tapButton("settings")
        XCTAssertTrue(music.waitForExistence(timeout: 5))
        XCTAssertEqual(music.value as? String, saved)
        XCTAssertEqual(others.map { app.descendants(matching: .any).matching(identifier: $0).firstMatch.value as? String }, before)
        tapButton("language_zh_hans")
        XCTAssertEqual(music.value as? String, saved)
        attachScreen("Settings functional ON and OFF contrast Chinese")
    }

    func testDailyClaimIsGrantedOnceAndPersists() {
        app.launchArguments = ["-ui-testing", "-reset-demo"]
        app.launch()
        tapButton("check_in")
        XCTAssertEqual(app.staticTexts["checkin_streak"].label, "0")
        let claim = app.buttons["claim_reward"]
        XCTAssertTrue(claim.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(claim.frame.width, 44, "Today's reward must retain a 44pt minimum touch width.")
        XCTAssertGreaterThanOrEqual(claim.frame.height, 44, "Today's reward must retain a 44pt minimum touch height.")
        for day in 2...7 {
            let item = app.buttons["checkin_day_\(day)"]
            XCTAssertTrue(item.exists)
            XCTAssertEqual(item.frame.midY, claim.frame.midY, accuracy: 1, "All seven days should stay in one horizontal row.")
        }
        attachScreen("Current check-in 44pt touch targets")
        tapButton("claim_reward")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Successful check-in uses its date state and a short celebration, without an extra confirmation popup.")
        XCTAssertEqual(app.staticTexts["checkin_streak"].label, "1")
        XCTAssertFalse(app.buttons["claim_reward"].exists)
        XCTAssertFalse(app.buttons["checkin_day_1"].isEnabled, "A claimed date is a read-only status.")
        XCTAssertFalse(app.buttons["checkin_day_2"].isEnabled, "A future date cannot be claimed.")
        attachScreen("Claimed date remains visible and disabled")
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        tapButton("check_in")
        XCTAssertEqual(app.staticTexts["checkin_streak"].label, "1")
        XCTAssertFalse(app.buttons["claim_reward"].exists, "Relaunching must not allow a second claim on the same UTC day.")
    }

    func testCaptureCurrentOriginalReferenceScreens() {
        // Deliberately omit -legacy-fixture: these visual checks show the current production pack and artwork.
        app.launchArguments = ["-ui-testing", "-reset-demo", "-skip-tutorial"]
        app.launch()
        XCTAssertTrue(app.buttons["play"].waitForExistence(timeout: 15))
        attachScreen("Reference 01 Home")
        tapButton("settings")
        XCTAssertTrue(app.buttons["settings_done"].waitForExistence(timeout: 5))
        attachScreen("Reference 02 Settings")
        tapButton("settings_done")
        tapButton("check_in")
        XCTAssertTrue(app.staticTexts["checkin_streak"].waitForExistence(timeout: 5))
        attachScreen("Reference 03 Check-in")
        tapButton("checkin_home")
        tapButton("play")
        XCTAssertTrue(cell(0).waitForExistence(timeout: 5))
        attachScreen("Reference 04 Current puzzle")
        let boardBeforeHint = app.otherElements["puzzle_board"].frame
        tapButton("hint")
        XCTAssertTrue(app.buttons["hint_apply"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.otherElements["puzzle_board"].frame, boardBeforeHint, "Hint presentation must not shift or resize the board.")
        attachScreen("Reference 05 Hint preview")
        tapButton("hint_close")
        // Any four-by-four valid board encounters three errors before a sequential scan could solve it.
        // No answer coordinates are assumed or injected into this current-pack visual test.
        for index in 0..<16 {
            if app.staticTexts["loss_result"].exists { break }
            cell(index).doubleTap()
        }
        XCTAssertTrue(app.staticTexts["loss_result"].waitForExistence(timeout: 5))
        attachScreen("Reference 06 Failure")
    }

    func testFirstLevelTenWinShowsChallengeOnceBeforeLevelEleven() {
        app.launchArguments = ["-ui-testing", "-reset-demo", "-skip-tutorial", "-level", "10"]
        app.launch()
        XCTAssertTrue(cell(35).waitForExistence(timeout: 15))
        // Current original-pipeline-v3 L10: 6×6, seed 3326683751187130770, candidate 48.
        for index in [3, 7, 16, 20, 29, 30] {
            cell(index).doubleTap()
            if index != 30 { expectValue(cell(index), "found") }
        }
        XCTAssertTrue(app.staticTexts["win_result"].waitForExistence(timeout: 5))
        tapButton("next_level")
        XCTAssertTrue(app.staticTexts["challenge_title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["challenge_title"].label, "A New Challenge!")
        XCTAssertFalse(app.buttons["next_level"].isHittable, "The transition card must freeze its completed level underneath.")
        attachScreen("Current Level 10 challenge transition")
        tapButton("challenge_continue")
        let next = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Level 11"), object: app.staticTexts["level_title"])
        XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 10), .completed)
        app.terminate()
        app.launchArguments = ["-ui-testing", "-skip-tutorial", "-level", "10"]
        app.launch()
        XCTAssertTrue(cell(35).waitForExistence(timeout: 15))
        for index in [3, 7, 16, 20, 29, 30] {
            cell(index).doubleTap()
            if index != 30 { expectValue(cell(index), "found") }
        }
        XCTAssertTrue(app.staticTexts["win_result"].waitForExistence(timeout: 5))
        tapButton("next_level")
        let repeated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Level 11"), object: app.staticTexts["level_title"])
        XCTAssertEqual(XCTWaiter.wait(for: [repeated], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["challenge_title"].exists, "The first-clear challenge notice must not reappear after restarting the app.")
    }

    private func launchAndSolveLevel150(extraArguments: [String] = []) {
        // Current Resources/levels.json: original-pipeline-v3, seed 13006768117413479694, candidate 12, 8×8.
        app.launchArguments = ["-ui-testing", "-reset-demo", "-skip-tutorial"] + extraArguments + ["-level", "150"]
        app.launch()
        XCTAssertTrue(cell(63).waitForExistence(timeout: 15))
        XCTAssertFalse(cell(64).exists, "The current packaged Level 150 must be 8×8.")
        XCTAssertEqual(app.staticTexts["level_title"].label, "Level 150")
        for index in [4, 14, 19, 29, 32, 42, 55, 57] {
            cell(index).doubleTap()
            if index != 57 { expectValue(cell(index), "found") }
        }
        XCTAssertTrue(app.staticTexts["win_result"].waitForExistence(timeout: 5))
    }

    func testLevel150AdvancesToGenerated151AndRestoresSameBoard() {
        launchAndSolveLevel150()
        tapButton("next_level")
        let next = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Level 151"), object: app.staticTexts["level_title"])
        XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 15), .completed)
        XCTAssertTrue(cell(0).waitForExistence(timeout: 5))
        cell(0).tap()
        expectValue(cell(0), "marked")
        let boardCells = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cell_")).allElementsBoundByIndex
        let count = boardCells.count
        XCTAssertTrue([36, 64, 100].contains(count), "The current endless profile permits 6×6, 8×8 or 10×10; do not freeze a generated size.")
        XCTAssertEqual(Set(boardCells.map(\.identifier)), Set((0..<count).map { "cell_\($0)" }))
        let before = boardValues(count: count)
        let regions = (0..<count).map { cell($0).label }
        attachScreen("Current pack Level 150 to generated Level 151")
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        tapButton("play")
        XCTAssertTrue(cell(count - 1).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["level_title"].label, "Level 151")
        XCTAssertFalse(cell(count).exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cell_")).count, count)
        XCTAssertEqual(boardValues(count: count), before)
        XCTAssertEqual((0..<count).map { cell($0).label }, regions, "Every region label must restore along with the player's marks.")
    }

    func testGenerationFailureKeepsCompletedLevel150Intact() {
        launchAndSolveLevel150(extraArguments: ["-generation-candidate-limit", "0"])
        let before = app.staticTexts["win_result"].value as? String
        XCTAssertTrue(before?.contains("Level 150.") == true)
        XCTAssertTrue(before?.contains("8 of 8 found.") == true)
        XCTAssertFalse(cell(0).exists, "Result isolation hides the completed board; exact snapshot persistence is also covered in AppModel tests.")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Failure injection must not produce an invalid session save.")
        tapButton("next_level")
        XCTAssertTrue(app.alerts.buttons["OK"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Generation stopped safely")).firstMatch.exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["win_result"].exists)
        XCTAssertEqual(app.staticTexts["win_result"].value as? String, before)
        XCTAssertFalse(cell(0).exists)
        tapButton("result_home")
        XCTAssertTrue(app.buttons["play"].waitForExistence(timeout: 5))
        tapButton("play")
        XCTAssertTrue(app.staticTexts["win_result"].exists)
        XCTAssertEqual(app.staticTexts["win_result"].value as? String, before)
        XCTAssertFalse(cell(0).exists)
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        tapButton("play")
        XCTAssertTrue(app.staticTexts["win_result"].exists, "The pre-failure board must also survive a cold restart.")
        XCTAssertEqual(app.staticTexts["win_result"].value as? String, before)
        XCTAssertFalse(cell(0).exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
