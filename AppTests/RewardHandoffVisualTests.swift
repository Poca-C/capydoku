import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

private final class HandoffManualRewardProvider: RewardProvider {
    private(set) var offers: [String] = []
    var completion: ((RewardSignal) -> Void)?
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) {
        offers.append(offerID); self.completion = completion
    }
}

/// Real Root evidence on its running animation clock. The fixture's warm face
/// center detects a material modal veil over the accepted answer, not art quality.
final class RewardHandoffVisualTests: XCTestCase {
    @MainActor private func views(_ view: UIView, path: String = "window") -> [(UIView, String)] {
        [(view, path)] + view.subviews.enumerated().flatMap {
            views($0.element, path: path + "/\($0.offset):\(String(describing: type(of: $0.element)))")
        }
    }

    private func rectValues(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }

    private func pixelSummary(_ image: CGImage) throws -> [String: Any] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: memory.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        XCTAssertTrue(rendered)
        var sums = [Double](repeating: 0, count: 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<4 { sums[channel] += Double(bytes[index + channel]) }
        }
        let count = max(1, image.width * image.height)
        let center = ((image.height / 2) * image.width + image.width / 2) * 4
        return ["pixelWidth": image.width, "pixelHeight": image.height,
                "meanPremultipliedSRGBA0To255": sums.map { $0 / Double(count) },
                "centerPremultipliedSRGBA0To255": Array(bytes[center..<(center + 4)]),
                "boundary": "Native-window pixels; the known brown face center is checked only against modal coverage."]
    }

    @MainActor func testActualRootRewardCoverBlocksThenReleasesTheSameBoardHitTarget() async throws {
        try await BundledStartupResources().prepare()
        for reduced in [false, true] {
            let name = "reward-hit-handoff-402-reduced-\(reduced)"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name + UUID().uuidString)
            let provider = HandoffManualRewardProvider()
            let model = AppModel(saveDirectory: directory, rewardProvider: provider, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true
            model.config = DemoConfig(directPerLevel: 0)
            model.start(level: 6)
            let before = try XCTUnwrap(model.session)
            let puzzle = before.puzzle
            let middle = Double(puzzle.size - 1) / 2
            let emptyCell = try XCTUnwrap(puzzle.regions.indices.filter {
                !puzzle.solution.contains($0) && !before.marks.contains($0) && !before.errors.contains($0)
            }.min {
                let lhs = abs(Double($0 / puzzle.size) - middle) + abs(Double($0 % puzzle.size) - middle)
                let rhs = abs(Double($1 / puzzle.size) - middle) + abs(Double($1 % puzzle.size) - middle)
                return lhs == rhs ? $0 < $1 : lhs < rhs
            })
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model)
                .environment(\.scenePhase, .active))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            func drainQueuedCallback() async {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
            try await Task.sleep(nanoseconds: 620_000_000)
            let board = try XCTUnwrap(views(window).compactMap { $0.0 as? PuzzleGridUIView }.first)
            let cell = try XCTUnwrap(board.accessibilityElements?[emptyCell] as? UIAccessibilityElement)
            let frame = board.convert(cell.accessibilityFrameInContainerSpace, to: window)
            let point = CGPoint(x: frame.midX, y: frame.midY)
            func reachesBoard(_ hit: UIView?) -> Bool { hit === board || hit?.isDescendant(of: board) == true }
            func pathForHit(_ hit: UIView?) -> String {
                guard let hit else { return "nil" }
                return views(window).first { $0.0 === hit }?.1 ?? String(describing: type(of: hit))
            }
            let initialHit = window.hitTest(point, with: nil)
            XCTAssertTrue(reachesBoard(initialHit), "The chosen real empty cell must receive window hits before the reward.")
            model.offer(.direct)
            await drainQueuedCallback()
            let complete = try XCTUnwrap(provider.completion)
            XCTAssertEqual(provider.offers.count, 1)
            complete(.started)
            await drainQueuedCallback()
            try await Task.sleep(nanoseconds: 240_000_000)
            XCTAssertTrue(model.rewardBusy); XCTAssertEqual(model.sheet, .reward)
            let busyHit = window.hitTest(point, with: nil)
            XCTAssertNotNil(busyHit)
            XCTAssertFalse(reachesBoard(busyHit), "A visible, busy reward must intercept the actual window hit above the board.")
            XCTAssertEqual(model.session, before)
            let busyPath = pathForHit(busyHit)

            let started = CACurrentMediaTime()
            complete(.earned)
            await drainQueuedCallback()
            let committedAt = CACurrentMediaTime() - started
            let accepted = try XCTUnwrap(model.session)
            XCTAssertEqual(accepted.id, before.id); XCTAssertEqual(accepted.status, .playing)
            XCTAssertEqual(accepted.found.subtracting(before.found).count, 1)
            XCTAssertEqual(accepted.marks, before.marks); XCTAssertEqual(accepted.errors, before.errors)
            XCTAssertEqual(accepted.lives, before.lives); XCTAssertGreaterThan(accepted.score, before.score)
            XCTAssertFalse(accepted.found.contains(emptyCell), "The hit target stays an ordinary empty cell after the random correct reveal.")
            XCTAssertNil(model.sheet); XCTAssertFalse(model.rewardBusy)

            var observations: [[String: Any]] = []
            for requested in [0.030, 0.120] {
                let wait = max(0, requested - (CACurrentMediaTime() - started))
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                let elapsed = CACurrentMediaTime() - started
                let hit = window.hitTest(point, with: nil)
                let reached = reachesBoard(hit)
                observations.append(["requestedSeconds": requested, "observedSeconds": elapsed,
                    "hitPath": pathForHit(hit), "reachesBoard": reached])
                if requested == 0.120 {
                    XCTAssertTrue(reached, "\(name): the retiring reward container must release the same actual board hit target by the 120ms observation.")
                    let elements = board.accessibilityElements ?? []
                    let current = elements.indices.contains(emptyCell) ? elements[emptyCell] as? UIAccessibilityElement : nil
                    XCTAssertNotNil(current, "The released board must also restore its cell accessibility.")
                    if let current {
                        let currentFrame = board.convert(current.accessibilityFrameInContainerSpace, to: window)
                        XCTAssertEqual(currentFrame.midX, point.x, accuracy: 0.5)
                        XCTAssertEqual(currentFrame.midY, point.y, accuracy: 0.5)
                    }
                }
                XCTAssertEqual(model.session, accepted, "Hit testing inspects routing without injecting a touch or mutating play.")
            }
            let report: [String: Any] = ["fixture": name, "targetCell": emptyCell,
                "targetFrameInWindow": rectValues(frame), "busyHitPath": busyPath,
                "businessCommitObservedAfterSeconds": committedAt, "observations": observations,
                "boundary": "Actual UIWindow.hitTest at the same measured empty cell. No gesture injection, screenshots, forced layout or CA clock changes. 30ms is diagnostic; 120ms requires board routing."
            ]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                uniformTypeIdentifier: "public.json")
            attachment.name = name + "-actual-window-hit-routing"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    @MainActor func testActualRootDenseMarkedDirectRunsContinuouslyForVideoReview() async throws {
        try await BundledStartupResources().prepare()
        let sequenceStarted = CACurrentMediaTime()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for width in [402, 320] {
            let name = "dense-inventory-direct-L101-\(width)-normal"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name + UUID().uuidString)
            let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true
            model.config = DemoConfig(directPerLevel: 1)
            model.start(level: 101)
            let puzzle = try XCTUnwrap(model.session).puzzle
            XCTAssertEqual(puzzle.size, 10, "This fixture must exercise the actual bundled L101, not a generated replacement.")
            // Leave the three uppermost answers so the real inventory tool
            // travels through a long, densely marked portion of this board.
            let remaining = Set(puzzle.solution.sorted().prefix(3))
            for cell in puzzle.solution where !remaining.contains(cell) { model.submit(cell) }
            let ordinaryCells = puzzle.regions.indices.filter { !puzzle.solution.contains($0) }
            let liveMark = try XCTUnwrap(ordinaryCells.last)
            for cell in ordinaryCells where cell != liveMark { model.toggle(cell) }
            let before = try XCTUnwrap(model.session)
            XCTAssertEqual(before.puzzle.id, 101); XCTAssertEqual(before.status, .playing)
            XCTAssertEqual(before.found.count, puzzle.size - 3)
            XCTAssertEqual(before.marks.count, ordinaryCells.count - 1)
            XCTAssertEqual(model.progress.availableDirect, 1)

            let previous = scene.windows.first(where: \.isKeyWindow)
            let surround = UIWindow(windowScene: scene); surround.frame = scene.coordinateSpace.bounds
            let backdrop = UIViewController(); backdrop.view.backgroundColor = .black
            surround.rootViewController = backdrop; surround.windowLevel = UIWindow.Level(rawValue: 1)
            surround.isHidden = false
            let window = UIWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: 2); window.overrideUserInterfaceStyle = .light
            window.frame = CGRect(x: 0, y: 0, width: width, height: width == 320 ? 568 : 874)
            var layout = [String: CGRect]()
            let host = UIHostingController(rootView: RootView(reduceMotionOverride: false).environmentObject(model)
                .environment(\.scenePhase, .active).environment(\.capyLayoutObserver, { layout[$0] = $1 }))
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds
            defer {
                model.setActive(false)
                window.isHidden = true; window.rootViewController = nil
                surround.isHidden = true; surround.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            var events = [[String: Any]]()
            func record(_ event: String) {
                events.append(["event": event, "secondsFromSequenceStart": CACurrentMediaTime() - sequenceStarted,
                    "found": model.session?.found.sorted() ?? [], "markCount": model.session?.marks.count ?? -1,
                    "score": model.session?.score ?? -1, "inventory": model.progress.availableDirect])
            }
            try await Task.sleep(nanoseconds: 620_000_000)
            record("dense-board-settled")
            let board = try XCTUnwrap(views(window).compactMap { $0.0 as? PuzzleGridUIView }.first)
            let boardFrame = board.convert(board.bounds, to: window)
            var remainingFrames = [String: [Double]]()
            for index in remaining.sorted() {
                let element = try XCTUnwrap(board.accessibilityElements?[index] as? UIAccessibilityElement)
                remainingFrames[String(index)] = rectValues(board.convert(element.accessibilityFrameInContainerSpace, to: window))
            }

            let directStarted = CACurrentMediaTime()
            record("inventory-direct-request")
            model.direct()
            let accepted = try XCTUnwrap(model.session)
            let receipt = try XCTUnwrap(model.directRevealFeedback)
            let added = accepted.found.subtracting(before.found)
            XCTAssertEqual(added, [receipt.cell]); XCTAssertTrue(remaining.contains(receipt.cell))
            XCTAssertEqual(receipt.sessionID, before.id); XCTAssertEqual(accepted.id, before.id)
            XCTAssertEqual(accepted.status, .playing); XCTAssertEqual(accepted.marks, before.marks)
            XCTAssertEqual(accepted.errors, before.errors); XCTAssertEqual(accepted.lives, before.lives)
            XCTAssertGreaterThan(accepted.score, before.score); XCTAssertEqual(model.progress.availableDirect, 0)
            record("inventory-direct-committed")

            // Leave the natural animation clock and compositor undisturbed.
            // These native accessibility actions check input while it runs;
            // they do not read back pixels or force presentation-layer phases.
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(nativeBoardAcceptsMark(board, index: liveMark))
            XCTAssertTrue(try XCTUnwrap(model.session).marks.contains(liveMark))
            record("native-mark-during-direct")
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(nativeBoardAcceptsMark(board, index: liveMark))
            XCTAssertEqual(model.session, accepted)
            record("native-undo-during-direct")
            try await Task.sleep(nanoseconds: 650_000_000)
            XCTAssertEqual(model.session, accepted)
            XCTAssertTrue(views(window).allSatisfy { !($0.0 is DirectToolRevealUIView) }, "The dense-board receipt must clean up normally.")
            record("direct-natural-playback-finished")

            let nextAnimal = try XCTUnwrap(puzzle.solution.first { !accepted.found.contains($0) })
            XCTAssertTrue(board.activate(index: nextAnimal, submit: true))
            let continued = try XCTUnwrap(model.session)
            XCTAssertEqual(continued.id, accepted.id); XCTAssertEqual(continued.status, .playing)
            XCTAssertEqual(continued.found, accepted.found.union([nextAnimal]))
            XCTAssertEqual(continued.marks, accepted.marks); XCTAssertEqual(continued.lives, accepted.lives)
            XCTAssertEqual(model.progress.availableDirect, 0)
            record("next-native-correct-accepted")
            try await Task.sleep(nanoseconds: 760_000_000)
            XCTAssertEqual(model.session, continued)
            record("settled-before-only-image-readback")

            let report: [String: Any] = ["fixture": name, "level": 101, "boardSize": puzzle.size,
                "screenSize": [width, width == 320 ? 568 : 874], "initialFound": before.found.sorted(),
                "initialMarks": before.marks.sorted(), "remainingUpperCells": remaining.sorted(),
                "revealedCell": receipt.cell, "liveMarkCell": liveMark,
                "boardFrameInWindow": rectValues(boardFrame), "remainingCellFramesInWindow": remainingFrames,
                "rootMeasuredFrames": layout.mapValues { rectValues($0) }, "events": events,
                "directSequenceObservedSeconds": CACurrentMediaTime() - directStarted,
                "boundary": "Real Root, bundled L101 and production inventory Direct. The in-flight mark/undo and later correct input use the native board accessibility entry point, not physical touches. Natural normal-motion playback; no image readback, CA freeze or forced layout during the tool acknowledgement. Business assertions do not grade magnifier visibility/continuity; review the external continuous recording. Audio is disabled and no device/FPS/parity claim is made."]
            let diagnostic = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                uniformTypeIdentifier: "public.json")
            diagnostic.name = name + "-natural-events-and-geometry"; diagnostic.lifetime = .keepAlways; add(diagnostic)
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale; format.preferredRange = .standard
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            XCTAssertTrue(rendered)
            let stableImage = XCTAttachment(image: image)
            stableImage.name = name + "-settled-after-next-correct"; stableImage.lifetime = .keepAlways; add(stableImage)
        }
    }

    @MainActor private func nativeBoardAcceptsMark(_ board: PuzzleGridUIView, index: Int) -> Bool {
        board.activate(index: index, submit: false)
    }

    @MainActor func testActualRootRewardToMidBoardDirectRecordsNaturalHandoffAndInventoryControl() async throws {
        try await BundledStartupResources().prepare()
        for (width, height, reduced) in [(402, 874, false), (320, 568, false), (402, 874, true), (320, 568, true)] {
        for rewarded in [true, false] {
            let name = (rewarded ? "reward-handoff" : "inventory-control") + "-L6-\(width)-" + (reduced ? "reduced" : "normal")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name + UUID().uuidString)
            let provider = HandoffManualRewardProvider()
            let model = AppModel(saveDirectory: directory, rewardProvider: provider, runsTimer: false, feedbackEnabled: false)
            model.progress.tutorialCompleted = true
            model.config = DemoConfig(directPerLevel: rewarded ? 0 : 1)
            model.start(level: 6)
            let puzzle = try XCTUnwrap(model.session).puzzle
            let middleRow = Double(puzzle.size - 1) / 2
            let remaining = Set(puzzle.solution.sorted {
                let lhs = abs(Double($0 / puzzle.size) - middleRow)
                let rhs = abs(Double($1 / puzzle.size) - middleRow)
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }.prefix(2))
            XCTAssertEqual(remaining.count, 2)
            for cell in puzzle.solution where !remaining.contains(cell) { model.submit(cell) }
            // Retain ordinary player marks as a visible/business control.
            for cell in puzzle.regions.indices.filter({ !puzzle.solution.contains($0) }).prefix(2) { model.toggle(cell) }
            let before = try XCTUnwrap(model.session)
            XCTAssertEqual(before.status, .playing)
            XCTAssertEqual(before.found.count, puzzle.size - 2, "The reward must not enter victory choreography.")
            XCTAssertEqual(model.progress.availableDirect, rewarded ? 0 : 1)

            let host = UIHostingController(rootView: RootView(reduceMotionOverride: reduced).environmentObject(model)
                .environment(\.scenePhase, .active))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds
            defer {
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                model.flushPendingSaves(); try? FileManager.default.removeItem(at: directory)
            }
            try await Task.sleep(nanoseconds: 620_000_000)
            let board = try XCTUnwrap(views(window).compactMap { $0.0 as? PuzzleGridUIView }.first)
            let initialCellFrames = try Dictionary(uniqueKeysWithValues: remaining.sorted().map { index in
                let element = try XCTUnwrap(board.accessibilityElements?[index] as? UIAccessibilityElement)
                return (index, element.accessibilityFrameInContainerSpace)
            })

            func windowImage(_ label: String, attachImmediately: Bool = true) -> UIImage {
                let format = UIGraphicsImageRendererFormat()
                format.scale = window.screen.scale; format.preferredRange = .standard
                var rendered = false
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                XCTAssertTrue(rendered, "Evidence must come from the actual window.")
                if attachImmediately {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = name + "-" + label; attachment.lifetime = .keepAlways; add(attachment)
                }
                return image
            }
            func drainAlreadyQueuedRewardCallback() async {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }

            var earnedCallback: ((RewardSignal) -> Void)?
            var offerID: String?
            if rewarded {
                model.offer(.direct) // Production offer automatically runs the provider.
                await drainAlreadyQueuedRewardCallback()
                XCTAssertEqual(provider.offers.count, 1)
                offerID = try XCTUnwrap(provider.offers.first)
                earnedCallback = try XCTUnwrap(provider.completion)
                XCTAssertTrue(model.rewardBusy); XCTAssertEqual(model.sheet, .reward)
                XCTAssertEqual(model.session, before)
                try await Task.sleep(nanoseconds: 260_000_000)
                earnedCallback?(.started)
                await drainAlreadyQueuedRewardCallback()
                try await Task.sleep(nanoseconds: 60_000_000)
                _ = windowImage("stable-simulated-reward-before-earned")
            } else {
                _ = windowImage("playing-before-inventory-direct")
            }

            let started = CACurrentMediaTime()
            if rewarded {
                earnedCallback?(.earned)
                // Drain the production adapter's async delivery; never wait
                // for the card, board feedback or any visual timer to finish.
                await drainAlreadyQueuedRewardCallback()
            } else { model.direct() }
            let committedAt = CACurrentMediaTime() - started
            let accepted = try XCTUnwrap(model.session)
            let added = accepted.found.subtracting(before.found)
            XCTAssertEqual(added.count, 1)
            let target = try XCTUnwrap(added.first)
            XCTAssertTrue(remaining.contains(target))
            XCTAssertEqual(accepted.status, .playing)
            XCTAssertEqual(accepted.lives, before.lives); XCTAssertEqual(accepted.marks, before.marks)
            XCTAssertEqual(accepted.errors, before.errors); XCTAssertGreaterThan(accepted.score, before.score)
            XCTAssertFalse(model.rewardBusy); XCTAssertNil(model.sheet)
            XCTAssertEqual(model.progress.availableDirect, 0, "The received reward executes once rather than accumulating inventory.")
            XCTAssertEqual(model.directRevealFeedback?.cell, target)
            let acceptedProgress = model.progress
            if let offerID { XCTAssertEqual(model.progress.rewardLedger[offerID]?.state, .executed) }

            var observations: [[String: Any]] = []
            var pendingImages: [(String, UIImage)] = []
            for requested in [0.120, 0.220] {
                let wait = max(0, requested - (CACurrentMediaTime() - started))
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                let captureStart = CACurrentMediaTime() - started
                // The retiring modal may still hide board accessibility on an
                // early render. Preserve measured board-local geometry rather
                // than making accessibility exposure a visibility assertion.
                let elements = board.accessibilityElements ?? []
                let currentCell = elements.indices.contains(target) ? elements[target] as? UIAccessibilityElement : nil
                let localFrame = try XCTUnwrap(currentCell?.accessibilityFrameInContainerSpace ?? initialCellFrames[target])
                let targetFrame = board.convert(localFrame, to: window)
                let effectViews: [[String: Any]] = views(window).compactMap { view, path in
                    guard view is BoardCellFeedbackView || view is DirectToolRevealUIView else { return nil }
                    let presentation = view.layer.presentation()
                    var row: [String: Any] = ["path": path, "frameInWindow": rectValues(view.convert(view.bounds, to: window)),
                        "hidden": view.isHidden, "viewAlpha": Double(view.alpha),
                        "layerOpacity": Double(presentation?.opacity ?? view.layer.opacity),
                        "layerHasPresentation": presentation != nil,
                        "animationKeys": view.layer.animationKeys() ?? [],
                        "childAnimationKeys": (view.layer.sublayers ?? []).flatMap { $0.animationKeys() ?? [] }]
                    if let feedback = view as? BoardCellFeedbackView {
                        row["cell"] = feedback.cellIndex; row["kind"] = String(describing: feedback.kind)
                    }
                    return row
                }
                let label = "requested-\(Int(requested * 1_000))ms-actual-\(Int(captureStart * 1_000))ms"
                let image = windowImage(label, attachImmediately: false)
                let captureEnd = CACurrentMediaTime() - started
                let bitmap = try XCTUnwrap(image.cgImage)
                let crop = CGRect(x: floor(targetFrame.minX * image.scale), y: floor(targetFrame.minY * image.scale),
                    width: ceil(targetFrame.maxX * image.scale) - floor(targetFrame.minX * image.scale),
                    height: ceil(targetFrame.maxY * image.scale) - floor(targetFrame.minY * image.scale))
                let targetPixels = try XCTUnwrap(bitmap.cropping(to: crop))
                let pixelReport = try pixelSummary(targetPixels)
                if requested == 0.120 {
                    // Do not accept a late screenshot as proof of early handoff.
                    XCTAssertLessThan(captureStart, 0.180, "The early observation missed its bounded window.")
                    let center = try XCTUnwrap(pixelReport["centerPremultipliedSRGBA0To255"] as? [UInt8])
                    // Both remaining targets have a brown character at their
                    // center in all four fixtures. The opaque cream reward card
                    // (or a card under its own gray scrim) fails this check.
                    XCTAssertGreaterThan(Int(center[0]) - Int(center[2]), 60,
                        "The accepted character is still hidden by the retiring reward card.")
                    XCTAssertGreaterThan(Int(center[1]), 90, "The target is still covered by the dark modal scrim.")
                }
                pendingImages.append((label, image))
                pendingImages.append((label + "-same-window-target-crop",
                    UIImage(cgImage: targetPixels, scale: image.scale, orientation: .up)))
                observations.append(["requestedSeconds": requested, "captureStartedAfterSeconds": captureStart,
                    "captureEndedAfterSeconds": captureEnd, "targetCell": target,
                    "targetFrameInWindow": rectValues(targetFrame), "cropNativePixels": rectValues(crop),
                    "cellGeometrySource": currentCell == nil ? "pre-modal real board measurement" : "current real board measurement",
                    "targetWindowPixels": pixelReport, "actualFeedbackViews": effectViews,
                    "modelSheet": model.sheet?.rawValue ?? "none", "modelRewardBusy": model.rewardBusy])
                XCTAssertEqual(model.session, accepted)
            }

            // At these phases the center of this fixture's happy face is a
            // stable brown. Compare early/late pixels from the SAME target;
            // the former 180ms exit leaves a large cream veil at120ms. A25/255
            // channel tolerance detects that regression without requiring
            // exact raster equality or grading the general animation/artwork.
            let centers = try observations.map { observation -> [UInt8] in
                let pixels = try XCTUnwrap(observation["targetWindowPixels"] as? [String: Any])
                return try XCTUnwrap(pixels["centerPremultipliedSRGBA0To255"] as? [UInt8])
            }
            let early = try XCTUnwrap(centers.first), settled = try XCTUnwrap(centers.last)
            let maximumChannelChange = (0..<3).map { abs(Int(early[$0]) - Int(settled[$0])) }.max() ?? 255
            XCTAssertLessThanOrEqual(maximumChannelChange, 25,
                "The early accepted face still has a material modal veil compared with its own settled color.")

            if rewarded {
                earnedCallback?(.earned)
                await drainAlreadyQueuedRewardCallback()
                XCTAssertEqual(model.progress, acceptedProgress, "A duplicate completion cannot issue another animal, score or inventory grant.")
                XCTAssertEqual(provider.offers.count, 1)
            }
            // Leave the first 120ms free of expensive pixel readback. Defer
            // attachment encoding until both live observations have
            // been captured. Readback time is still reported, never relabeled
            // as the requested sampling time.
            for (label, image) in pendingImages {
                let attachment = XCTAttachment(image: image)
                attachment.name = name + "-" + label; attachment.lifetime = .keepAlways; add(attachment)
            }
            let report: [String: Any] = ["fixture": name, "level": 6, "screenSize": [width, height], "reducedMotion": reduced,
                "remainingMiddleRowCellsBeforeUse": remaining.sorted(), "revealedCell": target,
                "businessCommitObservedAfterSeconds": committedAt, "observations": observations,
                "earlyToSettledCenterMaximumChannelChange": maximumChannelChange,
                "boundary": "Real Root and same-window native pixels. No CA freeze or forced configure/layout. First120ms has no image readback; same-target early/late face-center color detects a material modal veil in this fixture only, not aesthetic quality. Readback can delay later samples; actual capture ranges are recorded. Inventory control uses the same two remaining cells but random selection may choose the other cell."
            ]
            let reportAttachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                uniformTypeIdentifier: "public.json")
            reportAttachment.name = name + "-natural-timing-and-visible-paths"
            reportAttachment.lifetime = .keepAlways; add(reportAttachment)
            try await Task.sleep(nanoseconds: 600_000_000)
            XCTAssertEqual(model.session, accepted)
            XCTAssertTrue(views(window).allSatisfy { !($0.0 is DirectToolRevealUIView) }, "The finite receipt must eventually clean up.")
        }
        }
    }
}
