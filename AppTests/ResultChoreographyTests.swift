import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class ChoreographyClock {
    var now = 0.0
    var jobs: [(Double, () -> Void)] = []
    func schedule(_ delay: Double, _ action: @escaping () -> Void) { jobs.append((now + delay, action)) }
    func advance(_ seconds: Double) {
        let until = now + seconds
        while let next = jobs.indices.filter({ jobs[$0].0 <= until }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
            let job = jobs.remove(at: next); now = job.0; job.1()
        }
        now = until
    }
}

private struct ResultChromePixels {
    let width: Int
    let height: Int
    let scale: CGFloat
    let bytes: [UInt8]

    init(_ image: UIImage) throws {
        let source = try XCTUnwrap(image.cgImage)
        width = source.width; height = source.height; scale = image.scale
        var pixels = [UInt8](repeating: 0, count: source.width * source.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            return true
        }
        XCTAssertTrue(rendered); bytes = pixels
    }

    func nonBackgroundPixels(in frame: CGRect) -> Int {
        // The hosting view has a flat cream background. Its 4pt corner lies
        // outside GameView's 14pt horizontal padding and all of its controls.
        let backgroundOffset = (min(height - 1, Int(4 * scale)) * width + min(width - 1, Int(4 * scale))) * 4
        let sample = frame.insetBy(dx: 2, dy: 2)
        let x0 = max(0, Int(ceil(sample.minX * scale)))
        let x1 = min(width, Int(floor(sample.maxX * scale)))
        let y0 = max(0, Int(ceil(sample.minY * scale)))
        let y1 = min(height, Int(floor(sample.maxY * scale)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var count = 0
        for y in y0..<y1 { for x in x0..<x1 {
            let offset = (y * width + x) * 4
            if (0..<3).contains(where: { abs(Int(bytes[offset + $0]) - Int(bytes[backgroundOffset + $0])) > 8 }) {
                count += 1
            }
        } }
        return count
    }
}

final class ResultChoreographyTests: XCTestCase {
    @MainActor func testActualGameChromeHidesAtTerminalLayoutAndReturnsAfterNextRestartOrRevive() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
        var reference = try JSONDecoder().decode(ReferenceLevelGameplay.self, from: Data(contentsOf: fixture))
        reference.adsEnabled = false; reference.interstitial.enabled = false
        reference.failure.restartCreatesNewBoard = false
        reference.revive.freeCount = 1; reference.revive.resetPolicy = .oncePerLevel
        var observations = [[String: Any]]()

        for reduceMotion in [false, true] {
            for action in ["next", "restart", "revive"] {
                let name = "chrome-\(action)-\(reduceMotion ? "reduced" : "normal")"
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name + UUID().uuidString)
                let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
                model.progress.tutorialCompleted = true; model.config = DemoConfig(referenceGameplay: reference)
                model.start(level: 6)
                let initial = try XCTUnwrap(model.session)
                let lastCell: Int
                if action == "next" {
                    let remaining = initial.puzzle.solution.filter { !initial.found.contains($0) }
                    lastCell = try XCTUnwrap(remaining.last)
                    for cell in remaining.dropLast() { model.submit(cell) }
                } else {
                    let wrong = initial.puzzle.regions.indices.filter { !initial.puzzle.solution.contains($0) }
                    let sequence = Array(wrong.prefix(initial.lives))
                    lastCell = try XCTUnwrap(sequence.last)
                    for cell in sequence.dropLast() { model.submit(cell) }
                }
                XCTAssertEqual(model.session?.status, .playing)

                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first(where: \.isKeyWindow)
                let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
                window.overrideUserInterfaceStyle = .light
                var frames = [String: CGRect]()
                let host = UIHostingController(rootView: GameView().environmentObject(model)
                    .environment(\.scenePhase, .active).environment(\.capyMotionOverride, reduceMotion)
                    .environment(\.appLanguage, model.progress.settings.language)
                    .environment(\.capyLayoutObserver, { frames[$0] = $1 })
                    .frame(width: 320, height: 568).background(CapyPalette.cream).ignoresSafeArea())
                let controller = UIViewController(); controller.view.backgroundColor = .black
                window.rootViewController = controller; window.makeKeyAndVisible()
                controller.addChild(host); controller.view.addSubview(host.view)
                host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
                host.didMove(toParent: controller)
                defer {
                    window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                    model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
                }
                func nativeBoard(in view: UIView) -> PuzzleGridUIView? {
                    if let board = view as? PuzzleGridUIView { return board }
                    for child in view.subviews { if let board = nativeBoard(in: child) { return board } }
                    return nil
                }
                func snapshot(_ phase: String) throws -> ResultChromePixels {
                    host.view.layoutIfNeeded()
                    let format = UIGraphicsImageRendererFormat(); format.scale = window.screen.scale
                    format.preferredRange = .standard; format.opaque = true
                    var drawn = false
                    let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                        drawn = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                    }
                    XCTAssertTrue(drawn)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = name + "-" + phase; attachment.lifetime = .keepAlways; add(attachment)
                    return try ResultChromePixels(image)
                }
                try await Task.sleep(nanoseconds: 250_000_000)
                let board = try XCTUnwrap(nativeBoard(in: host.view))
                let beforeFrames = try ["home", "game_footer", "puzzle_board"].map { try XCTUnwrap(frames[$0], $0) }
                let before = try snapshot("playing")
                let homeBefore = before.nonBackgroundPixels(in: beforeFrames[0])
                let footerBefore = before.nonBackgroundPixels(in: beforeFrames[1])
                XCTAssertGreaterThan(homeBefore, 50, "The real Home artwork must be present before finishing.")
                XCTAssertGreaterThan(footerBefore, 100, "The real tool artwork must be present before finishing.")

                let submittedAt = CACurrentMediaTime()
                model.submit(lastCell)
                let terminal = try XCTUnwrap(model.session)
                XCTAssertEqual(terminal.status, action == "next" ? .won : .lost)
                // Wait only for the native board to receive this terminal
                // layout, not for the 0.60/0.82s result-decoration delay.
                for _ in 0..<30 {
                    if board.accessibilityElements?.isEmpty == true { break }
                    try await Task.sleep(nanoseconds: 4_000_000)
                }
                XCTAssertTrue(board.accessibilityElements?.isEmpty == true)
                let hidden = try snapshot("terminal-first-layout")
                let readbackElapsed = CACurrentMediaTime() - submittedAt
                let homeHidden = hidden.nonBackgroundPixels(in: beforeFrames[0])
                let footerHidden = hidden.nonBackgroundPixels(in: beforeFrames[1])
                XCTAssertLessThanOrEqual(homeHidden, 10, "The disabled Home must stop drawing when result owns navigation.")
                XCTAssertLessThanOrEqual(footerHidden, 10, "Old tool contents must stop drawing under the result action.")
                XCTAssertEqual(model.session, terminal)
                for (index, identifier) in ["home", "game_footer", "puzzle_board"].enumerated() {
                    XCTAssertEqual(frames[identifier], beforeFrames[index], "Hiding \(identifier) preserves the board and its reserved layout.")
                }

                if action == "next" { model.next() }
                else if action == "restart" { model.restart() }
                else {
                    XCTAssertTrue(model.reviveAvailable); XCTAssertFalse(model.reviveNeedsVideo)
                    model.revive()
                }
                XCTAssertEqual(model.session?.status, .playing)
                XCTAssertEqual(model.session?.puzzle.id, action == "next" ? 7 : 6)
                XCTAssertNil(model.sheet, "This fixture exercises free revival, not an ad delay.")
                for _ in 0..<30 {
                    if board.accessibilityElements?.isEmpty == false { break }
                    try await Task.sleep(nanoseconds: 4_000_000)
                }
                XCTAssertTrue(board.accessibilityElements?.isEmpty == false)
                let resumed = try snapshot("playing-restored")
                XCTAssertGreaterThan(resumed.nonBackgroundPixels(in: beforeFrames[0]), 50)
                XCTAssertGreaterThan(resumed.nonBackgroundPixels(in: beforeFrames[1]), 100)
                for (index, identifier) in ["home", "game_footer", "puzzle_board"].enumerated() {
                    XCTAssertEqual(frames[identifier], beforeFrames[index], "Restoring \(identifier) cannot shift the new or revived board.")
                }
                observations.append(["action": action, "reduceMotion": reduceMotion,
                    "nativeScale": hidden.scale, "terminalSnapshotReadbackSeconds": readbackElapsed,
                    "homeBeforePixels": homeBefore, "homeTerminalPixels": homeHidden,
                    "footerBeforePixels": footerBefore, "footerTerminalPixels": footerHidden,
                    "homeFrame": NSCoder.string(for: beforeFrames[0]),
                    "footerFrame": NSCoder.string(for: beforeFrames[1]),
                    "boardFrame": NSCoder.string(for: beforeFrames[2])])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["observations": observations,
            "boundary": "Real GameView raster at native scale after its terminal native-board layout; screenshot readback can take time and is not an exact first-frame or touch-latency measurement. Full Root result hit testing and choreography are covered separately."],
            options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "terminal-game-chrome-pixel-observations"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testWinAndLossRevealCharacterThenTitleThenDetailWithoutChangingImmediateActionContract() {
        for outcome in [GameStatus.won, .lost] {
            let clock = ChoreographyClock(), id = UUID(), result = ResultEntrancePresentation(schedule: clock.schedule)
            result.update(sessionID: id, status: .playing, animate: true)
            result.update(sessionID: id, status: outcome, animate: true)
            XCTAssertEqual(result.stage, .board); XCTAssertFalse(result.ready)
            clock.advance(outcome == .won ? 0.82 : 0.60)
            XCTAssertTrue(result.ready); XCTAssertEqual(result.stage, .character)
            let event = result.animationID; XCTAssertNotNil(event)
            clock.advance(0.161); XCTAssertEqual(result.stage, .title)
            clock.advance(0.16); XCTAssertEqual(result.stage, .detail)
            clock.advance(0.19); XCTAssertEqual(result.stage, .settled)
            XCTAssertEqual(result.animationID, event)
        }
    }

    @MainActor func testCoverAndNextLevelCancelEveryRemainingStageAndRestorationIsFullyReadable() {
        for leave in [false, true] {
            let clock = ChoreographyClock(), id = UUID(), result = ResultEntrancePresentation(schedule: clock.schedule)
            result.update(sessionID: id, status: .playing, animate: true)
            result.update(sessionID: id, status: .won, animate: true); clock.advance(0.83)
            result.update(sessionID: leave ? UUID() : id, status: leave ? .playing : .won, animate: false)
            XCTAssertNil(result.animationID); XCTAssertEqual(result.stage, .settled)
            clock.advance(3)
            XCTAssertNil(result.animationID); XCTAssertEqual(result.stage, .settled)
        }
        let restored = ResultEntrancePresentation()
        restored.update(sessionID: UUID(), status: .won, animate: true)
        XCTAssertTrue(restored.ready); XCTAssertEqual(restored.stage, .settled); XCTAssertNil(restored.animationID)
    }

    @MainActor func testLastLifeWaitsForAcknowledgementAndNeverReplaysHiddenChanges() {
        let clock = ChoreographyClock(), feedback = GameFeedbackPresentation(schedule: clock.schedule)
        feedback.life(1); clock.advance(20)
        XCTAssertTrue(feedback.showLastLife, "The player must have time to read and acknowledge it.")
        feedback.dismissLastLife(); clock.advance(20); XCTAssertFalse(feedback.showLastLife)
        feedback.life(3); feedback.life(1); XCTAssertTrue(feedback.showLastLife)
        feedback.setPresentationEnabled(false); feedback.life(1); feedback.setPresentationEnabled(true)
        XCTAssertFalse(feedback.showLastLife)
        feedback.life(1); feedback.life(0); XCTAssertFalse(feedback.showLastLife)
    }

    func testSpotlightGeometryTracksMeasuredHeartsAndRejectsInvalidOrOffscreenFrames() {
        let size = CGSize(width: 320, height: 568), measured = CGRect(x: 205, y: 120, width: 74, height: 32)
        let hole = LastLifeSpotlightView.focusFrame(measured, in: size)
        XCTAssertTrue(hole.contains(measured)); XCTAssertEqual(hole.midX, measured.midX)
        for rect in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), CGRect(x: -500, y: 600, width: 1000, height: 100)] {
            let valid = LastLifeSpotlightView.focusFrame(rect, in: size)
            XCTAssertTrue(valid.minX.isFinite); XCTAssertTrue(valid.minY.isFinite)
            XCTAssertGreaterThanOrEqual(valid.minX, 0); XCTAssertLessThanOrEqual(valid.maxX, size.width)
            XCTAssertLessThanOrEqual(valid.maxY, size.height * 0.36)
        }
    }

