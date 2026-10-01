import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class CheckInClock {
    var time: TimeInterval = 0
    var callbacks: [(TimeInterval, () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) { callbacks.append((time + delay, action)) }
    func advance(_ delta: TimeInterval) {
        let target = time + delta
        while let index = callbacks.indices.filter({ callbacks[$0].0 <= target }).min(by: { callbacks[$0].0 < callbacks[$1].0 }) {
            let next = callbacks.remove(at: index); time = next.0; next.1()
        }
        time = target
    }
}

final class CheckInChoreographyTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 25_000 * 86_400)
    @MainActor private func model() -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("check-in-choreography-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
    }
    private func claimed(_ initial: PlayerProgress, date: Date) -> PlayerProgress {
        var value = initial; _ = value.claimCheckIn(on: date); return value
    }
    @MainActor func testOnlyCommittedNewDayProducesThreeStagesAndActualRewardReceipt() {
        let clock = CheckInClock(), effects = CheckInChoreography(schedule: clock.schedule)
        let before = PlayerProgress(), after = claimed(before, date: day)
        effects.bind(.init(before)); effects.observe(.init(after), visible: true, animated: true)
        XCTAssertEqual(effects.phase, .illuminating)
        XCTAssertEqual(effects.receipt?.hints, after.bonusHints - before.bonusHints)
        XCTAssertEqual(effects.receipt?.direct, after.bonusDirect - before.bonusDirect)
        XCTAssertEqual(effects.receipt?.cycleDay, 1)
        XCTAssertNotNil(effects.animationID)
        clock.advance(0.24); XCTAssertEqual(effects.phase, .streak)
        clock.advance(0.28); XCTAssertEqual(effects.phase, .reward)
        clock.advance(0.61); XCTAssertEqual(effects.phase, .settled); XCTAssertNil(effects.animationID)
        XCTAssertNotNil(effects.receipt, "The awarded amount remains readable after decoration ends.")
    }
    @MainActor func testCycleReceiptContainsSavedHintAndDirectDeltas() {
        let effects = CheckInChoreography(schedule: { _, _ in })
        var before = PlayerProgress()
        for prior in stride(from: 6, through: 1, by: -1) {
            before = claimed(before, date: day.addingTimeInterval(-Double(prior) * 86_400))
        }
        let after = claimed(before, date: day)
        effects.bind(.init(before)); effects.observe(.init(after), visible: true, animated: true)
        XCTAssertEqual(effects.receipt?.cycleDay, 7)
        XCTAssertEqual(effects.receipt?.hints, 1); XCTAssertEqual(effects.receipt?.direct, 1)
        XCTAssertEqual(after.checkIn.completedCycles, before.checkIn.completedCycles + 1)
    }
    @MainActor func testRestoreReentryDuplicateAndInventoryOnlyUpdatesNeverReplay() {
        let clock = CheckInClock(), effects = CheckInChoreography(schedule: clock.schedule)
        let saved = claimed(PlayerProgress(), date: day)
        effects.bind(.init(saved)); effects.observe(.init(saved), visible: true, animated: true)
        var stockChange = saved; stockChange.bonusHints += 3
        effects.observe(.init(stockChange), visible: true, animated: true)
        effects.unbind(); effects.bind(.init(saved)); clock.advance(2)
        XCTAssertNil(effects.animationID); XCTAssertNil(effects.receipt); XCTAssertEqual(effects.phase, .idle)
        XCTAssertTrue(clock.callbacks.isEmpty)
    }
    @MainActor func testHiddenClaimAndCancelledAnimationCannotReplayOnReturn() {
        let clock = CheckInClock(), effects = CheckInChoreography(schedule: clock.schedule)
        let before = PlayerProgress(), after = claimed(before, date: day)
        effects.bind(.init(before)); effects.observe(.init(after), visible: false, animated: true)
        effects.observe(.init(after), visible: true, animated: true)
        XCTAssertNil(effects.animationID); XCTAssertNil(effects.receipt)
        let next = claimed(after, date: day.addingTimeInterval(86_400))
        effects.observe(.init(next), visible: true, animated: true)
        effects.cancel(); clock.advance(2)
        XCTAssertNil(effects.animationID); XCTAssertEqual(effects.phase, .settled)
        effects.observe(.init(next), visible: true, animated: true)
        XCTAssertNil(effects.animationID)
    }
    @MainActor func testReducedMotionAndLowPowerUseImmediateReadableReceipt() {
        let clock = CheckInClock(), effects = CheckInChoreography(schedule: clock.schedule)
        let before = PlayerProgress(), after = claimed(before, date: day)
        effects.bind(.init(before)); effects.observe(.init(after), visible: true, animated: false)
        XCTAssertEqual(effects.phase, .settled); XCTAssertNil(effects.animationID)
        XCTAssertEqual(effects.receipt?.hints, 1); XCTAssertTrue(clock.callbacks.isEmpty)
    }
    @MainActor func testCancelledCallbacksCannotAdvanceANewerClaim() {
        let clock = CheckInClock(), effects = CheckInChoreography(schedule: clock.schedule)
        let before = PlayerProgress(), first = claimed(before, date: day)
        effects.bind(.init(before)); effects.observe(.init(first), visible: true, animated: true)
        clock.advance(0.12); effects.cancel()
        let next = claimed(first, date: day.addingTimeInterval(86_400))
        effects.observe(.init(next), visible: true, animated: true)
        clock.advance(0.12)
        XCTAssertEqual(effects.phase, .illuminating, "The first claim's 0.24s callback must be ignored.")
        clock.advance(0.12); XCTAssertEqual(effects.phase, .streak)
        XCTAssertEqual(effects.receipt?.day, next.checkIn.lastClaimedDay)
    }
    @MainActor func testFailedSaveCreatesNeitherClaimNorSuccessReceiptAndRetryCommitsOnce() throws {
        let model = model(), effects = CheckInChoreography(schedule: { _, _ in })
        model.save(force: true)
        let url = model.saveDirectory.appendingPathComponent("progress.json")
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let before = model.progress
        effects.bind(.init(before)); model.claim()
        effects.observe(.init(model.progress), visible: true, animated: true)
        XCTAssertEqual(model.progress, before); XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(effects.animationID); XCTAssertNil(effects.receipt)
        try FileManager.default.removeItem(at: url); try data.write(to: url)
        model.errorMessage = nil; model.claim()
        effects.observe(.init(model.progress), visible: true, animated: true)
        XCTAssertNotNil(effects.animationID)
        let restored = AppModel(saveDirectory: model.saveDirectory, runsTimer: false, feedbackEnabled: false)
        XCTAssertEqual(restored.progress.checkIn, model.progress.checkIn)
        XCTAssertEqual(restored.progress.bonusHints, model.progress.bonusHints)
        let committed = model.progress
        model.claim(); effects.observe(.init(model.progress), visible: true, animated: true)
        XCTAssertEqual(model.progress, committed)
    }
    @MainActor func testReadyGiftDoesNotReplayWhenTheSamePageReopensOrClockRollsBack() {
        let owner = NSObject(), otherInstall = NSObject()
        XCTAssertTrue(CheckInGiftCueMemory.consume(owner: owner, day: 25_000))
        XCTAssertFalse(CheckInGiftCueMemory.consume(owner: owner, day: 25_000))
        XCTAssertFalse(CheckInGiftCueMemory.consume(owner: owner, day: 24_999))
        XCTAssertTrue(CheckInGiftCueMemory.consume(owner: owner, day: 25_007))
        XCTAssertTrue(CheckInGiftCueMemory.consume(owner: otherInstall, day: 25_000))
    }
    @MainActor func testCheckInScreensCaptureDarkLightStreakRewardAndRestoredState() async throws {
        let model = model(); model.screen = .checkIn
        for daysAgo in stride(from: 6, through: 1, by: -1) {
            _ = model.progress.claimCheckIn(on: Date().addingTimeInterval(-Double(daysAgo) * 86_400), config: model.config)
        }
        model.now = Date(); model.save(force: true)
        let before = model.progress
        let host = UIHostingController(rootView: CheckInView(reduceMotionOverride: false)
            .environmentObject(model).environment(\.scenePhase, .active)
            .environment(\.appLanguage, .simplifiedChinese).background(CapyPalette.cream))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func capture(_ name: String) {
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false))
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await Task.sleep(nanoseconds: 100_000_000); capture("checkin-0226-01-dark-ready")
        XCTAssertEqual(model.progress, before)
        model.claim()
        try await Task.sleep(nanoseconds: 100_000_000); capture("checkin-0226-02-light-100ms")
        try await Task.sleep(nanoseconds: 230_000_000); capture("checkin-0226-03-streak-330ms")
        try await Task.sleep(nanoseconds: 390_000_000); capture("checkin-0226-04-reward-720ms")
        try await Task.sleep(nanoseconds: 550_000_000); capture("checkin-0226-05-settled")
        XCTAssertEqual(model.progress.bonusHints, before.bonusHints + model.config.dailyHintReward)
        XCTAssertEqual(model.progress.bonusDirect, before.bonusDirect + model.config.cycleDirectReward)
        XCTAssertEqual(model.progress.checkIn.streak, 7)
        let restored = AppModel(saveDirectory: model.saveDirectory, runsTimer: false, feedbackEnabled: false)
        XCTAssertEqual(restored.progress.checkIn, model.progress.checkIn)
        XCTAssertEqual(restored.progress.bonusDirect, model.progress.bonusDirect)
        restored.screen = .checkIn
        host.rootView = CheckInView(reduceMotionOverride: true).environmentObject(restored)
            .environment(\.scenePhase, .active).environment(\.appLanguage, .english).background(CapyPalette.cream)
        try await Task.sleep(nanoseconds: 80_000_000); capture("checkin-0226-06-restored-english-static")
    }
}
