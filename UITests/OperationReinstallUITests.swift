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
        // Current packaged Level 1 path, also covered by the ordinary guided
        // tutorial regression. The script verifies this exact installed pack's
        // singleton/answer coordinates before executing the UI; this is not a
        // claim that the UI can discover targets for arbitrary generated boards.
        XCTAssertTrue(item("tutorial_title").waitForExistence(timeout: 10))
        for _ in 0..<4 { tap("tutorial_next") }
        tap("cell_0"); expectValue("cell_0", "marked")
        tap("cell_0"); expectValue("cell_0", "empty")
        for pair in [[4, 5], [9, 13]] {
            let from = item("cell_\(pair[0])").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = item("cell_\(pair[1])").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: to)
            for index in pair { expectValue("cell_\(index)", "marked") }
        }
        item("cell_8").doubleTap(); expectFound(1)
        XCTAssertFalse(item("tutorial_title").exists)
        capture("actual-nine-step-tutorial-completed")
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
        // A teaching exclusion is a genuine incorrect answer; exercise life/error
        // persistence without reading or injecting the stored board solution.
        let marked = (0..<16).filter { item("cell_\($0)").value as? String == "marked" }
        XCTAssertFalse(marked.isEmpty)
        item("cell_\(marked[0])").doubleTap(); expectValue("lives", "2")
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
        XCTAssertGreaterThan(values().filter { $0 == "marked" }.count, 0)
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
