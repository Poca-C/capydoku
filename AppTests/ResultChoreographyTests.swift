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
    @MainActor func testActualRootThreeResultEntrancesAndExitsRunContinuouslyForVideoReview() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let sequenceStart = ProcessInfo.processInfo.systemUptime
        var observations = [[String: Any]]()
        var fixtures: [(width: Int, performance: String, earlyExit: Bool)] = []
        for width in [402, 320] {
            for performance in ["joyful", "star-hug", "retry"] {
                fixtures.append((width, performance, false))
            }
        }
        fixtures.append((320, "joyful", true))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func controllers(_ controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children.flatMap(controllers)
        }

        for fixture in fixtures {
            let name = "three-results-\(fixture.width)-\(fixture.performance)\(fixture.earlyExit ? "-early-exit" : "")"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true; model.start(level: 6)
            // Pick the actual Root's variant before it binds this session. Each
            // fixture has its own host/save, so no event identity is reused there.
            let fixedID = try XCTUnwrap(UUID(uuidString: fixture.performance == "star-hug"
                ? "01000000-0000-4000-8000-000000000263" : "02000000-0000-4000-8000-000000000263"))
            model.progress.session?.id = fixedID
            let initial = try XCTUnwrap(model.session)
            XCTAssertEqual(initial.puzzle.id, 6)
            XCTAssertEqual(initial.id.uuid.0.isMultiple(of: 2), fixture.performance != "star-hug")
            let previous = scene.windows.first(where: \.isKeyWindow)
            let surround = UIWindow(windowScene: scene); surround.frame = scene.coordinateSpace.bounds
            let backdrop = UIViewController(); backdrop.view.backgroundColor = .black
            surround.rootViewController = backdrop; surround.windowLevel = UIWindow.Level(rawValue: 1)
            surround.isHidden = false
            let window = UIWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: 2); window.overrideUserInterfaceStyle = .light
            window.frame = CGRect(x: 0, y: 0, width: fixture.width, height: fixture.width == 320 ? 568 : 874)
            var frames = [String: CGRect]()
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: false).environmentObject(model)
                .environment(\.scenePhase, .active).environment(\.capyLayoutObserver, { frames[$0] = $1 }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                model.setActive(false)
                window.isHidden = true; window.rootViewController = nil
                surround.isHidden = true; surround.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            var events = [[String: Any]]()
            func record(_ event: String) {
                events.append(["event": event, "secondsFromSequenceStart": ProcessInfo.processInfo.systemUptime - sequenceStart,
                    "level": model.session?.puzzle.id ?? -1, "found": model.session?.found.sorted() ?? [],
                    "score": model.session?.score ?? -1, "lives": model.session?.lives ?? -1])
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            record("mounted-playing-L6")
            let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
            let won = fixture.performance != "retry"
            let submissions = won ? initial.puzzle.solution : Array(initial.puzzle.regions.indices
                .filter { !initial.puzzle.solution.contains($0) }.prefix(initial.lives))
            for (ordinal, cell) in submissions.enumerated() {
                XCTAssertTrue(board.activate(index: cell, submit: true))
                record("native-submit-\(cell)")
                if ordinal < submissions.count - 1 { try await Task.sleep(nanoseconds: 80_000_000) }
            }
            let committed = try XCTUnwrap(model.session)
            XCTAssertEqual(committed.id, fixedID); XCTAssertEqual(committed.status, won ? .won : .lost)
            let terminalAt = ProcessInfo.processInfo.systemUptime
            record("terminal-committed")
            // Observe the real delayed event without changing its scheduler or
            // taking a screenshot during the 180ms compositing transition.
            var activeCharacter: ResultCharacterUIView?
            for _ in 0..<320 {
                if let character = descendants(host.view).compactMap({ $0 as? ResultCharacterUIView })
                    .first(where: { $0.activeEventID != nil }) {
                    activeCharacter = character; break
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let character = try XCTUnwrap(activeCharacter, "The actual Root must start its finite result performance.")
            let observedEntranceDelay = ProcessInfo.processInfo.systemUptime - terminalAt
            XCTAssertGreaterThan(observedEntranceDelay, won ? 0.70 : 0.48,
                "The board's ordinary celebration/error delay must not be bypassed by this fixture.")
            XCTAssertEqual(character.playedEventCount, 1)
            XCTAssertNotNil(frames["result_primary_action"])
            record("character-event-observed")
            if fixture.earlyExit {
                try await Task.sleep(nanoseconds: 60_000_000)
                XCTAssertNotNil(character.activeEventID)
            } else {
                // The character has settled and the entrance fade has ended;
                // this readback cannot interrupt the compositing transition.
                try await Task.sleep(nanoseconds: 1_350_000_000)
                XCTAssertNil(character.activeEventID)
                capture(window, name + "-settled-result")
                record("settled-result-snapshot")
            }
            XCTAssertEqual(model.session, committed, "Result decoration cannot change the accepted outcome.")
            let exitAction = fixture.earlyExit || (won && fixture.width == 320) ? "next"
                : won ? "home" : "restart"
            record("leave-\(exitAction)\(fixture.earlyExit ? "-during-entrance" : "")")
            if exitAction == "next" { model.next() }
            else if exitAction == "home" { model.home() }
            else { model.restart() }
            if exitAction == "home" { XCTAssertEqual(model.screen, .home) }
            else { XCTAssertEqual(model.session?.status, .playing) }
            XCTAssertNil(model.sheet); XCTAssertNil(model.errorMessage)
            try await Task.sleep(nanoseconds: 60_000_000)
            for owner in controllers(host).filter({
                String(describing: type(of: $0)).hasPrefix("CapyAccessibilityController<") &&
                    String(describing: type(of: $0)).contains("ResultPanel")
            }) {
                XCTAssertFalse(owner.view.isUserInteractionEnabled)
                XCTAssertTrue(owner.view.accessibilityElementsHidden)
            }
            XCTAssertNil(character.activeEventID, "Leaving during the fade cancels the old joint performance.")
            if exitAction == "home" {
                // Home preserves the completed board. Resume it and explicitly
                // advance, matching the existing user-facing Continue flow.
                try await Task.sleep(nanoseconds: 220_000_000)
                model.startOrContinue(); record("home-continue")
                if model.session?.status == .won { model.next(); record("resumed-result-next") }
            }
            var resumedBoard: PuzzleGridUIView?
            for _ in 0..<80 {
                if let current = descendants(host.view).compactMap({ $0 as? PuzzleGridUIView }).first,
                   current.accessibilityElements?.isEmpty == false {
                    resumedBoard = current; break
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let currentBoard = try XCTUnwrap(resumedBoard)
            let resumed = try XCTUnwrap(model.session)
            XCTAssertEqual(resumed.status, .playing); XCTAssertEqual(resumed.puzzle.id, won ? 7 : 6)
            let mark = try XCTUnwrap(resumed.puzzle.regions.indices.first { !resumed.found.contains($0) })
            XCTAssertTrue(currentBoard.activate(index: mark, submit: false))
            XCTAssertTrue(model.session?.marks.contains(mark) == true)
            XCTAssertTrue(currentBoard.activate(index: mark, submit: false))
            XCTAssertEqual(model.session, resumed, "A mark and undo must preserve all other new-board state.")
            let correct = try XCTUnwrap(resumed.puzzle.solution.first { !resumed.found.contains($0) })
            XCTAssertTrue(currentBoard.activate(index: correct, submit: true))
            let accepted = try XCTUnwrap(model.session)
            XCTAssertEqual(accepted.found.count, resumed.found.count + 1); XCTAssertEqual(accepted.lives, resumed.lives)
            record("destination-mark-undo-first-find-accepted")
            try await Task.sleep(nanoseconds: fixture.earlyExit ? 1_400_000_000 : 300_000_000)
            XCTAssertEqual(model.session, accepted, "A departed result's late cleanup cannot mutate the new game.")
            XCTAssertNil(character.activeEventID)
            capture(window, name + "-destination")
            observations.append(["fixture": name, "width": fixture.width, "height": fixture.width == 320 ? 568 : 874,
                "sessionID": fixedID.uuidString, "performance": fixture.performance, "earlyExit": fixture.earlyExit,
                "observedEntranceDelaySeconds": observedEntranceDelay, "exitAction": exitAction, "events": events])
        }
        let data = try JSONSerialization.data(withJSONObject: ["fixtures": observations,
            "boundary": "Actual Root with normal motion, real bundled L6 submissions through native board endpoints, six complete performances and one departure during entrance. No screenshot readback inside entrance/exit fades; stable snapshots only. Event observation uses the live monotonic clock, not frame synchronization. This is not physical-touch, live-audio, FPS, exact reference-timing or grouped-opacity pixel verification; external recording has its own time origin."],
            options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "three-result-root-natural-event-times"; attachment.lifetime = .keepAlways; add(attachment)
    }

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
        feedback.bindLives(3)
        feedback.life(1); clock.advance(20)
        XCTAssertTrue(feedback.showLastLife, "The player must have time to read and acknowledge it.")
        feedback.dismissLastLife(); clock.advance(20); XCTAssertFalse(feedback.showLastLife)
        feedback.life(3); feedback.life(1); clock.advance(1.36); XCTAssertTrue(feedback.showLastLife)
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
        XCTAssertNil(frames["last_life_continue"])
        try await Task.sleep(nanoseconds: 1_150_000_000)
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

    @MainActor func testActualRootOneLifeFocusDoesNotCrossIntoFreshOrRestoredSession() async throws {
        var observations = [[String: Any]]()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for reduced in [false, true] { for restoreOneLife in [false, true] {
            let name = "one-life-replace-\(restoreOneLife ? "restored" : "fresh")-\(reduced ? "reduced" : "normal")"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name + UUID().uuidString)
            let restoredDirectory = directory.appendingPathComponent("saved-one-life")
            let savedModel = AppModel(saveDirectory: restoredDirectory, runsTimer: false, feedbackEnabled: false)
            savedModel.progress.tutorialCompleted = true; savedModel.start(level: 6)
            let savedInitial = try XCTUnwrap(savedModel.session)
            let savedWrong = savedInitial.puzzle.regions.indices.filter { !savedInitial.puzzle.solution.contains($0) }
            for index in savedWrong.prefix(savedInitial.lives - 1) { savedModel.submit(index) }
            savedModel.flushPendingSaves()
            let loadedModel = AppModel(saveDirectory: restoredDirectory, runsTimer: false, feedbackEnabled: false)
            let restored = try XCTUnwrap(loadedModel.session)
            XCTAssertEqual(restored.lives, 1); XCTAssertEqual(restored.status, .playing)

            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true; model.start(level: 6)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
            window.overrideUserInterfaceStyle = .light
            var frames = [String: CGRect]()
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model)
                .environment(\.scenePhase, .active).environment(\.capyLayoutObserver, { frames[$0] = $1 }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); loadedModel.flushPendingSaves(); savedModel.flushPendingSaves()
                try? FileManager.default.removeItem(at: directory)
            }
            func nativeBoard(in view: UIView) -> PuzzleGridUIView? {
                if let board = view as? PuzzleGridUIView { return board }
                for child in view.subviews { if let board = nativeBoard(in: child) { return board } }
                return nil
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            let board = try XCTUnwrap(nativeBoard(in: host.view))
            let initial = try XCTUnwrap(model.session)
            let correct = try XCTUnwrap(initial.puzzle.solution.first)
            // Two distinct wrong cells in the found character's row make the
            // prior session own both a rule explanation and one-life mode.
            let rowWrong = initial.puzzle.regions.indices.filter {
                $0 / initial.puzzle.size == correct / initial.puzzle.size && !initial.puzzle.solution.contains($0)
            }
            XCTAssertGreaterThanOrEqual(rowWrong.count, 2)
            XCTAssertTrue(board.activate(index: correct, submit: true))
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(board.activate(index: rowWrong[0], submit: true))
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(board.activate(index: rowWrong[1], submit: true))
            try await Task.sleep(nanoseconds: 1_400_000_000)
            for _ in 0..<40 {
                if board.accessibilityElements?.isEmpty == true, frames["last_life_continue"] != nil { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let departed = try XCTUnwrap(model.session)
            XCTAssertEqual(departed.lives, 1); XCTAssertEqual(departed.status, .playing)
            XCTAssertNotNil(frames["last_life_continue"])
            XCTAssertTrue(board.accessibilityElements?.isEmpty == true)
            XCTAssertFalse(board.activate(index: rowWrong[0], submit: false), "The same-session one-life acknowledgement must still lock input.")

            if restoreOneLife { model.progress.session = restored }
            else { model.start(level: 6) }
            let replacement = try XCTUnwrap(model.session)
            XCTAssertNotEqual(replacement.id, departed.id)
            XCTAssertEqual(replacement.lives, restoreOneLife ? 1 : initial.lives)
            for _ in 0..<40 {
                if board.accessibilityElements?.count == replacement.puzzle.size * replacement.puzzle.size { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let currentBoard = try XCTUnwrap(nativeBoard(in: host.view))
            let cells = try XCTUnwrap(currentBoard.accessibilityElements as? [UIAccessibilityElement])
            XCTAssertEqual(cells.count, replacement.puzzle.size * replacement.puzzle.size)
            let usableIndex = try XCTUnwrap(replacement.puzzle.regions.indices.first {
                !replacement.found.contains($0) && !replacement.errors.contains($0)
            })
            let cell = try XCTUnwrap(cells.first { $0.accessibilityIdentifier == "cell_\(usableIndex)" })
            XCTAssertFalse(cell.accessibilityTraits.contains(.notEnabled))
            XCTAssertEqual(cell.accessibilityCustomActions?.count, 2)
            XCTAssertEqual(cell.accessibilityValue, "empty")
            XCTAssertEqual(model.session, replacement, "Presentation reset must not mutate the restored or new game.")
            XCTAssertTrue(cell.accessibilityActivate())
            XCTAssertTrue(model.session?.marks.contains(usableIndex) == true)
            XCTAssertTrue(currentBoard.activate(index: usableIndex, submit: false))
            XCTAssertEqual(model.session?.marks, replacement.marks)
            XCTAssertTrue(currentBoard.activate(index: try XCTUnwrap(replacement.puzzle.solution.first), submit: true))
            XCTAssertEqual(model.session?.found.count, replacement.found.count + 1)
            XCTAssertEqual(model.session?.lives, replacement.lives)
            observations.append(["restoredOneLife": restoreOneLife, "reduceMotion": reduced,
                "replacementAccessibleCells": cells.count, "replacementLives": replacement.lives])
        } }
        let data = try JSONSerialization.data(withJSONObject: ["cases": observations,
            "boundary": "Actual Root remains mounted while its session changes. Native board accessibility and activation verify the current input mode. This does not measure transition pixels, rule-strip tint, display FPS, physical touch latency, or VoiceOver speech/focus timing."], options: [.prettyPrinted, .sortedKeys])
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        a.name = "one-life-session-replacement-observations"; a.lifetime = .keepAlways; add(a)
    }

    @MainActor private func capture(_ view: UIView, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: false) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
