import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

@MainActor private final class ArrivalTestClock {
    var now = 0.0
    var jobs: [(Double, DispatchWorkItem)] = []
    func schedule(_ delay: Double, _ work: DispatchWorkItem) { jobs.append((now + delay, work)) }
    func advance(_ interval: Double) {
        let end = now + interval
        while let index = jobs.indices.filter({ jobs[$0].0 <= end }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
            let (time, work) = jobs.remove(at: index); now = time
            if !work.isCancelled { work.perform() }
        }
        now = end
    }
}

final class ProgressArrivalPresentationTests: XCTestCase {
    @MainActor func testRapidArrivalsRetriggerAndOldJobsCannotSettleTheNewPulse() {
        let clock = ArrivalTestClock(), session = UUID(), first = UUID(), second = UUID()
        let pulse = ProgressArrivalPresentation(schedule: clock.schedule)
        pulse.bind(sessionID: session, arrivalID: nil)
        pulse.update(sessionID: session, arrivalID: first, enabled: true, reduceMotion: false, lowPower: false)
        clock.advance(0.045)
        XCTAssertEqual(pulse.scale, 1.10)
        pulse.update(sessionID: session, arrivalID: second, enabled: true, reduceMotion: false, lowPower: false)
        XCTAssertEqual(pulse.activeID, second); XCTAssertEqual(pulse.scale, 0.99)
        clock.advance(0.04)
        XCTAssertEqual(pulse.scale, 1.10)
        pulse.update(sessionID: session, arrivalID: second, enabled: true, reduceMotion: false, lowPower: false)
        XCTAssertEqual(pulse.scale, 1.10, "Repeated layout cannot restart the release phase.")
        clock.advance(0.065)
        XCTAssertEqual(pulse.scale, 1.10, "The first pulse's old settle job cannot affect the second.")
        clock.advance(0.18)
        XCTAssertEqual(pulse.activeID, second, "The old completion cannot cancel the new pulse.")
        clock.advance(0.04)
        XCTAssertNil(pulse.activeID); XCTAssertEqual(pulse.scale, 1)
    }

    @MainActor func testHiddenMotionPowerAndReplacementConsumeEventsWithoutReplay() {
        for gate in 0..<4 {
            let clock = ArrivalTestClock(), session = UUID(), first = UUID(), hidden = UUID()
            let pulse = ProgressArrivalPresentation(schedule: clock.schedule)
            pulse.bind(sessionID: session, arrivalID: nil)
            pulse.update(sessionID: session, arrivalID: first, enabled: true, reduceMotion: false, lowPower: false)
            clock.advance(0.05)
            let currentSession = gate == 3 ? UUID() : session
            pulse.update(sessionID: currentSession, arrivalID: hidden,
                         enabled: gate != 0, reduceMotion: gate == 1, lowPower: gate == 2)
            XCTAssertNil(pulse.activeID); XCTAssertEqual(pulse.scale, 1)
            let reset = pulse.resetID
            pulse.cancel()
            XCTAssertEqual(pulse.resetID, reset, "An already-static counter does not rebuild on repeated cancellation.")
            clock.advance(1)
            pulse.update(sessionID: currentSession, arrivalID: hidden, enabled: true, reduceMotion: false, lowPower: false)
            XCTAssertNil(pulse.activeID); XCTAssertEqual(pulse.scale, 1, "Reopening does not replay a consumed arrival.")
            let fresh = UUID()
            pulse.update(sessionID: currentSession, arrivalID: fresh, enabled: true, reduceMotion: false, lowPower: false)
            XCTAssertEqual(pulse.activeID, fresh)
            pulse.cancel(); clock.advance(1)
            XCTAssertNil(pulse.activeID); XCTAssertEqual(pulse.scale, 1)
        }
    }

