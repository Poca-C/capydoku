import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class RewardMotionClock {
    var now = 0.0
    var jobs: [(Double, () -> Void)] = []
    func schedule(_ delay: Double, _ action: @escaping () -> Void) { jobs.append((now + delay, action)) }
    func advance(_ interval: Double) {
        let end = now + interval
        while let next = jobs.indices.filter({ jobs[$0].0 <= end }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
            let job = jobs.remove(at: next); now = job.0; job.1()
        }
        now = end
    }
}

final class GameRewardPresentationTests: XCTestCase {
    @MainActor func testApplauseIsSinglePerAcceptedFindAndOldExpiryCannotEraseTheNext() throws {
        let clock = RewardMotionClock(), id = UUID(), reward = GameRewardPresentation(schedule: clock.schedule)
        reward.bind(sessionID: id, score: 100)
        XCTAssertNil(reward.applauseID, "Restoring score is not a fresh celebration.")
        reward.found(index: 1, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        let first = try XCTUnwrap(reward.applauseID)
        reward.found(index: 1, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertEqual(reward.applauseID, first)
        clock.advance(0.40)
        reward.found(index: 2, sessionID: id, origin: .zero, destination: .zero, reduceMotion: true)
        let second = try XCTUnwrap(reward.applauseID)
        XCTAssertNotEqual(first, second, "Static acknowledgement still belongs to the new find.")
        clock.advance(0.36)
        XCTAssertEqual(reward.applauseID, second)
        reward.clear()
        XCTAssertNil(reward.applauseID)
        XCTAssertTrue(reward.flights.isEmpty, "A newer mistake ends existing visual celebration.")
        reward.setPresentationEnabled(false)
        reward.found(index: 4, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        reward.setPresentationEnabled(true)
        reward.found(index: 4, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertNil(reward.applauseID, "Hidden finds are consumed, not replayed.")
        reward.found(index: 5, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertNotNil(reward.applauseID)
        reward.bind(sessionID: UUID(), score: 0)
        clock.advance(2)
        XCTAssertNil(reward.applauseID)
    }

    @MainActor func testFoundAcknowledgementIsBoundedAndNeverReplayedByDuplicateOrOldSession() {
        let clock = RewardMotionClock(), id = UUID(), next = UUID()
        let feedback = GameRewardPresentation(schedule: clock.schedule)
        feedback.bind(sessionID: id, score: 0)
        for cell in 0..<8 {
            feedback.found(index: cell, sessionID: id, origin: .zero, destination: CGPoint(x: 100, y: 30), reduceMotion: false)
        }
        XCTAssertEqual(feedback.flights.count, 4)
        feedback.found(index: 7, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        XCTAssertEqual(feedback.flights.count, 4)
        clock.advance(0.44)
        XCTAssertTrue(feedback.progressPulse)
        XCTAssertNotNil(feedback.progressArrivalID)
        feedback.bind(sessionID: next, score: 100)
        feedback.found(index: 0, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        clock.advance(1)
        XCTAssertTrue(feedback.flights.isEmpty)
        XCTAssertFalse(feedback.progressPulse)
        XCTAssertNil(feedback.progressArrivalID)
    }

    @MainActor func testHiddenFeedbackClearsFlightsAndStaleScoreExpiryCannotEraseNewReward() {
        let clock = RewardMotionClock(), id = UUID()
        let feedback = GameRewardPresentation(schedule: clock.schedule)
        feedback.bind(sessionID: id, score: 80)
        XCTAssertNil(feedback.scoreDelta, "Restoring a saved score must not replay a reward.")
        XCTAssertNil(feedback.scorePulseID)
        feedback.scoreChanged(100, sessionID: id, visible: true)
        XCTAssertEqual(feedback.scoreDelta, 20)
        let firstPulse = feedback.scorePulseID
        XCTAssertNotNil(firstPulse)
        clock.advance(0.5)
        feedback.scoreChanged(120, sessionID: id, visible: true)
        XCTAssertNotEqual(feedback.scorePulseID, firstPulse, "Equal consecutive awards still need separate visual pulses.")
        let secondPulse = feedback.scorePulseID
        feedback.scoreChanged(120, sessionID: id, visible: true)
        XCTAssertEqual(feedback.scorePulseID, secondPulse, "An unchanged HUD refresh is not another award.")
        clock.advance(0.3)
        XCTAssertEqual(feedback.scoreDelta, 20)
        XCTAssertEqual(feedback.scorePulseID, secondPulse, "Expiry of the preceding pulse must not cancel the newer one.")
        feedback.found(index: 1, sessionID: id, origin: .zero, destination: .zero, reduceMotion: false)
        feedback.clear()
        feedback.scoreChanged(180, sessionID: id, visible: false)
        clock.advance(1)
        XCTAssertTrue(feedback.flights.isEmpty)
        XCTAssertFalse(feedback.progressPulse)
        XCTAssertNil(feedback.scoreDelta)
        XCTAssertNil(feedback.scorePulseID)
        feedback.scoreChanged(200, sessionID: id, visible: true)
        XCTAssertEqual(feedback.scoreDelta, 20, "Hidden changes are the new baseline, not a deferred animation.")
    }

    @MainActor func testReducedMotionRetainsProgressAcknowledgementWithoutFlight() {
        let clock = RewardMotionClock(), id = UUID()
        let feedback = GameRewardPresentation(schedule: clock.schedule)
        feedback.bind(sessionID: id, score: 0)
        feedback.found(index: 1, sessionID: id, origin: .zero, destination: .zero, reduceMotion: true)
        XCTAssertTrue(feedback.flights.isEmpty)
        XCTAssertTrue(feedback.progressPulse)
        let firstArrival = feedback.progressArrivalID
        XCTAssertNotNil(firstArrival)
        clock.advance(0.04)
        feedback.found(index: 2, sessionID: id, origin: .zero, destination: .zero, reduceMotion: true)
        let nextArrival = feedback.progressArrivalID
        XCTAssertNotEqual(nextArrival, firstArrival, "Arrivals inside the old Boolean's hold window still have distinct identities.")
        feedback.found(index: 2, sessionID: id, origin: .zero, destination: .zero, reduceMotion: true)
        XCTAssertEqual(feedback.progressArrivalID, nextArrival, "A duplicate find is not another HUD arrival.")
        clock.advance(1)
        XCTAssertFalse(feedback.progressPulse)
    }

    @MainActor func testFinalMoveGetsBriefFeedbackButRestoredOrBackgroundResultsAreImmediate() {
        let clock = RewardMotionClock(), id = UUID()
        let entrance = ResultEntrancePresentation(schedule: clock.schedule)
        entrance.update(sessionID: id, status: .playing, animate: true)
        XCTAssertFalse(entrance.shows(sessionID: id, status: .won, animate: true))
        entrance.update(sessionID: id, status: .won, animate: true)
        clock.advance(0.81)
        XCTAssertFalse(entrance.shows(sessionID: id, status: .won, animate: true))
        clock.advance(0.01)
        XCTAssertTrue(entrance.shows(sessionID: id, status: .won, animate: true))
        let restored = ResultEntrancePresentation(schedule: clock.schedule)
        XCTAssertTrue(restored.shows(sessionID: id, status: .won, animate: true))
        restored.update(sessionID: id, status: .won, animate: true)
        XCTAssertTrue(restored.ready)
        entrance.update(sessionID: UUID(), status: .playing, animate: true)
        let lossID = UUID()
        entrance.update(sessionID: lossID, status: .playing, animate: true)
        entrance.update(sessionID: lossID, status: .lost, animate: true)
        XCTAssertFalse(entrance.ready)
        entrance.update(sessionID: lossID, status: .lost, animate: false)
        XCTAssertTrue(entrance.ready)
    }

    @MainActor func testNewSessionInvalidatesPendingResultAndReducedMotionNeverWaits() {
        let clock = RewardMotionClock(), id = UUID(), next = UUID()
        let entrance = ResultEntrancePresentation(schedule: clock.schedule)
        entrance.update(sessionID: id, status: .playing, animate: true)
        entrance.update(sessionID: id, status: .lost, animate: true)
        entrance.update(sessionID: next, status: .playing, animate: true)
        clock.advance(2)
        XCTAssertFalse(entrance.shows(sessionID: next, status: .playing, animate: true))
        entrance.update(sessionID: next, status: .won, animate: false)
        XCTAssertTrue(entrance.shows(sessionID: next, status: .won, animate: false))
    }

    @MainActor func testRepeatedComboTierStillGetsANewVisibleAcknowledgement() {
        let clock = RewardMotionClock(), feedback = GameFeedbackPresentation(schedule: clock.schedule)
        feedback.combo(.init(text: "Great", delay: 0))
        let first = feedback.comboRevision
        feedback.combo(.init(text: "Great", delay: 0))
        XCTAssertNotEqual(first, feedback.comboRevision)
        feedback.setPresentationEnabled(false)
        clock.advance(2)
        XCTAssertNil(feedback.comboText)
    }
}

final class GameFeelVisualTests: XCTestCase {
    @MainActor private func applause(in view: UIView) -> ApplauseFeedbackUIView? {
        (view as? ApplauseFeedbackUIView) ?? view.subviews.lazy.compactMap { self.applause(in: $0) }.first
    }
    @MainActor private func grid(in view: UIView) -> PuzzleGridUIView? {
        (view as? PuzzleGridUIView) ?? view.subviews.lazy.compactMap { self.grid(in: $0) }.first
    }

    /// Diagnostic evidence, not a claim that SwiftUI necessarily retains two
    /// visible labels. Each sample uses a fresh real board so screenshot work
    /// cannot move the next requested sample past its intended time window.
    @MainActor func testActualRootComboReplacementNaturalFrames() async throws {
        var samples: [[String: Any]] = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (width, language) in [(CGFloat(320), AppLanguage.simplifiedChinese), (CGFloat(402), AppLanguage.english)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("combo-replacement-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.settings.language = language
            model.progress.tutorialCompleted = true; model.start(level: 6)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: width == 320 ? 568 : 874)
            var frames: [String: CGRect] = [:]
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: false).environmentObject(model)
                .environment(\.scenePhase, .active)
                .environment(\.capyLayoutObserver, { frames[$0] = $1 }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            let solution = try XCTUnwrap(model.session).puzzle.solution
            // Derive the two cases from the configuration actually in this
            // session; this diagnostic must not change scoring or thresholds.
            let pairs: [(count: Int, before: String, after: String)] = (2..<solution.count).compactMap { count in
                guard let before = model.comboFeedbackPresentation(for: count - 1)?.text,
                      let after = model.comboFeedbackPresentation(for: count)?.text else { return nil }
                return (count, before, after)
            }
            let crossing = try XCTUnwrap(pairs.last(where: { $0.before != $0.after }))
            let repeating = try XCTUnwrap(pairs.first(where: { $0.before == $0.after }))
            for (kind, replacement) in [("cross-tier", crossing), ("same-tier", repeating)] {
                for requestedMilliseconds in [30, 70, 120] {
                    model.start(level: 6)
                    try await Task.sleep(nanoseconds: 200_000_000)
                    let boardBefore = try XCTUnwrap(frames["puzzle_board"])
                    let activeSolution = try XCTUnwrap(model.session).puzzle.solution
                    // Allow 400 ms before each next move. The before image
                    // verifies readability; this wait does not prove settling.
                    for index in activeSolution.prefix(replacement.count - 1) {
                        model.submit(index)
                        try await Task.sleep(nanoseconds: 400_000_000)
                    }
                    let before = try XCTUnwrap(model.session)
                    let replacementPresentation = try XCTUnwrap(model.comboFeedbackPresentation(for: replacement.count))
                    XCTAssertEqual(before.status, .playing)
                    XCTAssertEqual(before.combo, replacement.count - 1)
                    XCTAssertEqual(model.comboFeedbackPresentation(for: before.combo)?.text, replacement.before)
                    let prefix = "combo-replacement-\(Int(width))pt-\(kind)-\(requestedMilliseconds)ms"
                    func capture(_ name: String) {
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                        }
                        let attachment = XCTAttachment(image: image)
                        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    }
                    capture(prefix + "-before")
                    let acceptedAt = ProcessInfo.processInfo.systemUptime
                    model.submit(activeSolution[replacement.count - 1])
                    let committedAt = ProcessInfo.processInfo.systemUptime
                    let deadline = acceptedAt + Double(requestedMilliseconds) / 1_000
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    let captureBeganAt = ProcessInfo.processInfo.systemUptime
                    capture(prefix + "-replacement")
                    let captureEndedAt = ProcessInfo.processInfo.systemUptime
                    let after = try XCTUnwrap(model.session)
                    XCTAssertEqual(after.status, .playing, "The sample must precede the result overlay.")
                    XCTAssertEqual(after.combo, replacement.count)
                    XCTAssertEqual(after.found.count, before.found.count + 1)
                    XCTAssertEqual(after.lives, before.lives)
                    XCTAssertGreaterThan(after.score, before.score)
                    XCTAssertEqual(model.comboFeedbackPresentation(for: after.combo)?.text, replacement.after)
                    XCTAssertEqual(frames["puzzle_board"], boardBefore)
                    let band = try XCTUnwrap(frames["combo_feedback"])
                    let board = try XCTUnwrap(frames["puzzle_board"])
                    let rules = try XCTUnwrap(frames["rule_strip"])
                    // Window captures and their measured crop describe pixels.
                    // AX node counts would not prove which outgoing glyphs are
                    // actually visible during a SwiftUI insertion/removal.
                    samples.append([
                        "capture": prefix + "-replacement", "beforeCapture": prefix + "-before",
                        "widthPoints": Double(width), "language": language == .english ? "en" : "zh-Hans",
                        "kind": kind, "oldText": language.text(replacement.before), "newText": language.text(replacement.after),
                        "comboBefore": before.combo, "comboAfter": after.combo,
                        "configuredComboDelaySeconds": replacementPresentation.delay,
                        "requestedMillisecondsAfterSubmission": requestedMilliseconds,
                        "commitReturnedMilliseconds": (committedAt - acceptedAt) * 1_000,
                        "captureBeganMilliseconds": (captureBeganAt - acceptedAt) * 1_000,
                        "captureEndedMilliseconds": (captureEndedAt - acceptedAt) * 1_000,
                        "lastReportedComboFramePoints": [Double(band.minX), Double(band.minY), Double(band.width), Double(band.height)],
                        "reviewBandPoints": [0, Double(rules.maxY - 2), Double(width), Double(board.minY - rules.maxY + 4)],
                        "foundCount": after.found.count, "score": after.score, "lives": after.lives,
                        "animationsFrozen": false
                    ])
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "purpose": "Actual Root natural Combo replacement frames; visual overlap is not asserted by this diagnostic.",
            "timing": "Requested times are targets measured from model.submit, not the display refresh. afterScreenUpdates:false can capture the previous committed frame. Capture start/end enclose snapshot work, not presentation timestamps. No Core Animation timeOffset or speed is modified.",
            "layout": "The last reported Combo frame can belong to an earlier revision and does not prove the new text is visible. Judge the whole feedback band pixels together with the before image.",
            "samples": samples
        ], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "combo-replacement-natural-frame-timing"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testActualRootApplauseFitsBesideComboAndStopsForLaterMistake() async throws {
        for (width, language) in [(CGFloat(320), AppLanguage.simplifiedChinese), (CGFloat(402), AppLanguage.english)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("applause-root-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.settings.language = language
            model.progress.tutorialCompleted = true; model.start(level: 6)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: width == 320 ? 568 : 874)
            var frames: [String: CGRect] = [:]
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: false).environmentObject(model)
                .environment(\.scenePhase, .active)
                .environment(\.capyLayoutObserver, { frames[$0] = $1 }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            func capture(_ stage: String) {
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
                }
                let a = XCTAttachment(image: image); a.name = "applause-root-\(Int(width))pt-\(stage)"; a.lifetime = .keepAlways; add(a)
            }
            try await Task.sleep(nanoseconds: 180_000_000)
            let solution = try XCTUnwrap(model.session).puzzle.solution
            let boardBefore = try XCTUnwrap(frames["puzzle_board"])
            model.submit(solution[0])
            try await Task.sleep(nanoseconds: 120_000_000)
            let firstView = try XCTUnwrap(applause(in: host.view))
            let firstID = try XCTUnwrap(firstView.activeEventID)
            capture("first-correct")
            model.submit(solution[1])
            try await Task.sleep(nanoseconds: 90_000_000)
            XCTAssertNotEqual(firstView.activeEventID, firstID)
            model.submit(solution[2])
            try await Task.sleep(nanoseconds: 180_000_000)
            XCTAssertNotNil(firstView.activeEventID)
            let clap = try XCTUnwrap(frames["applause_feedback"]), combo = try XCTUnwrap(frames["combo_feedback"])
            let rules = try XCTUnwrap(frames["rule_strip"]), board = try XCTUnwrap(frames["puzzle_board"])
            XCTAssertLessThanOrEqual(clap.maxY, board.minY + 0.5)
            XCTAssertGreaterThanOrEqual(clap.minY, rules.maxY - 0.5)
            XCTAssertFalse(clap.intersects(combo), "Encouragement must fit beside translated Combo text.")
            XCTAssertTrue(host.view.bounds.contains(clap))
            XCTAssertEqual(board, boardBefore, "A fresh decoration must not shift the playable board.")
            XCTAssertFalse(firstView.isUserInteractionEnabled); XCTAssertTrue(firstView.accessibilityElementsHidden)
            capture("continuous-combo")
            let accepted = try XCTUnwrap(model.session)
            let wrong = try XCTUnwrap((0..<(accepted.puzzle.size * accepted.puzzle.size)).first { !solution.contains($0) })
            model.submit(wrong)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNil(firstView.activeEventID)
            XCTAssertEqual(model.session?.found, accepted.found); XCTAssertEqual(model.session?.score, accepted.score)
            XCTAssertEqual(model.session?.lives, 2)
            let boardView = try XCTUnwrap(grid(in: host.view))
            XCTAssertFalse(boardView.subviews.flatMap(\.subviews).contains {
                $0 is BoardPlacementBurstView || ($0 as? BoardCellFeedbackView)?.kind == .found
            })
            capture("mistake-no-applause")
            let precedingConflicts = boardView.subviews.flatMap(\.subviews).compactMap { $0 as? BoardConflictFeedbackView }
            XCTAssertFalse(precedingConflicts.isEmpty, "The wrong action must actually render its explanation before the next correct move.")
            model.submit(solution[3])
            try await Task.sleep(nanoseconds: 120_000_000)
            let recoveredEffects = boardView.subviews.flatMap(\.subviews)
            XCTAssertEqual(model.session?.found.count, 4)
            XCTAssertEqual(model.session?.lives, 2)
            XCTAssertTrue(model.session?.errors.contains(wrong) == true, "Clearing old decoration must retain the recorded wrong X.")
            XCTAssertGreaterThan(model.session?.score ?? 0, accepted.score)
            XCTAssertTrue(precedingConflicts.allSatisfy { $0.superview == nil })
            XCTAssertFalse(recoveredEffects.contains {
                $0 is BoardMistakeFeedbackView || $0 is BoardConflictFeedbackView || ($0 as? CapyFaceExpressionView)?.expression == .startled
            }, "A separately rendered correct action must replace the previous error explanation.")
            XCTAssertTrue(recoveredEffects.contains { ($0 as? BoardPlacementBurstView)?.cellIndex == solution[3] })
            XCTAssertNotNil(firstView.activeEventID, "The newer correct action retains its encouragement.")
            XCTAssertEqual(frames["puzzle_board"], boardBefore)
            capture("sequential-wrong-correct-latest-success")
            model.start(level: 6)
            try await Task.sleep(nanoseconds: 120_000_000)
            // Deliberately coalesce a real correct and incorrect submission.
            model.submit(solution[0]); model.submit(wrong)
            try await Task.sleep(nanoseconds: 120_000_000)
            let nextView = try XCTUnwrap(applause(in: host.view))
            XCTAssertFalse(firstView === nextView, "Consumed event storage is scoped to one board.")
            XCTAssertNil(nextView.activeEventID)
            XCTAssertEqual(model.session?.found.count, 1); XCTAssertEqual(model.session?.lives, 2)
            let coalescedBoard = try XCTUnwrap(grid(in: host.view))
            XCTAssertFalse(coalescedBoard.subviews.flatMap(\.subviews).contains {
                $0 is BoardPlacementBurstView || ($0 as? BoardCellFeedbackView)?.kind == .found
            }, "The actual Root must pass the latest wrong result to local board feedback as well as the HUD.")
            capture("coalesced-correct-wrong-no-applause")

            model.start(level: 6)
            try await Task.sleep(nanoseconds: 120_000_000)
            model.submit(wrong); model.submit(solution[0])
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertNotNil(applause(in: host.view)?.activeEventID)
            XCTAssertEqual(model.session?.found, [solution[0]]); XCTAssertEqual(model.session?.lives, 2)
            let latestBoard = try XCTUnwrap(grid(in: host.view))
            let latestEffects = latestBoard.subviews.flatMap(\.subviews)
            XCTAssertTrue(latestEffects.contains { $0 is BoardPlacementBurstView })
            XCTAssertFalse(latestEffects.contains { $0 is BoardMistakeFeedbackView || $0 is BoardConflictFeedbackView },
                "The actual Root must preserve a newer correct action rather than let earlier damage win the shared frame.")
            capture("coalesced-wrong-correct-latest-success")
        }
    }

    @MainActor func testActualMovesAndResultPresentationCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("game-feel-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true
        model.start(level: 6)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        var frames: [String: CGRect] = [:]
        let host = UIHostingController(rootView: RootView().environmentObject(model).environment(\.scenePhase, .active)
            .environment(\.capyLayoutObserver, { frames[$0] = $1 }))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: directory)
        }
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let solution = try XCTUnwrap(model.session).puzzle.solution
        for index in solution.prefix(3) {
            model.submit(index)
            try await Task.sleep(nanoseconds: 140_000_000)
            capture("correct-progress-flight-\(index)")
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertEqual(model.session?.found.count, 3)
        let combo = try XCTUnwrap(frames["combo_feedback"])
        let board = try XCTUnwrap(frames["puzzle_board"])
        let level = try XCTUnwrap(frames["level_title"])
        XCTAssertLessThanOrEqual(combo.maxY, board.minY + 1, "Combo must not cover the board's first row.")
        XCTAssertGreaterThan(combo.minY, level.maxY, "Combo must not obscure the level number.")
        capture("combo-progress-after-three")
        for index in solution.dropFirst(3) { model.submit(index) }
        XCTAssertEqual(model.session?.status, .won)
        let committedResult = model.session
        model.submit(solution[0])
        model.toggle((0..<36).first(where: { !solution.contains($0) }) ?? 0)
        XCTAssertEqual(model.session, committedResult, "Visual result delay must not postpone input locking.")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(frames["result_primary_action"], "Result actions must precede the decoration window.")
        XCTAssertNotNil(try XCTUnwrap(applause(in: host.view)).activeEventID, "A genuine final find still gets encouragement.")
        capture("final-move-before-result")
        // Requested sampling delays identify broad phases, not measured frame
        // timestamps. Keep the existing win-celebration capture for comparison.
        try await Task.sleep(nanoseconds: 500_000_000)
        capture("final-combo-board-phase-before-result-decoration")
        XCTAssertEqual(frames["puzzle_board"], board, "Preserving the Combo band must not shift the completed board.")
        try await Task.sleep(nanoseconds: 250_000_000)
        capture("win-celebration")
        try await Task.sleep(nanoseconds: 250_000_000)
        capture("result-title-entered-without-underlying-combo")
        XCTAssertNil(try XCTUnwrap(applause(in: host.view)).activeEventID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        capture("result-settled-without-underlying-combo")
        XCTAssertEqual(frames["puzzle_board"], board)
        XCTAssertNotNil(frames["result_primary_action"])
        XCTAssertEqual(model.session, committedResult, "Hiding Combo decoration changes no result or reward state.")
        XCTAssertEqual(model.session?.found.count, solution.count)
    }
}
