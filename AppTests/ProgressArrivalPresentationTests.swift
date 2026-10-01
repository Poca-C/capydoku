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
    @MainActor func testFlightRotatingBoundsClearSourceAcrossBoardSizesAndEdgesAndReachHUD() {
        // Match the board's 7-point inset while translating it by fractional
        // window coordinates. Include corners, edge centres and an interior
        // cell, with HUD targets on either side of the board.
        var checkedFlights = 0
        for boardWidth: CGFloat in [190, 320, 374] {
            let board = CGRect(x: 23.25, y: 241.75, width: boardWidth, height: boardWidth)
            let grid = board.insetBy(dx: 7, dy: 7)
            for size in 4...10 {
                let side = grid.width / CGFloat(size)
                let middle = size / 2
                let cells = [(0, 0), (0, middle), (0, size - 1),
                             (middle, 0), (middle, middle), (middle, size - 1),
                             (size - 1, 0), (size - 1, middle), (size - 1, size - 1)]
                for (row, column) in cells {
                    let source = CGRect(x: grid.minX + CGFloat(column) * side,
                                        y: grid.minY + CGFloat(row) * side,
                                        width: side, height: side)
                    let cellCentre = CGPoint(x: source.midX, y: source.midY)
                    for targetX in [board.minX + 28, board.maxX - 28] {
                        let destination = CGPoint(x: targetX, y: board.minY - 96)
                        let flight = GameRewardPresentation.Flight(origin: cellCentre,
                            destination: destination, sourceCell: source, boardFrame: grid)
                        let context = "board \(boardWidth), \(size)×\(size), cell \(row)/\(column), target \(targetX)"
                        XCTAssertGreaterThanOrEqual(flight.diameter, 8, context)
                        XCTAssertLessThanOrEqual(flight.diameter, 14, context)
                        XCTAssertLessThan(flight.origin.y, source.minY, context)
                        XCTAssertEqual(flight.position(at: 0).x, flight.origin.x, accuracy: 0.000001, context)
                        XCTAssertEqual(flight.position(at: 0).y, flight.origin.y, accuracy: 0.000001, context)
                        XCTAssertEqual(flight.position(at: 1).x, destination.x, accuracy: 0.000001, context)
                        XCTAssertEqual(flight.position(at: 1).y, destination.y, accuracy: 0.000001, context)
                        var minimumClearance = CGFloat.infinity
                        var allFinite = true
                        for step in 0...240 {
                            let progress = CGFloat(step) / 240
                            let point = flight.position(at: progress)
                            allFinite = allFinite && point.x.isFinite && point.y.isFinite
                            // Circumcircle encloses the square sprite at every
                            // rotation, including the renderer's shrinking scale.
                            // This checks source geometry, not shadow pixels or
                            // visibility through the separate rule/Combo masks.
                            let radius = flight.diameter * sqrt(2) / 2 * (1 - progress * 0.42)
                            let nearestX = min(source.maxX, max(source.minX, point.x))
                            let nearestY = min(source.maxY, max(source.minY, point.y))
                            let distance = hypot(point.x - nearestX, point.y - nearestY)
                            minimumClearance = min(minimumClearance, distance - radius)
                        }
                        XCTAssertTrue(allFinite, context)
                        XCTAssertGreaterThan(minimumClearance, 0, "Rotating star intersects its source: " + context)
                        checkedFlights += 1
                    }
                }
            }
        }
        XCTAssertEqual(checkedFlights, 378)
    }

    @MainActor func testCurrent150LevelFlightsClearEveryPossibleFoundFaceWithContinuousBoundedRoutes() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "levels", withExtension: "json"))
        let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
        XCTAssertEqual(puzzles.count, 150)
        let steps = 480
        var checked = 0, minimumClearance = CGFloat.infinity, maximumStepRatio: CGFloat = 0
        var minimumStepRatio = CGFloat.infinity, minimumTurnCosine: CGFloat = 1
        var diagnostics = [[String: Any]](), lengthRatios = [Double]()
        var legacyCollisionPaths = 0, legacyExamples = [[String: Any]]()
        func clearance(_ point: CGPoint, from rect: CGRect, radius: CGFloat) -> CGFloat {
            let x = min(rect.maxX, max(rect.minX, point.x))
            let y = min(rect.maxY, max(rect.minY, point.y))
            return hypot(point.x - x, point.y - y) - radius
        }
        for hostWidth: CGFloat in [190, 320, 374] {
            let hostBoard = CGRect(x: 23.25, y: 241.75, width: hostWidth, height: hostWidth)
            let grid = hostBoard.insetBy(dx: 7, dy: 7)
            for puzzle in puzzles {
                let side = grid.width / CGFloat(puzzle.size)
                let gap = max(1.1, min(2, side * 0.028))
                func cell(_ index: Int) -> CGRect {
                    CGRect(x: grid.minX + CGFloat(index % puzzle.size) * side,
                           y: grid.minY + CGFloat(index / puzzle.size) * side,
                           width: side, height: side)
                }
                for index in puzzle.solution {
                    let source = cell(index)
                    // The entire solution is only a test obstacle set: these
                    // include animals the player might find during this flight.
                    // Production receives source/board/target geometry, no answer.
                    let otherFaces = puzzle.solution.filter { $0 != index }.map { other -> CGRect in
                        let tile = cell(other).insetBy(dx: gap, dy: gap)
                        let face = tile.insetBy(dx: tile.width * 0.07, dy: tile.height * 0.07)
                        let pop = face.insetBy(dx: -face.width * 0.07, dy: -face.height * 0.07)
                        let victory = face.insetBy(dx: -face.width * 0.035, dy: -face.height * 0.035)
                            .offsetBy(dx: 0, dy: -min(3.2, face.height * 0.045))
                        return pop.union(victory)
                    }
                    for targetX in [hostBoard.minX + 28, hostBoard.maxX - 28] {
                        let destination = CGPoint(x: targetX, y: hostBoard.minY - 96)
                        let flight = GameRewardPresentation.Flight(origin: CGPoint(x: source.midX, y: source.midY),
                            destination: destination, sourceCell: source, boardFrame: grid)
                        let context = "L\(puzzle.id), host\(hostWidth), source\(index), targetX\(targetX)"
                        let points = (0...steps).map { flight.position(at: CGFloat($0) / CGFloat(steps)) }
                        XCTAssertTrue(points.allSatisfy { $0.x.isFinite && $0.y.isFinite }, context)
                        XCTAssertEqual(points[0].x, flight.origin.x, accuracy: 0.000001, context)
                        XCTAssertEqual(points[0].y, flight.origin.y, accuracy: 0.000001, context)
                        XCTAssertEqual(points[steps].x, destination.x, accuracy: 0.000001, context)
                        XCTAssertEqual(points[steps].y, destination.y, accuracy: 0.000001, context)
                        // Constant maximum radius +1pt glow is stricter than
                        // the real sprite, which shrinks throughout its flight.
                        let radius = flight.diameter * sqrt(2) / 2 + 1
                        var routeClearance = CGFloat.infinity
                        for point in points {
                            routeClearance = min(routeClearance, clearance(point, from: source, radius: radius))
                            for face in otherFaces {
                                routeClearance = min(routeClearance, clearance(point, from: face, radius: radius))
                            }
                        }
                        XCTAssertGreaterThan(routeClearance, 0, "Source or possible found face crossed: " + context)
                        minimumClearance = min(minimumClearance, routeClearance)
                        var distances = [CGFloat](), vectors = [CGVector]()
                        for offset in 1..<points.count {
                            let dx = points[offset].x - points[offset - 1].x
                            let dy = points[offset].y - points[offset - 1].y
                            distances.append(hypot(dx, dy)); vectors.append(CGVector(dx: dx, dy: dy))
                        }
                        let length = distances.reduce(0, +), meanStep = length / CGFloat(steps)
                        let smallStep = try XCTUnwrap(distances.min()) / meanStep
                        let largeStep = try XCTUnwrap(distances.max()) / meanStep
                        XCTAssertGreaterThan(smallStep, 0.8, "An equal-progress sample must not stall at the route join: " + context)
                        XCTAssertLessThan(largeStep, 1.15, "An equal-progress sample must not jump at the route join: " + context)
                        minimumStepRatio = min(minimumStepRatio, smallStep)
                        maximumStepRatio = max(maximumStepRatio, largeStep)
                        var turnCosine: CGFloat = 1
                        for offset in 1..<vectors.count {
                            let a = vectors[offset - 1], b = vectors[offset]
                            let denominator = distances[offset - 1] * distances[offset]
                            if denominator > 0 {
                                turnCosine = min(turnCosine, (a.dx * b.dx + a.dy * b.dy) / denominator)
                            }
                        }
                        XCTAssertGreaterThan(turnCosine, 0.8, "The two segments must not form a sharp corner or reversal: " + context)
                        minimumTurnCosine = min(minimumTurnCosine, turnCosine)
                        // Compare to the documented pre-0249 quadratic, solely
                        // as a route-length diagnostic and generous detour cap.
                        let control = CGPoint(x: flight.origin.x + (destination.x - flight.origin.x) * 0.28,
                                              y: min(flight.origin.y, destination.y) - 30)
                        var oldLength: CGFloat = 0, previous = flight.origin
                        var legacyCrossedFace = clearance(flight.origin, from: source, radius: radius) <= 0
                            || otherFaces.contains { clearance(flight.origin, from: $0, radius: radius) <= 0 }
                        for offset in 1...steps {
                            let t = CGFloat(offset) / CGFloat(steps), u = 1 - t
                            let point = CGPoint(x: u*u*flight.origin.x + 2*u*t*control.x + t*t*destination.x,
                                                y: u*u*flight.origin.y + 2*u*t*control.y + t*t*destination.y)
                            oldLength += hypot(point.x - previous.x, point.y - previous.y); previous = point
                            if !legacyCrossedFace {
                                legacyCrossedFace = clearance(point, from: source, radius: radius) <= 0
                                    || otherFaces.contains { clearance(point, from: $0, radius: radius) <= 0 }
                            }
                        }
                        if legacyCrossedFace {
                            legacyCollisionPaths += 1
                            if legacyExamples.count < 5 {
                                legacyExamples.append(["level": puzzle.id, "hostWidth": Double(hostWidth),
                                    "source": index, "destinationX": Double(targetX)])
                            }
                        }
                        let ratio = Double(length / oldLength)
                        XCTAssertLessThan(ratio, 1.3, "A protected route must not make an excessive detour: " + context)
                        lengthRatios.append(ratio)
                        diagnostics.append(["level": puzzle.id, "hostWidth": Double(hostWidth), "source": index,
                            "destinationX": Double(targetX), "newLength": Double(length), "oldLength": Double(oldLength),
                            "lengthRatio": ratio, "clearance": Double(routeClearance)])
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 7116)
        lengthRatios.sort()
        let worst = diagnostics.sorted { ($0["lengthRatio"] as? Double ?? 0) > ($1["lengthRatio"] as? Double ?? 0) }
        let data = try JSONSerialization.data(withJSONObject: ["routeCount": checked, "pointsPerRoute": steps + 1,
            "minimumClearance": Double(minimumClearance), "minimumStepRatio": Double(minimumStepRatio),
            "maximumStepRatio": Double(maximumStepRatio), "minimumTurnCosine": Double(minimumTurnCosine),
            "medianLengthRatio": lengthRatios[lengthRatios.count / 2],
            "p95LengthRatio": lengthRatios[Int(Double(lengthRatios.count) * 0.95)],
            "legacyCollisionPathsUnderSameObstacles": legacyCollisionPaths,
            "legacyCollisionExamples": legacyExamples,
            "worstLengthRatios": Array(worst.prefix(5)),
            "boundary": "Production Flight.position on the current150-level pack, translated190/320/374pt geometry and two HUD directions. All possible found faces include pop/celebration bounds; source uses its full cell. Legacy collision count uses the same481 progress samples and constant maximum rotating radius+1pt glow against the identical obstacles, not previously-found prefixes. Finite geometry samples and equal path progress do not prove actual composited pixels, elapsed-time speed, frame rate, or physical touch latency."], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "current-pack-flight-route-geometry"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testFlightWithoutSourceKeepsItsOriginalEndpointsAndVisibleFallbackSize() {
        let origin = CGPoint(x: 151.5, y: 412.25), destination = CGPoint(x: 74.25, y: 97.5)
        let flight = GameRewardPresentation.Flight(origin: origin, destination: destination)
        XCTAssertEqual(flight.origin, origin); XCTAssertEqual(flight.destination, destination)
        XCTAssertEqual(flight.diameter, 14)
        XCTAssertEqual(flight.position(at: 0), origin)
        XCTAssertEqual(flight.position(at: 1), destination)
    }

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
