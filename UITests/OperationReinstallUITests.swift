import XCTest

/// Run only through scripts/verify_operation_reinstall.py on its newly created
/// simulator. Stages intentionally share real app state until the script performs
/// uninstall/reinstall. No reset, skip, jump, fixture pack or save injection.
final class OperationReinstallUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CAPYDOKU_OPERATION_REINSTALL_AUDIT"] == "1" else {
            throw XCTSkip("Requires the dedicated disposable-simulator reinstall script; stages share real app state.")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-test-first-launch"]
    }
    private func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func tap(_ id: String) {
        let element = item(id)
        XCTAssertTrue(element.waitForExistence(timeout: 12), "Missing UI control: \(id)")
        XCTAssertTrue(element.isHittable, "UI control is not reachable: \(id)")
        element.tap()
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func values() -> [String] { (0..<16).map { item("cell_\($0)").value as? String ?? "missing" } }
    private func expectValue(_ id: String, _ value: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: item(id))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
    }
    private func expectFound(_ count: Int) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.values().filter { $0 == "found" }.count == count
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
    private func acceptRealWelcome() {
        XCTAssertTrue(item("accept_terms").waitForExistence(timeout: 20))
        XCTAssertEqual(item("accept_terms").label, "同意并继续")
        capture("actual-chinese-welcome-before-acceptance")
        let reject: (XCUIElement) -> Bool = { alert in
            for label in ["Don’t Allow", "Don't Allow", "Ask App Not to Track", "不允许", "要求 App 不跟踪", "要求App不跟踪"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        let monitor = addUIInterruptionMonitor(withDescription: "Optional system permission; decline for this disposable audit", handler: reject)
        defer { removeUIInterruptionMonitor(monitor) }
        tap("accept_terms")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<10 {
            if item("play").waitForExistence(timeout: 2) { break }
            if springboard.alerts.firstMatch.exists { _ = reject(springboard.alerts.firstMatch) }
            else { app.tap() }
        }
        XCTAssertTrue(item("play").waitForExistence(timeout: 10))
        XCTAssertFalse(item("accept_terms").exists)
    }
    private func backgroundAndTerminate() {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()
    }
    private func completeActualTutorial() {
        // Execute the current generated L1 v3 path as player gestures. The
        // companion script checks this exact packaged board and saved plan.
        XCTAssertTrue(item("tutorial_title").waitForExistence(timeout: 10))
        func title(_ expected: String) {
            let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: item("tutorial_title"))
            XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 8), .completed)
        }
        func drag(_ first: Int, _ last: Int) {
            let from = item("cell_\(first)").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = item("cell_\(last)").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: to)
            expectValue("cell_\(first)", "marked"); expectValue("cell_\(last)", "marked")
        }
        title("Find the first capybara"); item("cell_1").doubleTap(); expectFound(1)
        title("Tap to mark X"); tap("cell_0"); expectValue("cell_0", "marked")
        title("Tap again to undo"); tap("cell_0"); expectValue("cell_0", "empty")
        title("Swipe across a row"); drag(2, 3)
        title("Swipe down a column"); drag(5, 9)
        title("Cross out the remaining spaces")
        for cell in [0, 13] { tap("cell_\(cell)"); expectValue("cell_\(cell)", "marked") }
        title("Give them space")
        for cell in [4, 6] { tap("cell_\(cell)"); expectValue("cell_\(cell)", "marked") }
        title("One space left in this row"); item("cell_7").doubleTap(); expectFound(2)
        title("Give them space"); drag(10, 11)
        title("One space left in this region"); item("cell_14").doubleTap(); expectFound(3)
        title("Find the last capybara"); tap("tutorial_hint"); item("cell_8").doubleTap()
        XCTAssertTrue(item("win_result").waitForExistence(timeout: 8))
        XCTAssertEqual(item("win_result").label, "Tutorial complete")
        XCTAssertEqual(item("next_level").label, "Start game")
        capture("actual-v3-tutorial-completed-full-board")
        // Normal restart keeps the existing L1 cold-recovery scenario useful.
        // It is attempt 2; tutorial remains completed and no stock is replenished.
        tap("result_home"); tap("settings"); tap("restart")
        expectValue("cell_1", "empty"); XCTAssertFalse(item("tutorial_title").exists)
        item("cell_1").doubleTap(); expectFound(1)
    }

    func test01CreatePersistentStateThroughUI() {
        app.launch(); acceptRealWelcome()
        tap("settings")
        for id in ["music_toggle", "sound_toggle", "voice_toggle", "haptics_toggle"] {
            expectValue(id, "1"); tap(id); expectValue(id, "0")
        }
        tap("language_en")
        XCTAssertEqual(item("settings_title").label, "Settings")
        capture("nondefault-settings-created-through-ui")
        tap("settings_done"); tap("check_in")
        XCTAssertEqual(item("checkin_streak").label, "0")
        tap("claim_reward")
        XCTAssertEqual(item("checkin_streak").label, "1")
        XCTAssertFalse(item("claim_reward").exists)
        capture("actual-checkin-claim")
        tap("checkin_home"); tap("play"); completeActualTutorial()
        tap("direct"); expectFound(2)
        expectValue("direct", "Video reward")
        capture("depleted-direct-tool-offers-simulated-video")
        tap("direct"); expectFound(3)
        expectValue("direct", "Video reward")
        // The player just learned that cell 0 shares the first animal's row.
        // Recreate that manual exclusion in the ordinary restarted attempt.
        tap("cell_0"); expectValue("cell_0", "marked")
        item("cell_0").doubleTap(); expectValue("lives", "2")
        XCTAssertGreaterThan(Int(item("score").label) ?? 0, 0)
        XCTAssertEqual(values().filter { $0 == "found" }.count, 3)
        expectValue("hint", "2 available")
        capture("real-game-state-after-one-simulated-reward")
        tap("home")
        backgroundAndTerminate()
    }

    func test02VerifyColdRestoreThroughUI() {
        app.launch()
        XCTAssertTrue(item("play").waitForExistence(timeout: 20))
        XCTAssertFalse(item("accept_terms").exists)
        XCTAssertEqual(item("play").label, "Level 1")
        tap("settings")
        XCTAssertEqual(item("settings_title").label, "Settings")
        for id in ["music_toggle", "sound_toggle", "voice_toggle", "haptics_toggle"] { expectValue(id, "0") }
        capture("cold-restored-nondefault-settings")
        tap("settings_done"); tap("check_in")
        XCTAssertEqual(item("checkin_streak").label, "1")
        XCTAssertFalse(item("claim_reward").exists)
        XCTAssertFalse(item("checkin_day_1").isEnabled)
        tap("checkin_home"); tap("play")
        XCTAssertTrue(item("cell_0").waitForExistence(timeout: 10))
        XCTAssertFalse(item("tutorial_title").exists)
        expectFound(3); expectValue("lives", "2")
        expectValue("direct", "Video reward"); expectValue("hint", "2 available")
        XCTAssertGreaterThan(Int(item("score").label) ?? 0, 0)
        XCTAssertEqual(item("cell_0").value as? String, "error")
        capture("cold-restored-actual-board-and-inventory")
        tap("home"); backgroundAndTerminate()
    }

    func test03VerifyInitialStateAfterReinstallThroughUI() {
        app.launch(); acceptRealWelcome()
        XCTAssertEqual(item("play").label, "第 1 关")
        tap("settings")
        XCTAssertEqual(item("settings_title").label, "设置")
        for id in ["music_toggle", "sound_toggle", "voice_toggle", "haptics_toggle"] { expectValue(id, "1") }
        capture("reinstalled-default-chinese-settings")
        tap("settings_done"); tap("check_in")
        XCTAssertEqual(item("checkin_streak").label, "0")
        XCTAssertTrue(item("claim_reward").isEnabled)
        capture("reinstalled-unclaimed-checkin")
        tap("checkin_home")
        // Do not start or claim anything: the script must observe truly initial
        // gameplay, inventory, check-in and reward-ledger data after reinstall.
        backgroundAndTerminate()
    }
}
