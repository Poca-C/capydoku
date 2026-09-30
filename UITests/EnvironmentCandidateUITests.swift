import XCTest

/// Normal installed candidates only: no launch arguments/environment overrides,
/// save injection, reset, debug controls, or access to com.capydoku.demo.
/// Run these three cases explicitly after installing the optimized candidates.
/// The runner must separately verify their real Capydoku-<environment> storage
/// roots; UI success alone cannot establish which sandbox directory was used.
final class EnvironmentCandidateUITests: XCTestCase {
    private var app: XCUIApplication!
    private var candidate = ""
    private var observations: [String] = []

    private struct BoardSnapshot: Equatable {
        let values: [String]
        let score: String
        let lives: String
        let hints: Int
        let finds: Int
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // xcodebuild's documented TEST_RUNNER_ prefix passes this opt-in only
        // to the test runner. Normal UI suites need no installed candidates.
        // It is never added to the application arguments or environment.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CAPYDOKU_CANDIDATE_UI"] == "1",
                          "Install all three optimized candidates and explicitly enable this integration suite.")
    }

    override func tearDownWithError() throws {
        if app != nil { app.terminate() }
        let report = XCTAttachment(string: observations.joined(separator: "\n"))
        report.name = "\(candidate)-actual-path-observations"
        report.lifetime = .keepAlways
        add(report)
    }

    func testTestingCandidateNormalChinesePlayAndColdRestore() {
        exerciseCandidate("testing")
    }

    func testStagingCandidateNormalChinesePlayAndColdRestore() {
        exerciseCandidate("staging")
    }

    func testProductionCandidateNormalChinesePlayAndColdRestore() {
        exerciseCandidate("production")
    }

    private func item(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitFor(_ condition: @escaping () -> Bool, _ message: String,
                         timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message, file: file, line: line)
    }

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let control = item(id)
        waitFor({ control.exists && control.isHittable }, "Control must become reachable: \(id)", file: file, line: line)
        control.tap()
    }

    private func expectValue(_ id: String, _ value: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        waitFor({ self.item(id).value as? String == value }, "Expected \(id) = \(value)", file: file, line: line)
    }

    private func expectLabel(_ id: String, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        waitFor({ self.item(id).label == label }, "Expected \(id) label \(label)", file: file, line: line)
    }

    private func capture(_ name: String, system: Bool = false) {
        let attachment = XCTAttachment(screenshot: system ? XCUIScreen.main.screenshot() : app.screenshot())
        attachment.name = "\(candidate)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Declines only the observed optional permission, never a guessed button or
    /// an arbitrary screen coordinate. OS decisions may already be remembered;
    /// an absent prompt is recorded as absent, not claimed as a new denial test.
    private func rejectOptionalPermission(_ alert: XCUIElement) -> Bool {
        let tracking = ["Ask App Not to Track", "要求 App 不跟踪", "要求App不跟踪"]
        let refusal = ["Don’t Allow", "Don't Allow", "不允许"]
        for label in tracking + refusal where alert.buttons[label].exists {
            capture("system-permission-before-denial-\(observations.count)", system: true)
            observations.append("Observed system alert: \(alert.label); tapped denial: \(label)")
            alert.buttons[label].tap()
            return true
        }
        return false
    }

    private func launchToHome(allowFirstWelcome: Bool, expectedPlayLabel: String) {
        let monitor = addUIInterruptionMonitor(withDescription: "Decline candidate optional system permissions") { [weak self] alert in
            self?.rejectOptionalPermission(alert) ?? false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        // Intentionally leave both launchArguments and launchEnvironment alone.
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(45)
        var acceptedWelcome = false
        while Date() < deadline {
            if item("play").exists && item("play").isHittable { break }
            if item("accept_terms").exists && item("accept_terms").isHittable {
                XCTAssertTrue(allowFirstWelcome && !acceptedWelcome, "Saved acceptance must survive a normal cold launch.")
                expectLabel("accept_terms", "同意并继续")
                capture("normal-welcome")
                observations.append("Observed and accepted actual Chinese Welcome.")
                tap("accept_terms")
                acceptedWelcome = true
                continue
            }
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                XCTAssertTrue(rejectOptionalPermission(alert), "Unexpected system alert; no unapproved button is selected.")
                continue
            }
            // Waiting does not activate Home controls or alter a board behind a
            // late permission alert. The interruption monitor is a fallback.
            _ = item("play").waitForExistence(timeout: 1)
        }
        XCTAssertTrue(item("play").waitForExistence(timeout: 5), "Normal startup must reach Home after optional permission refusal.")
        XCTAssertFalse(item("accept_terms").exists)
        expectLabel("play", expectedPlayLabel)
        observations.append(acceptedWelcome ? "This launch traversed Welcome and the available OS permission flow."
                            : "This launch used existing acceptance; absent permission dialogs are not new permission coverage.")
    }

    private func backgroundAndTerminate() {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    private func drag(from start: Int, to end: Int) {
        let first = item("cell_\(start)"), last = item("cell_\(end)")
        waitFor({ first.isHittable && last.isHittable }, "Teaching swipe endpoints must be reachable.")
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    }

    private func completeFreshTutorialIfPresent() {
        guard item("tutorial_title").exists else {
            observations.append("Tutorial already completed; not replayed or reset.")
            return
        }
        // Exact unchanged Resources/levels.json fixture: original-pipeline-v3,
        // L1 4x4, seed 11400714819535654101, solution [1, 7, 8, 14].
        // Singleton region at 8 proves the current v2 path: region, neighbors,
        // row, column, tap/undo 0, swipe 4->5, swipe 9->13, double-tap 8.
        // A partly played/other tutorial is not reset or silently skipped.
        let rules = ["每个区域一只", "保持距离", "每行一只", "每列一只"]
        for (index, rule) in rules.enumerated() {
            expectLabel("tutorial_title", "\(index + 1)/9 · \(rule)")
            if index == 0 { capture("current-pack-chinese-tutorial") }
            tap("tutorial_next")
        }
        expectLabel("tutorial_title", "5/9 · 单击标记 X")
        tap("cell_0"); expectValue("cell_0", "marked")
        expectLabel("tutorial_title", "6/9 · 再次单击撤销")
        tap("cell_0"); expectValue("cell_0", "empty")
        expectLabel("tutorial_title", "7/9 · 沿一行滑动")
        drag(from: 4, to: 5)
        expectValue("cell_4", "marked"); expectValue("cell_5", "marked")
        expectLabel("tutorial_title", "8/9 · 沿一列滑动")
        drag(from: 9, to: 13)
        expectValue("cell_9", "marked"); expectValue("cell_13", "marked")
        expectLabel("tutorial_title", "9/9 · 双击寻找")
        item("cell_8").doubleTap(); expectValue("cell_8", "found")
        waitFor({ !self.item("tutorial_title").exists && self.item("hint").exists }, "Tutorial must finish into ordinary play.")
        XCTAssertEqual((0..<16).map { item("cell_\($0)").value as? String ?? "missing" },
                       (0..<16).map { $0 == 8 ? "found" : [4, 5, 9, 13].contains($0) ? "marked" : "empty" })
        observations.append("Completed all nine current-pack teaching steps through real UI gestures.")
        capture("chinese-tutorial-complete-one-found")
    }

    private func inventory(_ id: String) -> Int {
        let value = item(id).value as? String ?? ""
        if value == "Video reward" || value == "观看广告获取奖励" { return 0 }
        let numbers = value.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        XCTAssertEqual(numbers.count, 1, "Unrecognized visible inventory value for \(id): \(value)")
        return numbers.first.flatMap(Int.init) ?? -1
    }

    private func snapshot(chinese: Bool) -> BoardSnapshot {
        XCTAssertTrue(item("cell_15").waitForExistence(timeout: 10))
        expectLabel("level_title", chinese ? "第 1 关" : "Level 1")
        // Validate the actual visible region map as well as the player marks;
        // matching values alone would not establish restoration of the same board.
        let regions = [0, 0, 1, 1, 0, 0, 0, 1, 2, 3, 0, 1, 3, 3, 3, 1]
        let values = (0..<16).map { index -> String in
            let cell = item("cell_\(index)")
            let position = chinese
                ? "第 \(index / 4 + 1) 行，第 \(index % 4 + 1) 列，第 \(regions[index] + 1) 号区域"
                : "Row \(index / 4 + 1), column \(index % 4 + 1), region \(regions[index] + 1)"
            XCTAssertTrue(cell.label.hasPrefix(position), "Unexpected current-pack cell position/region: \(cell.label)")
            let value = cell.value as? String ?? "missing"
            XCTAssertTrue(["empty", "marked", "found", "error"].contains(value))
            return value
        }
        return BoardSnapshot(values: values, score: item("score").label,
                             lives: item("lives").value as? String ?? "missing",
                             hints: inventory("hint"), finds: inventory("direct"))
    }

    private func assertClaimedCalendar(streak: String) {
        expectLabel("checkin_streak", streak)
        waitFor({ !self.item("claim_reward").exists }, "A same-day reward must not be claimable twice.")
        for day in 1...7 {
            let control = item("checkin_day_\(day)")
            XCTAssertTrue(control.exists)
            XCTAssertFalse(control.isEnabled, "Claimed and future calendar dates are read-only.")
        }
    }

    private func exerciseCandidate(_ environment: String) {
        XCTAssertTrue(["testing", "staging", "production"].contains(environment))
        candidate = environment
        let bundleID = "com.capydoku.demo." + environment
        observations = ["Candidate: \(bundleID)", "Normal launch; no app arguments/environment overrides; no save injection or reset."]
        app = XCUIApplication(bundleIdentifier: bundleID)
        let utcDayAtStart = Int(Date().timeIntervalSince1970 / 86_400)
        launchToHome(allowFirstWelcome: true, expectedPlayLabel: "第 1 关")
        expectLabel("settings", "设置")
        capture("normal-chinese-home")
        tap("play")
        XCTAssertTrue(item("cell_15").waitForExistence(timeout: 10))
        completeFreshTutorialIfPresent()
        let before = snapshot(chinese: true)
        XCTAssertEqual(before.values.filter { $0 == "found" }.count, 1, "Expected newly taught or previously audited L1; do not alter unrelated saved gameplay.")
        XCTAssertEqual(before.values[8], "found")
        XCTAssertEqual(before.score, "100"); XCTAssertEqual(before.lives, "3")
        tap("home"); tap("settings"); tap("language_en")
        expectLabel("settings_title", "Settings"); expectValue("language_en", "Selected")
        capture("english-settings")
        tap("settings_done"); expectLabel("play", "Level 1")
        backgroundAndTerminate()

        launchToHome(allowFirstWelcome: false, expectedPlayLabel: "Level 1")
        tap("play")
        XCTAssertFalse(item("tutorial_title").exists)
        XCTAssertEqual(snapshot(chinese: false), before)
        capture("english-cold-restored-same-board")
        tap("home"); tap("settings"); tap("language_zh_hans")
        expectLabel("settings_title", "设置"); expectValue("language_zh_hans", "已选择")
        tap("settings_done"); tap("check_in")
        XCTAssertTrue(item("checkin_streak").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["连续签到天数"].exists)
        let claimedThisRun = item("claim_reward").exists
        if claimedThisRun {
            capture("checkin-before-one-real-claim")
            tap("claim_reward")
            waitFor({ !self.item("claim_reward").exists }, "The real claim must finish durably.")
            observations.append("Claimed one available reward through the normal Chinese calendar.")
        } else {
            observations.append("Reward already claimed before this run; this run checks persistence/no second claim only.")
        }
        let streak = item("checkin_streak").label
        XCTAssertGreaterThan(Int(streak) ?? 0, 0)
        assertClaimedCalendar(streak: streak)
        capture("chinese-checkin-claimed-disabled")
        tap("checkin_home"); tap("play")
        let afterClaim = snapshot(chinese: true)
        XCTAssertEqual(afterClaim.values, before.values)
        XCTAssertEqual(afterClaim.score, before.score); XCTAssertEqual(afterClaim.lives, before.lives)
        XCTAssertEqual(afterClaim.finds, before.finds)
        XCTAssertEqual(afterClaim.hints, before.hints + (claimedThisRun ? 1 : 0), "Current provisional daily reward grants exactly one hint.")
        tap("home")
        backgroundAndTerminate()

        launchToHome(allowFirstWelcome: false, expectedPlayLabel: "第 1 关")
        tap("check_in")
        XCTAssertEqual(Int(Date().timeIntervalSince1970 / 86_400), utcDayAtStart, "A real UTC midnight crossed; same-day no-repeat evidence requires a separate run, not clock manipulation.")
        assertClaimedCalendar(streak: streak)
        capture("cold-restored-chinese-checkin-no-repeat")
        tap("checkin_home"); tap("play")
        XCTAssertFalse(item("tutorial_title").exists)
        XCTAssertEqual(snapshot(chinese: true), afterClaim)
        capture("cold-restored-chinese-same-board-and-inventory")
        tap("home")
        backgroundAndTerminate()
        observations.append("English and Chinese cold launches preserved the actual board, score, lives and tool stock; same-day check-in stayed unclaimable.")
    }
}
