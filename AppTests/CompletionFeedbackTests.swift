import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class CompletionFeedbackClock {
    private var time = 0.0
    private var work: [(Double, () -> Void)] = []
    func schedule(_ delay: Double, _ action: @escaping () -> Void) { work.append((time + delay, action)) }
    func advance(_ seconds: Double) {
        let end = time + seconds
        while let index = work.indices.filter({ work[$0].0 <= end }).min(by: { work[$0].0 < work[$1].0 }) {
            let item = work.remove(at: index); time = item.0; item.1()
        }
        time = end
    }
}

final class CompletionFeedbackTests: XCTestCase {
    @MainActor func testResultEventOnlyExistsForFreshVisibleResultAndCannotReplayAfterCoverOrRestore() {
        let clock = CompletionFeedbackClock(), result = ResultEntrancePresentation(schedule: clock.schedule), id = UUID()
        result.update(sessionID: id, status: .playing, animate: true)
        result.update(sessionID: id, status: .won, animate: true)
        XCTAssertNil(result.animationID)
        clock.advance(0.82)
        let event = result.animationID
        XCTAssertNotNil(event)
        result.update(sessionID: id, status: .won, animate: true)
        XCTAssertEqual(result.animationID, event, "Ordinary redraw cannot restart the performance.")
        result.update(sessionID: id, status: .won, animate: false)
        result.update(sessionID: id, status: .won, animate: true)
        clock.advance(2)
        XCTAssertNil(result.animationID)
        let restored = ResultEntrancePresentation(schedule: clock.schedule)
        restored.update(sessionID: id, status: .won, animate: true)
        XCTAssertTrue(restored.ready); XCTAssertNil(restored.animationID)
    }

    @MainActor func testImmediateNextAndInterruptionCancelPendingCharacterPerformance() {
        let clock = CompletionFeedbackClock(), result = ResultEntrancePresentation(schedule: clock.schedule), id = UUID()
        result.update(sessionID: id, status: .playing, animate: true)
        result.update(sessionID: id, status: .won, animate: true)
        result.update(sessionID: UUID(), status: .playing, animate: true)
        clock.advance(1)
        XCTAssertNil(result.animationID)
        let next = UUID()
        result.update(sessionID: next, status: .playing, animate: true)
        result.update(sessionID: next, status: .lost, animate: true)
        result.update(sessionID: next, status: .lost, animate: false)
        clock.advance(1)
        XCTAssertTrue(result.ready); XCTAssertNil(result.animationID)
    }

    @MainActor func testToolAcknowledgementIsSingleFiniteAndSessionBound() {
        let clock = CompletionFeedbackClock(), id = UUID(), reward = GameRewardPresentation(schedule: clock.schedule)
        let first = DirectRevealFeedback(sessionID: id, cell: 0)
        reward.bind(sessionID: id, score: 0)
        reward.directReveal(first, origin: .zero, destination: CGPoint(x: 50, y: 80), reduceMotion: false)
        XCTAssertEqual(reward.toolReveal?.id, first.id)
        clock.advance(0.3)
        let second = DirectRevealFeedback(sessionID: id, cell: 1)
        reward.directReveal(second, origin: .zero, destination: CGPoint(x: 80, y: 80), reduceMotion: false)
        clock.advance(0.23)
        XCTAssertEqual(reward.toolReveal?.id, second.id, "Old expiry must not erase the newer committed tool use.")
        clock.advance(0.3)
        XCTAssertNil(reward.toolReveal)
        reward.directReveal(first, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertNil(reward.toolReveal)
        reward.bind(sessionID: UUID(), score: 100)
        reward.directReveal(second, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertNil(reward.toolReveal)
    }

    @MainActor func testHiddenAndInvalidToolEventsNeverReplayWhileReducedMotionKeepsStaticConfirmation() {
        let clock = CompletionFeedbackClock(), id = UUID(), reward = GameRewardPresentation(schedule: clock.schedule)
        reward.bind(sessionID: id, score: 0)
        let hidden = DirectRevealFeedback(sessionID: id, cell: 0)
        reward.setPresentationEnabled(false)
        reward.directReveal(hidden, origin: .zero, destination: .zero, reduceMotion: false)
        reward.setPresentationEnabled(true)
        reward.directReveal(hidden, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertNil(reward.toolReveal)
        reward.directReveal(.init(sessionID: id, cell: 1), origin: CGPoint(x: CGFloat.nan, y: 0), destination: .zero, reduceMotion: false)
        XCTAssertNil(reward.toolReveal)
        reward.directReveal(.init(sessionID: id, cell: 2), origin: .zero, destination: .zero, reduceMotion: true)
        XCTAssertEqual(reward.toolReveal?.reduceMotion, true)
        clock.advance(0.52); XCTAssertNil(reward.toolReveal)
    }

    @MainActor func testThreeComboTiersFitDedicatedBandInChineseEnglishAndReducedMotion() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 220)
        var frames: [String: CGRect] = [:]
        let view = VStack(spacing: 3) {
            ForEach(Array(ComboVisualTier.allCases.enumerated()), id: \.offset) { index, tier in
                ComboCelebrationView(text: ["不错！", "真棒！", "太出色了！"][index], tier: tier, compact: true, reduceMotion: false)
                    .capyLayoutProbe("zh-\(index)")
                ComboCelebrationView(text: ["Nice", "Great", "Excellent"][index], tier: tier, compact: true, reduceMotion: true)
                    .capyLayoutProbe("en-\(index)")
            }
        }.frame(width: 320, height: 220).background(CapyPalette.cream)
            .environment(\.capyLayoutObserver, { frames[$0] = $1 })
        let host = UIHostingController(rootView: view); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(frames.count, 6)
        for frame in frames.values { XCTAssertLessThanOrEqual(frame.width, 300); XCTAssertLessThanOrEqual(frame.height, 24) }
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false) }
        let attachment = XCTAttachment(image: image); attachment.name = "combo-three-tiers-chinese-english"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testCurrentPackRootDirectAndCompleteBoardCaptureWithImmediateNextAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("completion-feedback-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true; model.start(level: 6)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        var frames: [String: CGRect] = [:]
        let host = UIHostingController(rootView: RootView(reduceMotionOverride: false).environmentObject(model)
            .environment(\.scenePhase, .active).environment(\.capyLayoutObserver, { frames[$0] = $1 }))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory) }
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        capture("current-level-6-staggered-entry-120ms")
        try await Task.sleep(nanoseconds: 500_000_000)
        model.direct()
        let accepted = try XCTUnwrap(model.session)
        XCTAssertEqual(accepted.found.count, 1); XCTAssertNotNil(model.directRevealFeedback)
        try await Task.sleep(nanoseconds: 120_000_000)
        capture("current-level-6-direct-tool-120ms")
        XCTAssertEqual(model.session, accepted)
        try await Task.sleep(nanoseconds: 600_000_000)
        for cell in accepted.puzzle.solution where !accepted.found.contains(cell) { model.submit(cell) }
        let won = try XCTUnwrap(model.session); XCTAssertEqual(won.status, .won)
        try await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertNotNil(frames["result_primary_action"], "Next is available during the board celebration.")
        capture("current-level-6-full-board-victory-220ms")
        try await Task.sleep(nanoseconds: 850_000_000)
        capture("current-level-6-result-character-1070ms")
        XCTAssertEqual(model.session, won, "Decorations never issue another game/reward transaction.")
    }
}
