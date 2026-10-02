import XCTest

/// No language override: verifies the actual Chinese default and saved switch.
final class AppLanguageUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }
    private func item(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func tap(_ id: String) {
        XCTAssertTrue(item(id).waitForExistence(timeout: 10))
        item(id).tap()
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func board(_ size: Int = 4) -> [String] {
        (0..<size * size).map { item("cell_\($0)").value as? String ?? "missing" }
    }

    func testDefaultChineseSwitchAndRelaunchPreserveBoard() {
        app.launchArguments = ["-ui-testing", "-reset-demo", "-skip-tutorial"]
        app.launch()
        XCTAssertTrue(item("play").waitForExistence(timeout: 12))
        XCTAssertEqual(item("play").label, "第 1 关")
        XCTAssertEqual(item("settings").label, "设置")
        capture("chinese-home")
        tap("play")
        XCTAssertTrue(item("cell_0").waitForExistence(timeout: 8))
        item("cell_0").tap()
        let marked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "marked"), object: item("cell_0"))
        XCTAssertEqual(XCTWaiter.wait(for: [marked], timeout: 5), .completed)
        let before = board()
        XCTAssertTrue(item("cell_0").label.contains("第 1 行"))
        XCTAssertTrue(item("cell_0").label.contains("已标记排除"))
        tap("settings")
        XCTAssertEqual(item("settings_title").label, "设置")
        for id in ["language_zh_hans", "language_en"] {
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.item(id).frame.height >= 44
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 4), .completed)
            XCTAssertTrue(item(id).isHittable)
            XCTAssertGreaterThanOrEqual(item(id).frame.height, 44)
        }
        capture("chinese-settings")
        tap("language_en")
        XCTAssertEqual(item("settings_title").label, "Settings")
        XCTAssertEqual(item("language_en").value as? String, "Selected")
        capture("english-settings")
        tap("settings_done")
        XCTAssertEqual(item("level_title").label, "Level 1")
        XCTAssertTrue(item("cell_0").label.contains("Row 1"))
        XCTAssertEqual(board(), before)
        app.terminate(); app.launchArguments = ["-ui-testing"]; app.launch()
        XCTAssertTrue(item("play").waitForExistence(timeout: 12))
        XCTAssertEqual(item("play").label, "Level 1")
        tap("play")
        XCTAssertEqual(board(), before)
        capture("english-restored-game")
        tap("settings"); tap("language_zh_hans"); tap("settings_done")
        XCTAssertEqual(item("level_title").label, "第 1 关")
        XCTAssertEqual(board(), before)
        tap("hint")
        XCTAssertTrue(item("hint_apply").waitForExistence(timeout: 8))
        XCTAssertEqual(item("hint_apply").label, "应用")
        XCTAssertTrue(item("hint_explanation").label.contains("提示。"))
        XCTAssertFalse(item("hint_explanation").label.contains("candidate"))
        capture("chinese-hint")
        tap("hint_close"); tap("home"); tap("check_in")
        XCTAssertTrue(app.staticTexts["连续签到天数"].waitForExistence(timeout: 5))
        capture("chinese-checkin")
        app.terminate(); app.launch()
        XCTAssertTrue(item("play").waitForExistence(timeout: 12))
        XCTAssertEqual(item("play").label, "第 1 关")
        tap("play")
        XCTAssertEqual(board(), before)
    }

    func testChineseTutorialAndAllBoardSizesRender() {
        app.launchArguments = ["-ui-testing", "-reset-demo", "-level", "1"]
        app.launch()
        XCTAssertTrue(item("tutorial_title").waitForExistence(timeout: 12))
        XCTAssertEqual(item("tutorial_title").label, "找到第一只卡皮巴拉")
        XCTAssertTrue(app.staticTexts["每种颜色的区域各有一只卡皮巴拉。双击这个区域里唯一的格子，找到它。"].exists)
        XCTAssertFalse(item("tutorial_next").exists, "The current introduction starts with a real board action.")
        XCTAssertTrue(item("cell_1").isHittable)
        capture("chinese-v3-tutorial-first-action")
        item("cell_1").doubleTap()
        let found = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "found"), object: item("cell_1"))
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 5), .completed)
        XCTAssertEqual(item("tutorial_title").label, "单击标记 X")
        XCTAssertTrue(app.staticTexts["这一行已经有卡皮巴拉了。单击高亮空格，标记 X。"].exists)
        XCTAssertEqual(board(), (0..<16).map { $0 == 1 ? "found" : "empty" })
        capture("chinese-v3-tutorial-first-placement")
        for (level, size) in [(1,4), (6,6), (51,8), (101,10)] {
            app.terminate()
            app.launchArguments = ["-ui-testing", "-reset-demo", "-skip-tutorial", "-level", "\(level)"]
            app.launch()
            XCTAssertTrue(item("cell_\(size * size - 1)").waitForExistence(timeout: 12))
            XCTAssertEqual(item("level_title").label, "第 \(level) 关")
            XCTAssertTrue(item("hint").isHittable)
            XCTAssertEqual(item("hint").label, "提示")
            XCTAssertGreaterThan(item("hint").frame.minY, item("puzzle_board").frame.maxY)
            capture("chinese-board-\(size)x\(size)")
        }
    }

    func testChineseFirstLaunchLegalCopy() {
        app.launchArguments = ["-ui-testing", "-reset-demo", "-test-first-launch"]
        app.launch()
        XCTAssertTrue(item("accept_terms").waitForExistence(timeout: 12))
        XCTAssertEqual(item("accept_terms").label, "同意并继续")
        capture("chinese-welcome")
        app.buttons["服务条款"].tap()
        XCTAssertTrue(app.staticTexts["内部测试版"].waitForExistence(timeout: 5))
        capture("chinese-legal-placeholder")
        app.buttons["关闭"].tap()
        XCTAssertTrue(item("accept_terms").waitForExistence(timeout: 5))
    }
}