    @MainActor func testAtmosphereIsFiniteBoundedAndCoverCannotReplayItsParticles() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 360)
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(white: 0.14, alpha: 1)
        window.rootViewController = controller; window.makeKeyAndVisible()
        let effect = ResultAtmosphereUIView(frame: controller.view.bounds)
        effect.autoresizingMask = [.flexibleWidth, .flexibleHeight]; controller.view.addSubview(effect)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        controller.view.layoutIfNeeded()
        let id = UUID(); effect.configure(won: true, eventID: id, enabled: true, reduceMotion: false)
        XCTAssertEqual(effect.activeEventID, id); XCTAssertEqual(effect.playedEvents, 1); XCTAssertEqual(effect.particleCount, 28)
        XCTAssertFalse(effect.isUserInteractionEnabled)
        try await Task.sleep(nanoseconds: 350_000_000)
        capture(controller.view, "result-atmosphere-rays-confetti-350ms")
        effect.configure(won: true, eventID: id, enabled: false, reduceMotion: false)
        XCTAssertNil(effect.activeEventID)
        effect.configure(won: true, eventID: id, enabled: true, reduceMotion: false)
        XCTAssertEqual(effect.playedEvents, 1)
        effect.configure(won: true, eventID: UUID(), enabled: true, reduceMotion: true)
        XCTAssertNil(effect.activeEventID); XCTAssertEqual(effect.playedEvents, 1)
        effect.configure(won: false, eventID: UUID(), enabled: true, reduceMotion: false)
        XCTAssertNil(effect.activeEventID)
        effect.configure(won: true, eventID: UUID(), enabled: true, reduceMotion: false)
        try await Task.sleep(nanoseconds: 1_650_000_000)
        XCTAssertNil(effect.activeEventID); XCTAssertEqual(effect.playedEvents, 2)
        func animationCount(_ layer: CALayer) -> Int { (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + animationCount($1) } }
        XCTAssertEqual(animationCount(effect.layer), 0)
    }

    @MainActor func testCurrentLevelSixRootShowsSequentialResultAndAccessibleImmediateAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("result-choreography-" + UUID().uuidString)
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
        try await Task.sleep(nanoseconds: 650_000_000)
        for cell in try XCTUnwrap(model.session).puzzle.solution { model.submit(cell) }
        let won = model.session; XCTAssertEqual(won?.status, .won)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(frames["result_primary_action"])
        capture(host.view, "current-L6-final-board-200ms")
        try await Task.sleep(nanoseconds: 680_000_000)
        capture(host.view, "current-L6-character-first-880ms")
        try await Task.sleep(nanoseconds: 190_000_000)
        capture(host.view, "current-L6-title-second-1070ms")
        try await Task.sleep(nanoseconds: 430_000_000)
        capture(host.view, "current-L6-complete-celebration-1500ms")
        XCTAssertEqual(model.session, won)
        model.next(); XCTAssertEqual(model.session?.puzzle.id, 7)
    }

    @MainActor func testActualSmallRootOneLifeFocusFitsChineseAndPreservesCommittedState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("last-life-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true; model.start(level: 6)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        var frames: [String: CGRect] = [:]
        let host = UIHostingController(rootView: RootView(reduceMotionOverride: true).environmentObject(model)
            .environment(\.scenePhase, .active).environment(\.dynamicTypeSize, .accessibility1)
            .environment(\.capyLayoutObserver, { frames[$0] = $1 }))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let session = try XCTUnwrap(model.session), wrong = (0..<(session.puzzle.size * session.puzzle.size)).filter { !session.puzzle.solution.contains($0) }
        model.submit(wrong[0]); try await Task.sleep(nanoseconds: 100_000_000); model.submit(wrong[1])
        let committed = model.session; XCTAssertEqual(committed?.lives, 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(frames["last_life_continue"])
        capture(host.view, "current-L6-last-life-small-Chinese-large-type")
        XCTAssertEqual(model.session, committed)
        model.home(); try await Task.sleep(nanoseconds: 100_000_000); model.startOrContinue()
        try await Task.sleep(nanoseconds: 200_000_000)
        // A real Home/Continue transition opens the next analytics result phase.
        // Keep an exact session comparison, including every gameplay field.
        var expected = try XCTUnwrap(committed)
        XCTAssertNotNil(expected.claimResult(.quit))
        XCTAssertTrue(expected.resumeAfterQuit())
        XCTAssertEqual(model.session, expected)
    }

    @MainActor private func capture(_ view: UIView, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: false) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
