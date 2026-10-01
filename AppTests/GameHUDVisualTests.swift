import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class EarlyAdvanceDisplaySampler: NSObject {
    var sample: (() -> Void)?
    private var link: CADisplayLink?
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    @objc private func tick() { sample?() }
    func stop() { link?.invalidate(); link = nil; sample = nil }
}

final class GameHUDVisualTests: XCTestCase {
    @MainActor func testActualRootConflictLinksPreserveFacesIncludingUnrelatedVisibleAnimal() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (level, width, reduced, variant) in [(6, 402, false, "single"), (63, 320, false, "single"),
                (63, 320, true, "single"), (101, 320, false, "single"),
                (6, 320, false, "successive"), (63, 320, false, "marked"), (63, 320, false, "mark-later")] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conflict-face-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true; model.start(level: level)
            let initial = try XCTUnwrap(model.session)
            let found: [Int] = level == 63 ? (variant.hasPrefix("mark") ? [62] : [62, 51]) : level == 101 ? Array(initial.puzzle.solution.dropLast())
                : [try XCTUnwrap(initial.puzzle.solution.first)]
            var candidate = level == 63 ? 40 : try XCTUnwrap(initial.puzzle.regions.indices.first {
                $0 / initial.puzzle.size == found[0] / initial.puzzle.size && !initial.puzzle.solution.contains($0)
            })
            XCTAssertTrue(found.allSatisfy { initial.puzzle.solution.contains($0) })
            for index in found { model.submit(index) }
            if variant == "marked" { model.toggle(51) }
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: width == 320 ? 568 : 874)
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model)
                .environment(\.scenePhase, .active))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(nanoseconds: 620_000_000)
            let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
            XCTAssertTrue(board.activate(index: candidate, submit: true))
            if variant == "successive" {
                try await Task.sleep(nanoseconds: 120_000_000)
                candidate = 3
                XCTAssertFalse(initial.puzzle.solution.contains(candidate))
                XCTAssertTrue(board.activate(index: candidate, submit: true))
            }
            var originalExplanation: BoardConflictFeedbackView?
            if variant == "mark-later" {
                try await Task.sleep(nanoseconds: 100_000_000)
                originalExplanation = try XCTUnwrap(descendants(board).compactMap { $0 as? BoardConflictFeedbackView }.first)
                XCTAssertTrue(board.activate(index: 51, submit: false))
            }
            let committed = try XCTUnwrap(model.session)
            try await Task.sleep(nanoseconds: 300_000_000)
            let effect = try XCTUnwrap(descendants(board).compactMap { $0 as? BoardConflictFeedbackView }.first)
            if let originalExplanation { XCTAssertTrue(effect === originalExplanation) }
            if level == 63 {
                XCTAssertEqual(effect.conflicts.map(\.otherCell), [62], "The animal crossed by the line is not a conflict partner.")
                XCTAssertEqual(effect.conflicts.first?.kinds, [.region])
            }
            let label = "conflict-faces-L\(level)-\(width)-reduced-\(reduced)-\(variant)"
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            let attachment = XCTAttachment(image: screenshot); attachment.name = label
            attachment.lifetime = .keepAlways; add(attachment)
            // Pixel comparison uses a static copy of this actual explanation's
            // current model layers after the natural screenshot. Toggle only
            // the two connector strokes: region tint/rings must remain equal.
            effect.layer.removeAllAnimations(); effect.layer.opacity = 1
            let lines = (effect.layer.sublayers ?? []).filter { $0.name?.hasPrefix("conflict-link") == true }
            XCTAssertEqual(lines.count, 2)
            let format = UIGraphicsImageRendererFormat(); format.scale = 3
            let renderer = UIGraphicsImageRenderer(bounds: effect.bounds, format: format)
            let linked = try XCTUnwrap(renderer.image { effect.layer.render(in: $0.cgContext) }.cgImage)
            lines.forEach { $0.isHidden = true }
            let plain = try XCTUnwrap(renderer.image { effect.layer.render(in: $0.cgContext) }.cgImage)
            func bytes(_ image: CGImage) -> [UInt8] {
                var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
                result.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                return result
            }
            XCTAssertGreaterThan(zip(bytes(linked), bytes(plain)).filter { abs(Int($0) - Int($1)) > 2 }.count, 0,
                "Connections must remain visible between cells; hiding all strokes is not a fix.")
            var protectedRects = [Int: CGRect]()
            for index in committed.found.union(committed.marks).union(committed.errors).sorted() {
                let cell = try XCTUnwrap(board.accessibilityElements?[index] as? UIAccessibilityElement).accessibilityFrameInContainerSpace
                // The actual artwork is inset inside the painted tile, which
                // itself excludes the grid gap. Compare fully covered pixels,
                // without expanding the crop into the unrelated gutter.
                let gap = max(1.1, min(2, cell.width * 0.028))
                let tile = cell.insetBy(dx: gap, dy: gap)
                let scaled = tile.insetBy(dx: tile.width * 0.07, dy: tile.height * 0.07)
                    .applying(CGAffineTransform(scaleX: 3, y: 3))
                let portrait = CGRect(x: ceil(scaled.minX), y: ceil(scaled.minY),
                    width: floor(scaled.maxX) - ceil(scaled.minX), height: floor(scaled.maxY) - ceil(scaled.minY))
                protectedRects[index] = portrait
                let a = try XCTUnwrap(linked.cropping(to: portrait)), b = try XCTUnwrap(plain.cropping(to: portrait))
                XCTAssertEqual(zip(bytes(a), bytes(b)).filter { abs(Int($0) - Int($1)) > 2 }.count, 0,
                    "\(label) cell\(index): connector ink must not cross a visible face, mark or error.")
            }
            if variant == "mark-later" {
                lines.forEach { $0.isHidden = false }
                XCTAssertTrue(board.activate(index: 51, submit: false))
                try await Task.sleep(nanoseconds: 80_000_000)
                XCTAssertTrue(descendants(board).contains { $0 === effect }, "A new mark must not restart the explanation.")
                let unmarked = try XCTUnwrap(renderer.image { effect.layer.render(in: $0.cgContext) }.cgImage)
                let crop = try XCTUnwrap(protectedRects[51])
                let a = try XCTUnwrap(unmarked.cropping(to: crop)), b = try XCTUnwrap(plain.cropping(to: crop))
                XCTAssertGreaterThan(zip(bytes(a), bytes(b)).filter { abs(Int($0) - Int($1)) > 2 }.count, 0,
                    "An erased mark must not leave a stale hole in the connector.")
                var expected = committed; expected.toggleMark(at: 51)
                XCTAssertEqual(model.session, expected)
            } else { XCTAssertEqual(model.session, committed) }
        }
    }

    @MainActor func testActualRootContinuingBeforeLastLifeReminderCancelsOldFocus() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for action in ["correct", "mark", "lose", "cover", "replace"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("last-life-continue-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true; model.start(level: 6)
            let initial = try XCTUnwrap(model.session)
            let wrong = initial.puzzle.regions.indices.filter { !initial.puzzle.solution.contains($0) }
            model.submit(wrong[0])
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
            var frames = [String: CGRect]()
            let host = UIHostingController(rootView: RootView().environmentObject(model).environment(\.scenePhase, .active)
                .environment(\.capyLayoutObserver, { frames[$0] = $1 }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
            XCTAssertTrue(board.activate(index: wrong[1], submit: true))
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertNil(frames["last_life_continue"])
            switch action {
            case "correct":
                XCTAssertTrue(board.activate(index: initial.puzzle.solution[0], submit: true))
                XCTAssertEqual(model.session?.combo, 1, "First correct has no Combo badge but still cancels pending focus.")
            case "mark": XCTAssertTrue(board.activate(index: wrong[2], submit: false))
            case "lose": XCTAssertTrue(board.activate(index: wrong[2], submit: true))
            case "cover": model.sheet = .settings; model.sheet = nil
            default: model.start(level: 7)
            }
            let committed = model.session
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertNil(frames["last_life_continue"], "A late reminder must not interrupt \(action).")
            XCTAssertEqual(model.session, committed)
            if action == "lose" { XCTAssertEqual(model.session?.status, .lost) }
            else {
                XCTAssertFalse(board.accessibilityElementsHidden)
                if action == "correct" { XCTAssertEqual(model.session?.found.count, 1) }
                if action == "mark" { XCTAssertTrue(model.session?.marks.contains(wrong[2]) == true) }
            }
        }
    }

    @MainActor func testActualRootLastLifeAllowsMistakeExplanationBeforeReminder() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (width, reduced) in [(402, false), (320, true)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("last-life-handoff-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true; model.start(level: 6)
            let initial = try XCTUnwrap(model.session), first = try XCTUnwrap(initial.puzzle.solution.first)
            let wrong = initial.puzzle.regions.indices.filter { !initial.puzzle.solution.contains($0) }
            let candidate = try XCTUnwrap(wrong.first { $0 / initial.puzzle.size == first / initial.puzzle.size })
            let earlier = try XCTUnwrap(wrong.first { $0 != candidate })
            model.submit(first); model.submit(earlier)
            XCTAssertEqual(model.session?.lives, 2)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: 2)
            window.frame = CGRect(x: 0, y: 0, width: width, height: width == 320 ? 568 : 874)
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model)
                .environment(\.scenePhase, .active))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(nanoseconds: 620_000_000)
            let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
            XCTAssertTrue(board.activate(index: candidate, submit: true))
            let committed = try XCTUnwrap(model.session)
            XCTAssertEqual(committed.lives, 1)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertFalse(board.accessibilityElementsHidden, "The same mistake must remain visible before the reminder takes focus.")
            XCTAssertTrue(descendants(board).contains { $0 is BoardConflictFeedbackView },
                "The reminder must not discard the just-triggered visible-rule explanation.")
            let early = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            let a = XCTAttachment(image: early); a.name = "last-life-\(width)-reduced-\(reduced)-mistake"
            a.lifetime = .keepAlways; add(a)
            try await Task.sleep(nanoseconds: 1_300_000_000)
            XCTAssertTrue(board.accessibilityElementsHidden, "The reminder still appears after the error explanation.")
            XCTAssertEqual(model.session, committed, "Presentation must not change lives, marks or score.")
            let late = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            let b = XCTAttachment(image: late); b.name = "last-life-\(width)-reduced-\(reduced)-reminder"
            b.lifetime = .keepAlways; add(b)
        }
    }

    /// Watch actual newly mounted native reward views while the result is
    /// skipped before its character entrance. Never read back a screenshot in
    /// that interval: keep the recording useful for the mixed-renderer window.
    @MainActor func testActualRootEarlyAdvanceDoesNotCarryOldRewardsIntoTheNextBoard() async throws {
        var cases: [[String: Any]] = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (width, restart, reduced) in [(320, false, false), (320, true, false), (402, false, false), (320, false, true)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("early-advance-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true; model.start(level: 6)
            let initial = try XCTUnwrap(model.session), last = try XCTUnwrap(initial.puzzle.solution.last)
            for index in initial.puzzle.solution.dropLast() { model.submit(index) }
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            let surround = UIWindow(windowScene: scene); surround.frame = scene.coordinateSpace.bounds
            let backdrop = UIViewController(); backdrop.view.backgroundColor = .black
            surround.rootViewController = backdrop; surround.windowLevel = UIWindow.Level(rawValue: 1); surround.isHidden = false
            window.windowLevel = UIWindow.Level(rawValue: 2)
            window.frame = CGRect(x: 0, y: 0, width: width, height: width == 320 ? 568 : 874)
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model).environment(\.scenePhase, .active))
            window.rootViewController = host; window.makeKeyAndVisible()
            let sampler = EarlyAdvanceDisplaySampler()
            defer {
                sampler.stop(); window.isHidden = true; window.rootViewController = nil
                surround.isHidden = true; surround.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(nanoseconds: 620_000_000)
            let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
            XCTAssertTrue(board.activate(index: last, submit: true))
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(model.session?.status, .won)
            let previousApplause = try XCTUnwrap(descendants(host.view).compactMap { $0 as? ApplauseFeedbackUIView }.first)
            // Reduced motion shows the result immediately and suppresses its
            // departing board applause; a missing event is expected there.
            let previousEvent = previousApplause.activeEventID
            if !reduced { XCTAssertNotNil(previousEvent) }
            let departedSession = try XCTUnwrap(model.session), advancedAt = ProcessInfo.processInfo.systemUptime
            var observations: [[String: Any]] = []
            sampler.sample = {
                let native = self.descendants(host.view)
                let applause = native.compactMap { $0 as? ApplauseFeedbackUIView }.first
                let newOwner = applause != nil && applause !== previousApplause
                let oldEvent = previousEvent != nil && applause?.activeEventID == previousEvent
                let resultPlaying = native.compactMap { $0 as? ResultCharacterUIView }.contains { $0.activeEventID != nil }
                observations.append(["secondsAfterAdvance": ProcessInfo.processInfo.systemUptime - advancedAt,
                    "newApplauseOwner": newOwner, "oldApplauseEvent": oldEvent,
                    "resultCharacterPlaying": resultPlaying, "found": model.session?.found.count ?? -1])
            }
            sampler.start()
            if restart { model.restart() } else { model.next() }
            let next = try XCTUnwrap(model.session)
            XCTAssertNotEqual(next.id, departedSession.id); XCTAssertEqual(next.status, .playing)
            XCTAssertEqual(next.puzzle.id, restart ? 6 : 7); XCTAssertEqual(next.score, 0); XCTAssertTrue(next.found.isEmpty)
            try await Task.sleep(nanoseconds: 420_000_000)
            sampler.stop()
            XCTAssertTrue(observations.contains { $0["newApplauseOwner"] as? Bool == true })
            XCTAssertFalse(observations.contains {
                $0["newApplauseOwner"] as? Bool == true && $0["oldApplauseEvent"] as? Bool == true
            }, "A new board must never consume the previous board's applause event.")
            XCTAssertFalse(observations.contains { $0["resultCharacterPlaying"] as? Bool == true },
                "Skipping before result decoration must not start a late result character.")
            XCTAssertEqual(model.session, next, "A delayed presentation may not mutate the new board.")
            let newBoard = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
            XCTAssertTrue(newBoard.activate(index: try XCTUnwrap(next.puzzle.solution.first), submit: true))
            try await Task.sleep(nanoseconds: 120_000_000)
            let newEvent = try XCTUnwrap(descendants(host.view).compactMap { $0 as? ApplauseFeedbackUIView }.first?.activeEventID)
            XCTAssertNotEqual(newEvent, previousEvent, "A real new find must still receive its own reward.")
            XCTAssertEqual(model.session?.found.count, 1); XCTAssertGreaterThan(model.session?.score ?? 0, 0)
            cases.append(["width": width, "restart": restart, "reduced": reduced,
                "advancedAtUptime": advancedAt, "observations": observations])
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            let a = XCTAttachment(image: image); a.name = "early-advance-\(width)-restart-\(restart)-reduced-\(reduced)-fresh-reward"
            a.lifetime = .keepAlways; add(a)
        }
        let data = try JSONSerialization.data(withJSONObject: ["cases": cases,
            "boundary": "Actual Root, requested120ms after final find, then next/restart via AppModel. CADisplayLink observes native reward identity without screenshot readback. Samples are finite and do not prove per-frame pixel/FPS or physical touch latency."], options: [.prettyPrinted, .sortedKeys])
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); a.name = "early-advance-native-observations"
        a.lifetime = .keepAlways; add(a)
    }

    /// Continuous actual Root handoff; no screenshot readback during entrance.
    /// Wall-clock observations describe this fixture, not touch latency or FPS.
    @MainActor func testActualRootResultControlHandoffPlaysContinuously() async throws {
        var samples: [[String: Any]] = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (width, won, reduced) in [(402, true, false), (320, true, false), (320, false, false), (320, true, true), (320, false, true)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("result-handoff-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true; model.start(level: 6)
            let initial = try XCTUnwrap(model.session), solution = initial.puzzle.solution
            let wrong = (0..<(initial.puzzle.size * initial.puzzle.size)).filter { !solution.contains($0) }
            if won { for index in solution.dropLast() { model.submit(index) } }
            else { for index in wrong.prefix(initial.lives - 1) { model.submit(index) } }
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            let surround = UIWindow(windowScene: scene); surround.frame = scene.coordinateSpace.bounds
            let backdrop = UIViewController(); backdrop.view.backgroundColor = .black
            surround.rootViewController = backdrop; surround.windowLevel = UIWindow.Level(rawValue: 1)
            surround.isHidden = false; window.windowLevel = UIWindow.Level(rawValue: 2)
            window.frame = CGRect(x: 0, y: 0, width: width, height: width == 320 ? 568 : 874)
            var frames: [String: CGRect] = [:]
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model)
                .environment(\.scenePhase, .active).environment(\.capyLayoutObserver, { frames[$0] = $1 }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil
                surround.isHidden = true; surround.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(nanoseconds: 620_000_000)
            let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
            let boardFrame = try XCTUnwrap(frames["puzzle_board"])
            let submittedAt = ProcessInfo.processInfo.systemUptime
            XCTAssertTrue(board.activate(index: won ? solution.last! : wrong[initial.lives - 1], submit: true))
            let committed = try XCTUnwrap(model.session)
            XCTAssertEqual(committed.status, won ? .won : .lost)
            try await Task.sleep(nanoseconds: 60_000_000)
            for _ in 0..<10 where frames["result_primary_action"] == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            let action = try XCTUnwrap(frames["result_primary_action"])
            XCTAssertGreaterThan(action.width, 44); XCTAssertGreaterThanOrEqual(action.height, 44)
            XCTAssertGreaterThanOrEqual(action.minY, boardFrame.maxY,
                "The active result button must not travel over the board's final feedback.")
            samples.append(["width": width, "won": won, "reduced": reduced,
                "submittedAtUptime": submittedAt,
                "firstActionObservationSeconds": ProcessInfo.processInfo.systemUptime - submittedAt,
                "actionFrame": NSCoder.string(for: action), "boardFrame": NSCoder.string(for: boardFrame)])
            // Keep this interval free of screenshot readbacks so the recording
            // can expose the control/decorative handoff in continuous playback.
            try await Task.sleep(nanoseconds: 1_600_000_000)
            XCTAssertEqual(model.session, committed)
            XCTAssertEqual(frames["puzzle_board"], boardFrame)
            XCTAssertEqual(frames["result_primary_action"], action)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            let a = XCTAttachment(image: image); a.name = "result-handoff-\(width)-\(won ? "win" : "loss")-reduced-\(reduced)"
            a.lifetime = .keepAlways; add(a)
            let exitAt = ProcessInfo.processInfo.systemUptime
            if width == 402 { model.home() }
            else if won { model.next() }
            else { model.restart() }
            if width == 402 { XCTAssertEqual(model.screen, .home) }
            else {
                XCTAssertEqual(model.session?.status, .playing)
                XCTAssertEqual(model.session?.puzzle.id, won ? 7 : 6)
            }
            // After leaving, the departing decoration must not own interaction.
            try await Task.sleep(nanoseconds: 60_000_000)
            let target = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
            let hit = try XCTUnwrap(window.hitTest(target, with: nil))
            var ancestors: [UIView] = []; var current: UIView? = hit
            while let view = current { ancestors.append(view); current = view.superview }
            func controllers(_ controller: UIViewController) -> [UIViewController] {
                [controller] + controller.children.flatMap(controllers)
            }
            let resultOwners = controllers(host).filter {
                String(describing: type(of: $0)).hasPrefix("CapyAccessibilityController<") &&
                String(describing: type(of: $0)).contains("ResultPanel")
            }
            for owner in resultOwners {
                XCTAssertFalse(owner.view.isUserInteractionEnabled)
                XCTAssertTrue(owner.view.accessibilityElementsHidden)
                XCTAssertFalse(ancestors.contains(where: { $0 === owner.view }))
            }
            samples[samples.count - 1]["exitAtUptime"] = exitAt
            samples[samples.count - 1]["exitAction"] = width == 402 ? "home" : won ? "next" : "restart"
            samples[samples.count - 1]["retainedDecorationOwners"] = resultOwners.count
            try await Task.sleep(nanoseconds: 350_000_000)
            let exitImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            let exitAttachment = XCTAttachment(image: exitImage)
            exitAttachment.name = "result-exit-\(width)-\(won ? "win" : "loss")-reduced-\(reduced)"
            exitAttachment.lifetime = .keepAlways; add(exitAttachment)
        }
        let data = try JSONSerialization.data(withJSONObject: ["samples": samples,
            "boundary": "Actual Root normal/compact viewport, native board.activate and normal/reduced motion. No entrance screenshots; final screenshots only. Layout observation does not prove first rendered frame, physical touch latency or exact reference timing."], options: [.prettyPrinted, .sortedKeys])
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        a.name = "result-handoff-event-times"; a.lifetime = .keepAlways; add(a)
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private func layers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(layers)
    }

    /// Real late-board scenes for proximity and rapid score replacement review.
    /// Final snapshots occur after the moving interval; these are broad phases,
    /// not a frame-rate or precise callback-latency benchmark.
    @MainActor func testDenseLocalScoresInActualRootStayAssociatedAndReadable() async throws {
        var samples: [[String: Any]] = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (level, reduced) in [(6, true), (6, false), (111, true), (111, false), (101, true), (101, false)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dense-score-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true; model.start(level: level)
            let originalSolution = try XCTUnwrap(model.session).puzzle.solution
            // Reverse L101 leaves its top-left corner until last, reproducing
            // the current pack's most distant compact-board score placement.
            let solution = level == 101 ? Array(originalSolution.reversed()) : originalSolution
            let pending = level == 6 ? 2 : 1
            for index in solution.dropLast(pending) { model.submit(index) }
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            let surround = UIWindow(windowScene: scene); surround.frame = scene.coordinateSpace.bounds
            let backdrop = UIViewController(); backdrop.view.backgroundColor = .black
            surround.rootViewController = backdrop; surround.windowLevel = UIWindow.Level(rawValue: 1)
            surround.isHidden = false; window.windowLevel = UIWindow.Level(rawValue: 2)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
            var frames: [String: CGRect] = [:]
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model)
                .environment(\.scenePhase, .active).environment(\.capyLayoutObserver, { frames[$0] = $1 }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil
                surround.isHidden = true; surround.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
            let initial = try XCTUnwrap(model.session), boardFrame = try XCTUnwrap(frames["puzzle_board"])
            let elements = try XCTUnwrap(board.accessibilityElements as? [UIAccessibilityElement])
            let cells = elements.map { board.convert($0.accessibilityFrameInContainerSpace, to: window) }
            var lastAmount = 0
            for index in solution.suffix(pending) {
                let oldScore = model.session!.score
                XCTAssertTrue(board.activate(index: index, submit: true))
                lastAmount = model.session!.score - oldScore
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            for _ in 0..<10 where frames["local_score_\(lastAmount)"] == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let badge = try XCTUnwrap(frames["local_score_\(lastAmount)"]), source = cells[solution.last!]
            samples.append(["level": level, "reduced": reduced, "amount": lastAmount,
                "sourceFrame": NSCoder.string(for: source), "labelFrame": NSCoder.string(for: badge),
                "centerDistanceInCells": hypot(badge.midX - source.midX, badge.midY - source.midY) / source.width])
            XCTAssertEqual(model.session?.status, .won); XCTAssertEqual(model.session?.found, Set(solution))
            XCTAssertEqual(model.session?.lives, initial.lives)
            XCTAssertEqual(frames["puzzle_board"], boardFrame)
            let scoreBand = CGRect(x: 14, y: boardFrame.minY, width: window.bounds.width - 28, height: boardFrame.height)
            XCTAssertTrue(scoreBand.contains(badge), "Use only measured horizontal board margins, never the controls above or below.")
            for key in ["rule_strip", "game_footer"] {
                XCTAssertFalse(badge.intersects(try XCTUnwrap(frames[key])))
            }
            if level == 101 {
                XCTAssertLessThan(hypot(badge.midX - source.midX, badge.midY - source.midY) / source.width, 2,
                    "The real compact corner score must stay associated with its source instead of crossing three or four columns.")
            }
            for cell in cells.enumerated() where solution.contains(cell.offset) {
                XCTAssertFalse(badge.intersects(cell.element), "Latest score must not cover any character.")
            }
            let accepted = model.session
            model.submit(solution.last!); XCTAssertEqual(model.session, accepted)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            let a = XCTAttachment(image: image); a.name = "dense-score-L\(level)-reduced-\(reduced)"
            a.lifetime = .keepAlways; add(a)
        }
        let data = try JSONSerialization.data(withJSONObject: ["samples": samples,
            "boundary": "Real Root320x568 viewport;150ms requested intervals and final layout observations. Static reduced-motion collisions and natural final-flight frames are visually reviewed; no compositor phase or actual input latency is inferred."], options: [.prettyPrinted, .sortedKeys])
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        a.name = "dense-score-root-geometry"; a.lifetime = .keepAlways; add(a)
    }

    @MainActor func testLocalScoreFitsActualRootWithoutCoveringItsCharacterAtBoardEdges() async throws {
        var samples: [[String: Any]] = []
        for (width, level, reduced) in [(CGFloat(402), 6, false), (CGFloat(320), 101, false), (CGFloat(320), 101, true), (CGFloat(320), 47, false)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("score-placement-" + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true; model.start(level: level)
            if level == 47 {
                for index in try XCTUnwrap(model.session).puzzle.solution.dropLast() { model.submit(index) }
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: width == 320 ? 568 : 874)
            var frames: [String: CGRect] = [:]
            var firstLayoutTimes: [String: TimeInterval] = [:]
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model)
                .environment(\.scenePhase, .active)
                .environment(\.capyLayoutObserver, { key, frame in
                    frames[key] = frame
                    if key.hasPrefix("local_score"), firstLayoutTimes[key] == nil {
                        firstLayoutTimes[key] = ProcessInfo.processInfo.systemUptime
                    }
                }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
            let initial = try XCTUnwrap(model.session), boardBefore = try XCTUnwrap(frames["puzzle_board"])
            let elements = try XCTUnwrap(board.accessibilityElements as? [UIAccessibilityElement])
            let measured = elements.map { board.convert($0.accessibilityFrameInContainerSpace, to: window) }
            let indices = level == 47 ? [try XCTUnwrap(initial.puzzle.solution.last)] : [try XCTUnwrap(initial.puzzle.solution.first), initial.puzzle.solution[1], try XCTUnwrap(initial.puzzle.solution.last)]
            for (step, index) in indices.enumerated() {
                let prior = try XCTUnwrap(model.session)
                let submittedAt = ProcessInfo.processInfo.systemUptime
                XCTAssertTrue(board.activate(index: index, submit: true))
                let accepted = try XCTUnwrap(model.session), amount = accepted.score - prior.score
                XCTAssertGreaterThan(amount, 0)
                try await Task.sleep(nanoseconds: 120_000_000)
                // Read the laid-out badge after its asynchronous accepted-event
                // delivery; the initial 120ms sleep is not a compositor clock.
                for _ in 0..<15 where frames["local_score_\(amount)"] == nil {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                if frames["local_score_\(amount)"] == nil {
                    let full = measured.reduce(CGRect.null) { $0.union($1) }
                    let attempt = CellScorePlacement.anchored(amount: amount, cellFrame: measured[index], boardFrame: full,
                                                              avoiding: accepted.found.map { measured[$0] })
                    let diagnostic: [String: Any] = ["level": level, "amount": amount, "index": index,
                        "board": NSCoder.string(for: full), "source": NSCoder.string(for: measured[index]),
                        "found": accepted.found.sorted(), "layoutPossible": attempt != nil,
                        "observedLabels": frames.keys.filter { $0.hasPrefix("local_score") },
                        "notice": model.notice ?? "", "error": model.errorMessage ?? ""]
                    let data = try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
                    let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    a.name = "local-score-missing-diagnostic"; a.lifetime = .keepAlways; add(a)
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
                    let shot = XCTAttachment(image: image); shot.name = "local-score-missing-root"; shot.lifetime = .keepAlways; add(shot)
                }
                let label = try XCTUnwrap(frames["local_score_\(amount)"])
                samples.append(["level": level, "width": width, "reduced": reduced, "cell": index, "amount": amount,
                    "layoutObservedAfterSubmissionMs": (try XCTUnwrap(firstLayoutTimes["local_score_\(amount)"]) - submittedAt) * 1000,
                    "beforeCaptureAfterSubmissionMs": (ProcessInfo.processInfo.systemUptime - submittedAt) * 1000])
                let cell = measured[index]
                XCTAssertFalse(label.intersects(cell), "The complete laid-out score badge must leave the accepted character visible.")
                for found in accepted.found {
                    let foundCell = measured[found]
                    XCTAssertFalse(label.intersects(foundCell), "The new badge must also preserve earlier characters.")
                }
                let scoreBand = CGRect(x: 14, y: boardBefore.minY, width: window.bounds.width - 28, height: boardBefore.height)
                XCTAssertTrue(scoreBand.contains(label), "Only side whitespace is available; do not spill into rules, Combo or tools.")
                for key in ["rule_strip", "game_footer"] {
                    XCTAssertFalse(label.intersects(try XCTUnwrap(frames[key])))
                }
                XCTAssertGreaterThan(label.width, 20); XCTAssertGreaterThanOrEqual(label.height, 22)
                XCTAssertLessThanOrEqual(label.height, 28.5)
                XCTAssertEqual(frames["puzzle_board"], boardBefore)
                XCTAssertEqual(model.session, accepted)
                XCTAssertEqual(accepted.lives, initial.lives)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                let a = XCTAttachment(image: image)
                a.name = "local-score-L\(level)-\(Int(width))pt-reduced-\(reduced)-\(level == 47 ? "final" : step == 0 ? "top" : step == 1 ? "nearby" : "bottom")"
                a.lifetime = .keepAlways; add(a)
                // The second source arrives before the first badge's 0.72s
                // cleanup; no forced clock or animation seek is involved.
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            try await Task.sleep(nanoseconds: 800_000_000)
            XCTAssertEqual(model.session?.found, initial.found.union(indices))
        }
        let data = try JSONSerialization.data(withJSONObject: ["samples": samples,
            "boundary": "Process-relative layout-observer timings are not visible frame or touch latency measurements; snapshots are taken afterward. Initial120ms wait is followed by up to300ms for async layout."], options: [.prettyPrinted, .sortedKeys])
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        a.name = "local-score-root-layout-timing"; a.lifetime = .keepAlways; add(a)
    }

    @MainActor func testCurrentLevelSixRootCapturesHappyScoreAndVisibleConflictWithoutChangingCommittedGame() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hud-current-pack-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.settings.language = .simplifiedChinese
        model.progress.tutorialCompleted = true
        model.start(level: 6)
        let initial = try XCTUnwrap(model.session)
        XCTAssertEqual(initial.puzzle.id, 6)
        XCTAssertEqual(initial.status, .playing)
        XCTAssertGreaterThan(initial.lives, 1)
        XCTAssertTrue(initial.found.isEmpty)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        var frames: [String: CGRect] = [:]
        let host = UIHostingController(rootView: RootView(reduceMotionOverride: false)
            .environmentObject(model).environment(\.scenePhase, .active)
            .environment(\.capyLayoutObserver, { frames[$0] = $1 }))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
            model.flushPendingSaves()
            try? FileManager.default.removeItem(at: directory)
        }
        func capture(_ name: String) throws {
            var drawn = false
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                drawn = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
            }
            XCTAssertTrue(drawn)
            XCTAssertGreaterThan(Set(try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data).count, 16)
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        let board = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PuzzleGridUIView }.first)
        let solutionCell = try XCTUnwrap(initial.puzzle.solution.first)
        model.submit(solutionCell)
        let accepted = try XCTUnwrap(model.session)
        XCTAssertEqual(accepted.found, [solutionCell])
        XCTAssertGreaterThan(accepted.score, initial.score)
        XCTAssertEqual(accepted.lives, initial.lives)
        try await Task.sleep(nanoseconds: 120_000_000)
        let happy = try XCTUnwrap(descendants(board).compactMap { $0 as? BoardCellFeedbackView }
            .first { $0.cellIndex == solutionCell && $0.kind == .found })
        let happyFace = try XCTUnwrap(layers(happy.layer).first { $0.name == "found-face-happy" })
        let happyImage = try XCTUnwrap(happyFace.presentation()?.contents) as AnyObject
        XCTAssertTrue(happyImage === CapyExpressionArtwork.image(.happy)?.cgImage)
        try capture("current-level-6-happy-local-score-120ms")
        XCTAssertEqual(model.session, accepted, "Happy artwork and local score text only acknowledge the accepted move.")

        try await Task.sleep(nanoseconds: 700_000_000)
        let wrongCell = try XCTUnwrap(initial.puzzle.regions.indices.first { cell in
            !initial.puzzle.solution.contains(cell) && !VisibleConflictAnalysis.conflicts(
                size: initial.puzzle.size, regions: initial.puzzle.regions,
                candidate: cell, found: accepted.found).isEmpty
        })
        let expected = VisibleConflictAnalysis.conflicts(size: initial.puzzle.size,
            regions: initial.puzzle.regions, candidate: wrongCell, found: accepted.found)
        model.submit(wrongCell)
        let mistaken = try XCTUnwrap(model.session)
        XCTAssertEqual(mistaken.lives, accepted.lives - 1)
        XCTAssertEqual(mistaken.found, accepted.found)
        XCTAssertEqual(mistaken.score, accepted.score)
        XCTAssertTrue(mistaken.errors.contains(wrongCell))
        model.submit(wrongCell)
        XCTAssertEqual(model.session, mistaken, "A duplicated delivery cannot deduct life again while feedback is starting.")

        try await Task.sleep(nanoseconds: 120_000_000)
        let conflict = try XCTUnwrap(descendants(board).compactMap { $0 as? BoardConflictFeedbackView }.first)
        XCTAssertEqual(conflict.candidate, wrongCell)
        XCTAssertEqual(conflict.conflicts, expected)
        XCTAssertEqual(conflict.connections.count, expected.count)
        XCTAssertFalse(conflict.isUserInteractionEnabled)
        XCTAssertTrue(descendants(board).compactMap { $0 as? BoardMistakeFeedbackView }.contains { $0.cellIndex == wrongCell })
        let rulesFrame = try XCTUnwrap(frames["rule_strip"])
        let livesFrame = try XCTUnwrap(frames["lives"])
        let boardFrame = try XCTUnwrap(frames["puzzle_board"])
        XCTAssertGreaterThan(rulesFrame.height, 0)
        XCTAssertGreaterThan(livesFrame.height, 0)
        XCTAssertLessThanOrEqual(rulesFrame.maxY, boardFrame.minY)
        XCTAssertLessThan(livesFrame.maxY, boardFrame.minY)
        try capture("current-level-6-rules-links-heart-loss-120ms")
        XCTAssertEqual(model.session, mistaken)

        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertTrue(descendants(board).compactMap { $0 as? BoardConflictFeedbackView }.isEmpty)
        XCTAssertTrue(descendants(board).compactMap { $0 as? BoardMistakeFeedbackView }.isEmpty)
        XCTAssertEqual(model.session, mistaken, "Animation completion must not alter the answer, score, life or marks.")
        XCTAssertEqual(model.session?.puzzle, initial.puzzle, "This capture uses the current packaged level without a fixture substitution.")
        try capture("current-level-6-conflict-settled-no-extra-deduction")
    }
}
