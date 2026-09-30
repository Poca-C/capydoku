import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class CompactLayoutMeasurements {
    var frames: [String: CGRect] = [:]
}

@MainActor private final class CompactLayoutRig {
    let measurements = CompactLayoutMeasurements()
    let directory: URL
    let model: AppModel
    let host: UIHostingController<AnyView>
    let window: UIWindow
    private let previousWindow: UIWindow?

    init(size: CGSize, usesRoot: Bool = false, type: DynamicTypeSize = .large, configure: (AppModel) throws -> Void) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("compact-layout-" + UUID().uuidString)
        model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true
        model.progress.settings.language = .simplifiedChinese
        try configure(model)
        let measurements = measurements
        let page: AnyView = usesRoot ? AnyView(RootView(reduceMotionOverride: true)) : model.screen == .checkIn
            ? AnyView(CheckInView(reduceMotionOverride: true)) : AnyView(GameView())
        host = UIHostingController(rootView: AnyView(page
            .environmentObject(model).environment(\.scenePhase, .active)
            .environment(\.appLanguage, .simplifiedChinese).foregroundColor(CapyPalette.ink)
            .dynamicTypeSize(type).background(CapyPalette.cream.ignoresSafeArea())
            .environment(\.capyLayoutObserver, { measurements.frames[$0] = $1 })))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        let container = UIViewController()
        container.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = container
        window.makeKeyAndVisible()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.clipsToBounds = true
        host.didMove(toParent: container)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }

    var views: [UIView] {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(host.view)
    }

    func frame(of identifier: String) throws -> CGRect {
        try XCTUnwrap(measurements.frames[identifier], "Missing actual measured control: " + identifier)
    }

    func close() {
        window.isHidden = true; window.rootViewController = nil
        previousWindow?.makeKeyAndVisible()
        model.flushPendingSaves()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Actual hosted pages at explicit portrait viewports. These checks do not
/// simulate a physical small iPhone, operating-system safe-area behavior, or
/// real finger gestures. The board must have no scrolling ancestor at all.
final class CompactLayoutTests: XCTestCase {
    @MainActor private func settle(_ rig: CompactLayoutRig) async throws {
        try await Task.sleep(nanoseconds: 180_000_000)
        rig.host.view.layoutIfNeeded()
    }

    @MainActor private func capture(_ rig: CompactLayoutRig, _ name: String) throws {
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: rig.host.view.bounds).image { _ in
            drawn = rig.host.view.drawHierarchy(in: rig.host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn)
        XCTAssertGreaterThan(Set(try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data).count, 16)
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func assertVisible(_ frame: CGRect, within bounds: CGRect, _ identifier: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - 1, identifier, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY - 1, identifier, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 1, identifier, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 1, identifier, file: file, line: line)
    }

    @MainActor func testGameplayFitsCompactAndRegularPortraitWithoutScrollingTheBoard() async throws {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 390, height: 844)] {
            for (level, boardSize) in [(1, 4), (6, 6), (51, 8), (101, 10)] {
                let rig = try CompactLayoutRig(size: size) { $0.start(level: level) }
                defer { rig.close() }
                try await settle(rig)
                try capture(rig, "portrait-\(Int(size.width))x\(Int(size.height))-board-\(boardSize)x\(boardSize)")
                XCTAssertEqual(rig.host.view.bounds.size, size)
                let board = try XCTUnwrap(rig.views.first { $0.accessibilityIdentifier == "puzzle_board" })
                let boardFrame = board.convert(board.bounds, to: rig.host.view)
                XCTAssertEqual(boardFrame.minX, try rig.frame(of: "puzzle_board").minX, accuracy: 1)
                XCTAssertEqual(boardFrame.minY, try rig.frame(of: "puzzle_board").minY, accuracy: 1)
                XCTAssertEqual(boardFrame.width, boardFrame.height, accuracy: 1)
                XCTAssertGreaterThanOrEqual(boardFrame.width, 190 - 0.01)
                assertVisible(boardFrame, within: rig.host.view.bounds, "board")
                var ancestor = board.superview
                while let current = ancestor {
                    XCTAssertFalse(current is UIScrollView, "Page scrolling must never compete with board marking gestures.")
                    ancestor = current.superview
                }
                let home = try rig.frame(of: "home"), settings = try rig.frame(of: "settings")
                let title = try rig.frame(of: "level_title"), progress = try rig.frame(of: "found_count")
                let lives = try rig.frame(of: "lives"), rules = try rig.frame(of: "rule_strip")
                let hint = try rig.frame(of: "hint")
                for (identifier, frame) in [("home", home), ("settings", settings), ("hint", hint)] {
                    assertVisible(frame, within: rig.host.view.bounds, identifier)
                    XCTAssertGreaterThanOrEqual(frame.width, 44, identifier)
                    XCTAssertGreaterThanOrEqual(frame.height, 44, identifier)
                }
                for (identifier, frame) in [("title", title), ("progress", progress), ("lives", lives), ("rules", rules)] {
                    assertVisible(frame, within: rig.host.view.bounds, identifier)
                }
                XCTAssertGreaterThanOrEqual(title.minY, settings.maxY - 1)
                XCTAssertGreaterThanOrEqual(progress.minY, title.maxY - 1)
                XCTAssertGreaterThanOrEqual(rules.minY, max(progress.maxY, lives.maxY) - 1)
                XCTAssertGreaterThanOrEqual(boardFrame.minY, rules.maxY - 1)
                XCTAssertGreaterThanOrEqual(hint.minY, boardFrame.maxY)
            }
        }
    }

    @MainActor func testSevenDayCheckInRemainsReachableAtCompactAndRegularWidths() async throws {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 390, height: 844)] {
            let rig = try CompactLayoutRig(size: size) { model in
                model.start(level: 1)
                let today = Date(timeIntervalSince1970: 1_790_784_000)
                for daysAgo in stride(from: 6, through: 1, by: -1) {
                    _ = model.progress.claimCheckIn(on: today.addingTimeInterval(-Double(daysAgo) * 86_400), config: model.config)
                }
                model.now = today; model.screen = .checkIn
            }
            defer { rig.close() }
            try await settle(rig)
            try capture(rig, "portrait-\(Int(size.width))x\(Int(size.height))-checkin-leading")
            let boardBefore = rig.model.session, checkInBefore = rig.model.progress.checkIn
            XCTAssertEqual(rig.model.config.checkInCycleDays, 7)
            if size.width == 320 {
                let scroll = try XCTUnwrap(rig.views.compactMap { $0 as? UIScrollView }.first {
                    $0.contentSize.width > $0.bounds.width + 10
                }, "A seven-day strip must scroll on narrow screens while keeping every target at least 44pt.")
                XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1)
                let first = try rig.frame(of: "checkin_day_1")
                assertVisible(first, within: rig.host.view.bounds, "first day")
                XCTAssertGreaterThanOrEqual(first.width, 44); XCTAssertGreaterThanOrEqual(first.height, 44)
                scroll.setContentOffset(CGPoint(x: scroll.contentSize.width - scroll.bounds.width, y: 0), animated: false)
                try await settle(rig)
                try capture(rig, "portrait-320x568-checkin-trailing")
            } else {
                XCTAssertFalse(rig.views.compactMap { $0 as? UIScrollView }.contains {
                    $0.contentSize.width > $0.bounds.width + 10
                }, "The normal-width seven-day row must retain its existing arrangement.")
            }
            let gift = try rig.frame(of: "claim_reward")
            assertVisible(gift, within: rig.host.view.bounds, "seventh-day gift")
            XCTAssertGreaterThanOrEqual(gift.width, 44); XCTAssertGreaterThanOrEqual(gift.height, 44)
            XCTAssertEqual(rig.model.session, boardBefore)
            XCTAssertEqual(rig.model.progress.checkIn, checkInBefore, "Scrolling cannot claim or duplicate the reward.")
        }
    }

    @MainActor func testCompactHintTutorialAndConfiguredFreeToolRemainUsableWithoutPageScrolling() async throws {
        for state in ["hint", "tutorial", "free-tool"] {
            let rig = try CompactLayoutRig(size: CGSize(width: 320, height: 568),
                                           type: state == "hint" ? .accessibility5 : .large) { model in
                if state == "free-tool" {
                    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
                    var row = try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: url))
                    row.adsEnabled = true
                    row.levelStartFreeAd.visible = true
                    row.levelStartFreeAd.enabled = true
                    row.levelStartFreeAd.buttonState = .enabled
                    model.config = DemoConfig(referenceGameplay: row)
                }
                model.start(level: 1)
                if state == "hint" { model.showHint() }
                if state == "tutorial" {
                    model.progress.tutorialCompleted = false
                    let steps = PuzzleHints.tutorial(puzzle: try XCTUnwrap(model.session).puzzle)
                    model.progress.tutorialStep = try XCTUnwrap(steps.firstIndex { $0.action == "read" })
                }
            }
            defer { rig.close() }
            try await settle(rig)
            let before = rig.model.session, claimBefore = rig.model.progress.checkIn
            try capture(rig, "portrait-320x568-\(state)-initial")
            let board = try XCTUnwrap(rig.views.first { $0.accessibilityIdentifier == "puzzle_board" })
            let boardFrame = board.convert(board.bounds, to: rig.host.view)
            assertVisible(boardFrame, within: rig.host.view.bounds, "board in " + state)
            XCTAssertEqual(boardFrame.width, boardFrame.height, accuracy: 1)
            XCTAssertGreaterThanOrEqual(boardFrame.width, 190 - 0.01)
            var ancestor = board.superview
            while let current = ancestor {
                XCTAssertFalse(current is UIScrollView)
                ancestor = current.superview
            }
            let controls = state == "hint" ? ["hint_close", "hint_apply"] : state == "tutorial" ? ["skip_tutorial"] : ["direct", "level_start_free", "hint"]
            for identifier in controls {
                let frame = try rig.frame(of: identifier)
                assertVisible(frame, within: rig.host.view.bounds, identifier)
                XCTAssertGreaterThanOrEqual(frame.width, 44)
                XCTAssertGreaterThanOrEqual(frame.height, 44)
            }
            if state == "tutorial" || state == "hint" {
                let scroll = try XCTUnwrap(rig.views.compactMap { $0 as? UIScrollView }.first {
                    $0.contentSize.height > $0.bounds.height + 1
                }, "Only the text panel should scroll when its content needs more space.")
                let scrollFrame = scroll.convert(scroll.bounds, to: rig.host.view)
                XCTAssertFalse(scrollFrame.intersects(boardFrame), "A text scroll viewport cannot cover the board.")
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
                try await settle(rig)
                try capture(rig, "portrait-320x568-\(state)-scrolled")
                if state == "tutorial" {
                    let next = try rig.frame(of: "tutorial_next")
                    assertVisible(next, within: rig.host.view.bounds, "tutorial confirm after scrolling")
                    XCTAssertGreaterThanOrEqual(next.width, 44); XCTAssertGreaterThanOrEqual(next.height, 44)
                }
            }
            XCTAssertEqual(rig.model.session, before)
            XCTAssertEqual(rig.model.progress.checkIn, claimBefore)
        }
    }

    @MainActor func testActualRootPagesAtCompactViewportRetainTheBoardAndScrollableGift() async throws {
        for page in ["game", "check-in"] {
            let rig = try CompactLayoutRig(size: CGSize(width: 320, height: 568), usesRoot: true) { model in
                model.start(level: 51)
                if page == "check-in" { model.screen = .checkIn }
            }
            defer { rig.close() }
            try await settle(rig)
            try capture(rig, "root-320x568-\(page)-leading")
            if page == "game" {
                let board = try XCTUnwrap(rig.views.first { $0.accessibilityIdentifier == "puzzle_board" })
                let frame = board.convert(board.bounds, to: rig.host.view)
                assertVisible(frame, within: rig.host.view.bounds, "actual Root board")
                XCTAssertEqual(frame.width, frame.height, accuracy: 1)
                XCTAssertGreaterThanOrEqual(frame.width, 190 - 0.01)
            } else {
                let scroll = try XCTUnwrap(rig.views.compactMap { $0 as? UIScrollView }.first {
                    $0.contentSize.width > $0.bounds.width + 10
                })
                scroll.setContentOffset(CGPoint(x: scroll.contentSize.width - scroll.bounds.width, y: 0), animated: false)
                try await settle(rig)
                try capture(rig, "root-320x568-check-in-trailing")
            }
        }
    }
}
