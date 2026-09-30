import XCTest

/// Runs against the CURRENT pack, independent of the archived interaction fixture.
final class OriginalReferenceUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false; app = XCUIApplication(); app.launchEnvironment["CAPYDOKU_UI_LANGUAGE"] = "en" }
    private func launch(_ extra: [String] = []) {
        app.launchArguments = ["-ui-testing", "-reset-demo", "-skip-tutorial"] + extra
        app.launch()
    }
    private func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    private func tap(_ id: String) { XCTAssertTrue(item(id).waitForExistence(timeout: 8)); item(id).tap() }

    func testHomeSettingsAndCheckInMatchOriginalHierarchy() {
        launch()
        XCTAssertTrue(item("play").waitForExistence(timeout: 10))
        XCTAssertTrue(item("play").label.contains("Level 1"))
        let check = item("check_in"), settings = item("settings")
        XCTAssertLessThan(check.frame.midX, settings.frame.midX)
        XCTAssertEqual(check.frame.midY, settings.frame.midY, accuracy: 2)
        XCTAssertLessThan(settings.frame.maxY, item("daily_challenge").frame.minY)
        XCTAssertFalse(item("daily_challenge").isEnabled)
        capture("original-home")
        tap("settings")
        let switches = ["music_toggle", "sound_toggle", "voice_toggle", "haptics_toggle"].map(item)
        XCTAssertTrue(switches[0].waitForExistence(timeout: 5))
        for index in 1..<switches.count {
            XCTAssertGreaterThan(switches[index].frame.midX, switches[index - 1].frame.midX)
            XCTAssertEqual(switches[index].frame.midY, switches[0].frame.midY, accuracy: 2)
        }
        XCTAssertGreaterThan(item("feedback").frame.minY, switches[0].frame.maxY)
        XCTAssertGreaterThan(item("restart").frame.minY, item("feedback").frame.maxY)
        capture("original-settings")
        tap("settings_done"); tap("check_in")
        XCTAssertTrue(app.staticTexts["Day Streak"].waitForExistence(timeout: 5))
        let days = [item("claim_reward")] + (2...7).map { item("checkin_day_\($0)") }
        for day in days { XCTAssertTrue(day.exists); XCTAssertEqual(day.frame.midY, days[0].frame.midY, accuracy: 2) }
        capture("original-check-in")
    }

    func testAllFourBoardSizesKeepNavigationRulesAndToolsInOrder() {
        for (level, size) in [(1,4),(6,6),(51,8),(101,10)] {
            launch(["-level", "\(level)"])
            XCTAssertTrue(item("puzzle_board").waitForExistence(timeout: 12))
            XCTAssertTrue(item("cell_\(size * size - 1)").exists)
            let nav = item("settings"), title = item("level_title"), progress = item("found_count"), rules = item("rule_strip"), board = item("puzzle_board"), hint = item("hint")
            XCTAssertGreaterThanOrEqual(title.frame.minY, nav.frame.maxY - 1)
            XCTAssertGreaterThan(progress.frame.minY, title.frame.minY)
            XCTAssertGreaterThan(rules.frame.minY, progress.frame.minY)
            XCTAssertGreaterThanOrEqual(board.frame.minY, rules.frame.maxY - 2)
            XCTAssertGreaterThan(hint.frame.minY, board.frame.maxY)
            XCTAssertTrue(hint.isHittable)
            XCTAssertEqual(board.frame.width, board.frame.height, accuracy: 1)
            capture("original-board-\(size)x\(size)")
        }
    }

    func testHintIsAnOverlayAndOnlyApplyWritesMarks() {
        launch(["-level", "1"])
        XCTAssertTrue(item("cell_0").waitForExistence(timeout: 12))
        let before = (0..<16).map { item("cell_\($0)").value as? String ?? "" }
        tap("hint"); XCTAssertTrue(item("hint_apply").waitForExistence(timeout: 5))
        capture("original-hint-preview")
        XCTAssertEqual((0..<16).map { item("cell_\($0)").value as? String ?? "" }, before)
        XCTAssertFalse(item("settings").exists)
        tap("hint_close")
        XCTAssertEqual((0..<16).map { item("cell_\($0)").value as? String ?? "" }, before)
        tap("hint") // no inventory -> immediately runs the isolated reward adapter
        XCTAssertTrue(item("hint_apply").waitForExistence(timeout: 8))
        XCTAssertFalse(item("run_reward").exists)
        tap("hint_apply")
        XCTAssertTrue((0..<16).contains { item("cell_\($0)").value as? String == "marked" })
        XCTAssertEqual(item("lives").value as? String, "3")
    }

    func testLargestTextHintKeepsCloseApplyAndBoardReachableInBothLanguages() {
        for language in ["en", "zh-Hans"] {
            app.launchEnvironment["CAPYDOKU_UI_LANGUAGE"] = language
            launch(["-level", "1", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
            XCTAssertTrue(item("puzzle_board").waitForExistence(timeout: 12))
            let before = (0..<16).map { item("cell_\($0)").value as? String ?? "" }
            tap("hint")
            XCTAssertTrue(item("hint_explanation").waitForExistence(timeout: 5))
            XCTAssertGreaterThan(item("hint_explanation").frame.height, 120,
                                 "The real launch must render enlarged hint text, not silently test the default font.")
            let close = item("hint_close"), apply = item("hint_apply"), board = item("puzzle_board")
            for control in [close, apply] {
                XCTAssertTrue(control.isHittable)
                XCTAssertGreaterThanOrEqual(control.frame.width, 44)
                XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            }
            XCTAssertLessThan(close.frame.maxY, board.frame.minY)
            XCTAssertGreaterThan(apply.frame.minY, board.frame.maxY)
            XCTAssertEqual(board.frame.width, board.frame.height, accuracy: 1)
            XCTAssertGreaterThanOrEqual(board.frame.width, 190)
            capture("largest-text-hint-\(language)")
            tap("hint_close")
            XCTAssertEqual((0..<16).map { item("cell_\($0)").value as? String ?? "" }, before)
            XCTAssertTrue(item("hint").isHittable)
        }
    }

    func testFirstLaunchHasWorkingLegalLinksAndAcceptancePersists() {
        launch(["-test-first-launch"])
        XCTAssertTrue(item("accept_terms").waitForExistence(timeout: 10))
        capture("original-welcome")
        app.buttons["Terms of Service"].tap()
        XCTAssertTrue(app.staticTexts["Internal demo"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        let token = addUIInterruptionMonitor(withDescription: "Optional system permissions") { alert in
            if alert.buttons["Don’t Allow"].exists { alert.buttons["Don’t Allow"].tap(); return true }
            if alert.buttons["Don't Allow"].exists { alert.buttons["Don't Allow"].tap(); return true }
            if alert.buttons["Ask App Not to Track"].exists { alert.buttons["Ask App Not to Track"].tap(); return true }
            return false
        }
        tap("accept_terms")
        for _ in 0..<3 where !item("play").waitForExistence(timeout: 3) { app.tap() }
        XCTAssertTrue(item("play").waitForExistence(timeout: 10))
        removeUIInterruptionMonitor(token)
        app.terminate(); app.launchArguments = ["-ui-testing", "-test-first-launch"]; app.launch()
        XCTAssertTrue(item("play").waitForExistence(timeout: 10))
        XCTAssertFalse(item("accept_terms").exists)
    }

    func testModalControlsExcludeBackgroundAndReturnToTheSameBoard() {
        launch(["-level", "1"])
        XCTAssertTrue(item("cell_0").waitForExistence(timeout: 12))
        item("cell_0").tap()
        let marked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "marked"), object: item("cell_0"))
        XCTAssertEqual(XCTWaiter.wait(for: [marked], timeout: 5), .completed)
        let before = (0..<16).map { item("cell_\($0)").value as? String ?? "" }
        let settingsPoint = item("settings").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        settingsPoint.press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        XCTAssertFalse(item("settings_title").exists, "Dragging out cancels the button action and its action-owned feedback.")
        tap("settings")
        XCTAssertTrue(item("settings_title").waitForExistence(timeout: 5))
        for id in ["home", "settings", "cell_0", "hint", "direct"] { XCTAssertFalse(item(id).exists, "Covered \(id) must be absent from the accessibility tree.") }
        for id in ["settings_done", "feedback", "restart", "music_toggle", "sound_toggle", "voice_toggle", "haptics_toggle"] {
            XCTAssertGreaterThanOrEqual(item(id).frame.width, 44)
            XCTAssertGreaterThanOrEqual(item(id).frame.height, 44)
        }
        capture("modal-settings-isolated")
        tap("settings_done")
        XCTAssertTrue(item("settings").isHittable)
        XCTAssertEqual((0..<16).map { item("cell_\($0)").value as? String ?? "" }, before)
        let homePoint = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: item("home").frame.midX, dy: item("home").frame.midY))
        tap("hint")
        XCTAssertTrue(item("hint_explanation").waitForExistence(timeout: 5))
        XCTAssertFalse(item("settings").exists)
        // The hint keeps a read-only board on screen. XCTest can still enumerate
        // SwiftUI's dimmed labels, so verify input blocking separately from the
        // manual VoiceOver focus/navigation check instead of treating exists as it.
        XCTAssertFalse(item("home").isEnabled)
        homePoint.tap()
        XCTAssertTrue(item("hint_apply").exists, "A covered Home action must not dismiss or leave the preview.")
        for id in ["hint_close", "hint_apply"] {
            XCTAssertGreaterThanOrEqual(item(id).frame.width, 44)
            XCTAssertGreaterThanOrEqual(item(id).frame.height, 44)
        }
        XCTAssertTrue(item("cell_0").exists, "Read-only board cells remain available as part of the hint preview.")
        XCTAssertFalse(item("cell_0").isEnabled)
        tap("hint_close")
        XCTAssertTrue(item("hint").isHittable)
        XCTAssertEqual((0..<16).map { item("cell_\($0)").value as? String ?? "" }, before)
        capture("modal-isolation-restored-game")
    }
}