    func testTextMaskKeepsOverlappingMeasuredBandsProtectedAndEndpointsAvailable() {
        let board = CGRect(x: 0, y: 0, width: 200, height: 300)
        let measured = [CGRect(x: 10, y: 80, width: 180, height: 60),
                        CGRect(x: 25, y: 135, width: 150, height: 30),
                        CGRect(x: 30, y: 165, width: 130, height: 20)]
        let protected = measured.map { $0.insetBy(dx: -5, dy: -5) }
        let path = ProgressFlightTextMask(protectedFrames: protected).path(in: board)
        let pieces = ProgressFlightTextMask.mergedFrames(protected, inside: board)
        for (index, piece) in pieces.enumerated() {
            for other in pieces.dropFirst(index + 1) {
                let overlap = piece.intersection(other)
                XCTAssertTrue(overlap.isNull || overlap.isEmpty, "Even-odd holes must not double-cover any area.")
            }
        }
        for frame in measured {
            for point in [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.midX, y: frame.midY),
                          CGPoint(x: frame.maxX, y: frame.maxY)] {
                XCTAssertFalse(path.contains(point, eoFill: true), "Measured text and overlapping masks cannot leak a star.")
            }
        }
        XCTAssertTrue(path.contains(CGPoint(x: 150, y: 240), eoFill: true), "Actual cell origin remains drawable.")
        XCTAssertTrue(path.contains(CGPoint(x: 70, y: 40), eoFill: true), "Actual HUD destination remains drawable.")
        let narrowBadgeFrames = [CGRect(x: 10, y: 80, width: 180, height: 60),
                                 CGRect(x: 70, y: 135, width: 60, height: 30)].map { $0.insetBy(dx: -5, dy: -5) }
        let besideBadge = CGPoint(x: 20, y: 155)
        XCTAssertTrue(narrowBadgeFrames.allSatisfy { !$0.contains(besideBadge) })
        let narrowPath = ProgressFlightTextMask(protectedFrames: narrowBadgeFrames).path(in: board)
        XCTAssertTrue(narrowPath.contains(besideBadge, eoFill: true), "A wide rule row cannot erase the empty space beside the narrow badge.")
        XCTAssertFalse(narrowPath.contains(CGPoint(x: 100, y: 137), eoFill: true), "The actual overlap still protects text.")
        let invalid = CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20)
        let clipped = ProgressFlightTextMask.mergedFrames([invalid, CGRect(x: -20, y: 40, width: 40, height: 20)], inside: board)
        XCTAssertEqual(clipped, [CGRect(x: 0, y: 40, width: 20, height: 20)])
    }

    @MainActor func testLiveSwiftUIRetriggerAndCancellationDuringReturnRestoreTheCounterSize() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let pulse = ProgressArrivalPresentation(), session = UUID()
        var laidOutWidth: CGFloat = 0
        let view = Color.white.frame(width: 100, height: 40)
            .background(GeometryReader { geometry in
                Color.clear.onAppear { laidOutWidth = geometry.size.width }
            })
            .modifier(ProgressArrivalPulseModifier(sessionID: session, arrivalID: nil, enabled: true,
                                                   reduceMotion: false, presentation: pulse))
            .frame(width: 150, height: 90).background(Color.black)
            .environment(\.scenePhase, .active)
        let host = UIHostingController(rootView: view)
        let controller = UIViewController(); controller.view.backgroundColor = .black
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.addChild(host); controller.view.addSubview(host.view)
        host.view.frame = CGRect(x: 30, y: 120, width: 150, height: 90); host.didMove(toParent: controller)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(nanoseconds: 100_000_000)
        func visibleWidth() throws -> Int {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
            }
            let bitmap = try XCTUnwrap(image.cgImage)
            let bytes = try XCTUnwrap(bitmap.dataProvider?.data) as Data
            let row = bitmap.height / 2, pixelBytes = bitmap.bitsPerPixel / 8
            return (0..<bitmap.width).filter { x in
                let offset = row * bitmap.bytesPerRow + x * pixelBytes
                return bytes[offset] > 230 && bytes[offset + 1] > 230 && bytes[offset + 2] > 230
            }.count
        }
        let baseline = try visibleWidth()
        // Point width and the fully-white raster interior differ at antialiased
        // edges. Check layout exactly, then compare identical pixel criteria.
        XCTAssertEqual(laidOutWidth, 100)
        pulse.update(sessionID: session, arrivalID: UUID(), enabled: true, reduceMotion: false, lowPower: false)
        try await Task.sleep(nanoseconds: 105_000_000)
        XCTAssertGreaterThan(try visibleWidth(), baseline + 3)
        pulse.update(sessionID: session, arrivalID: UUID(), enabled: true, reduceMotion: false, lowPower: false)
        try await Task.sleep(nanoseconds: 105_000_000)
        XCTAssertGreaterThan(try visibleWidth(), baseline + 3, "A second arrival actually animates before the old pulse ends.")
        try await Task.sleep(nanoseconds: 75_000_000)
        XCTAssertEqual(pulse.scale, 1, "The model already targets identity during the visible return.")
        let previousReset = pulse.resetID
        pulse.update(sessionID: session, arrivalID: pulse.activeID, enabled: false, reduceMotion: false, lowPower: false)
        XCTAssertNotEqual(pulse.resetID, previousReset, "Cancelling an identity-targeted return discards its active interpolation.")
        try await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertEqual(Double(try visibleWidth()), Double(baseline), accuracy: 1, "Cancellation must stop the presentation, even when its model target was already identity.")
        XCTAssertEqual(laidOutWidth, 100, "The reset does not move or resize the counter's layout.")
        let cancelledReset = pulse.resetID
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(pulse.resetID, cancelledReset, "Replacing the child cannot recursively bind or cancel the stable modifier.")
        XCTAssertEqual(Double(try visibleWidth()), Double(baseline), accuracy: 1)
    }

    @MainActor func testActualRootRapidFoundArrivalsAndCoverCancellationCaptures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arrival-hud-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true; model.start(level: 6)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: RootView(reduceMotionOverride: false).environmentObject(model)
            .environment(\.scenePhase, .active))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: directory)
        }
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: false)
            }
            let item = XCTAttachment(image: image); item.name = name; item.lifetime = .keepAlways; add(item)
        }
        try await Task.sleep(nanoseconds: 650_000_000)
        let solution = try XCTUnwrap(model.session).puzzle.solution
        let cells = Array(solution.prefix(2))
        XCTAssertEqual(cells.count, 2)
        model.submit(cells[0])
        try await Task.sleep(nanoseconds: 130_000_000)
        model.submit(cells[1])
        XCTAssertEqual(model.session?.found.count, 2, "Both finds commit before either flight arrives.")
        let committed = model.session
        capture("arrival-actual-root-two-committed-before-hud-arrival")
        try await Task.sleep(nanoseconds: 160_000_000)
        capture("arrival-actual-root-flight-through-protected-text-290ms")
        try await Task.sleep(nanoseconds: 225_000_000)
        capture("arrival-actual-root-first-hud-pulse-515ms")
        try await Task.sleep(nanoseconds: 130_000_000)
        capture("arrival-actual-root-second-hud-pulse-645ms")
        XCTAssertEqual(model.session, committed)
        model.sheet = .settings
        try await Task.sleep(nanoseconds: 100_000_000)
        model.sheet = nil
        try await Task.sleep(nanoseconds: 220_000_000)
        capture("arrival-actual-root-cover-cancel-return-no-replay")
        XCTAssertEqual(model.session, committed, "A HUD cancellation changes no gameplay state.")
    }
}
