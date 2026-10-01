import XCTest
import UIKit
@testable import Capydoku

@MainActor private final class FacePresentationHost {
    let window: UIWindow
    let head = CALayer()
    let presentation = ResultFacePresentation()
    let parts: ResultFaceParts
    private let previous: UIWindow?

    init(_ performance: ResultCharacterPerformance) throws {
        // Deliberately no generated fixture or fallback eyes/mouth. A missing
        // final atlas/registration must fail this real-artwork host test.
        parts = try XCTUnwrap(ResultFaceArtwork.parts(for: performance))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.cream)
        window.rootViewController = controller; window.makeKeyAndVisible()
        head.frame = CGRect(x: 40, y: 120, width: 250, height: 250 * parts.base.size.height / parts.base.size.width)
        head.contents = parts.base.cgImage; head.contentsGravity = .resize
        controller.view.layer.addSublayer(head)
        presentation.configure(parts: parts, on: head)
    }

    var features: [CALayer] { (head.sublayers ?? []).filter { $0.name?.hasPrefix("result-face-") == true } }
    func close() {
        presentation.configure(parts: nil, on: nil)
        window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
    }
}

final class ResultFacePresentationTests: XCTestCase {
    @MainActor private func feature(_ name: String, in root: CALayer) throws -> CALayer {
        try XCTUnwrap(root.sublayers?.first { $0.name == "result-face-" + name })
    }

    @MainActor private func modelPixels(_ head: CALayer) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: head.bounds, format: format).image { head.render(in: $0.cgContext) }
        return try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
    }

    @MainActor private func capture(_ head: CALayer, name: String) throws {
        let actual = try XCTUnwrap(head.presentation(), "Capture the real running host, not a seeked layer or static fallback.")
        let image = UIGraphicsImageRenderer(bounds: head.bounds).image { actual.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func assertRest(_ layers: [CALayer], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(layers.count, 4, file: file, line: line)
        for layer in layers {
            let visible = layer.name == "result-face-eyes-open" || layer.name == "result-face-mouth-rest"
            XCTAssertEqual(layer.opacity, visible ? 1 : 0, file: file, line: line)
            XCTAssertTrue(CATransform3DIsIdentity(layer.transform), file: file, line: line)
        }
    }

    @MainActor private func wait(until time: CFTimeInterval) async throws {
        let remaining = time - CACurrentMediaTime()
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
    }

    /// Screenshot/recording entry with the final cached raster parts. These are
    /// component hosts; integration with the whole moving head is checked by the
    /// owning result view's tests, not inferred from this fixture.
    @MainActor func testActualRasterEyesAndMouthChangeIndependentlyThenRestoreForAllPerformances() async throws {
        for performance in ResultCharacterPerformance.allCases {
            let host = try FacePresentationHost(performance); defer { host.close() }
            try await Task.sleep(nanoseconds: 100_000_000)
            let baseline = try modelPixels(host.head)
            let duration: TimeInterval = performance == .joyfulRaise ? 1.05 : performance == .starHug ? 1.2 : 0.92
            let closedPhase = performance == .joyfulRaise ? 0.23 : performance == .starHug ? 0.39 : 0.43
            let reopenedPhase = performance == .joyfulRaise ? 0.42 : performance == .starHug ? 0.61 : 0.69
            let start = CACurrentMediaTime()
            host.presentation.play(performance: performance, duration: duration, startTime: start)
            assertRest(host.features)
            XCTAssertTrue((host.head.animationKeys() ?? []).isEmpty, "Local features cannot flash or animate the head base.")
            try await wait(until: start + duration * closedPhase)
            let closed = try XCTUnwrap(host.head.presentation())
            XCTAssertGreaterThan(try feature("eyes-closed", in: closed).opacity, 0.94)
            XCTAssertLessThan(try feature("eyes-open", in: closed).opacity, 0.06)
            XCTAssertGreaterThan(try feature("mouth-active", in: closed).opacity, 0.94)
            try capture(host.head, name: "face-0231-\(performance.rawValue)-closed-eyes-active-mouth")

            try await wait(until: start + duration * reopenedPhase)
            let reopened = try XCTUnwrap(host.head.presentation())
            XCTAssertGreaterThan(try feature("eyes-open", in: reopened).opacity, 0.94)
            XCTAssertLessThan(try feature("eyes-closed", in: reopened).opacity, 0.06)
            XCTAssertGreaterThan(try feature("mouth-active", in: reopened).opacity, 0.94,
                                 "Eyes must reopen while the mouth is still active: this cannot be a whole-face swap.")
            try capture(host.head, name: "face-0231-\(performance.rawValue)-open-eyes-active-mouth")

            try await wait(until: start + duration + 0.12)
            let settled = try XCTUnwrap(host.head.presentation())
            XCTAssertEqual(try feature("eyes-open", in: settled).opacity, 1, accuracy: 0.001)
            XCTAssertEqual(try feature("mouth-rest", in: settled).opacity, 1, accuracy: 0.001)
            XCTAssertEqual(try feature("eyes-closed", in: settled).opacity, 0, accuracy: 0.001)
            XCTAssertEqual(try feature("mouth-active", in: settled).opacity, 0, accuracy: 0.001)
            XCTAssertTrue(host.features.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
            XCTAssertEqual(try modelPixels(host.head), baseline)
            try capture(host.head, name: "face-0231-\(performance.rawValue)-settled")
        }
    }

    @MainActor func testSameHeadLayoutKeepsLiveClockAndCancelRestoresExactSameRasterState() async throws {
        let host = try FacePresentationHost(.starHug); defer { host.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let baseline = try modelPixels(host.head)
        let ids = host.features.map(ObjectIdentifier.init)
        let start = CACurrentMediaTime()
        host.presentation.play(performance: .starHug, duration: 1.2, startTime: start)
        let begins = host.features.map { $0.animation(forKey: "result-face-expression")?.beginTime }
        try await wait(until: start + 1.2 * 0.39)
        XCTAssertGreaterThan(try feature("eyes-closed", in: XCTUnwrap(host.head.presentation())).opacity, 0.94)
        let originalBounds = host.head.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host.head.bounds.size = CGSize(width: originalBounds.width * 0.88, height: originalBounds.height * 0.88)
        CATransaction.commit()
        for _ in 0..<5 { host.presentation.configure(parts: host.parts, on: host.head) }
        XCTAssertEqual(host.features.map(ObjectIdentifier.init), ids)
        XCTAssertEqual(host.features.map { $0.animation(forKey: "result-face-expression")?.beginTime }, begins)
        XCTAssertEqual(try feature("eyes-open", in: host.head).bounds.width,
                       host.parts.openEyes.frame.width * host.head.bounds.width, accuracy: 0.0001)
        try await wait(until: start + 1.2 * 0.61)
        XCTAssertGreaterThan(try feature("eyes-open", in: XCTUnwrap(host.head.presentation())).opacity, 0.94)
        XCTAssertGreaterThan(try feature("mouth-active", in: XCTUnwrap(host.head.presentation())).opacity, 0.94)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host.head.bounds = originalBounds
        CATransaction.commit()
        host.presentation.configure(parts: host.parts, on: host.head)
        host.presentation.cancel()
        assertRest(host.features)
        XCTAssertTrue(host.features.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        XCTAssertEqual(try modelPixels(host.head), baseline)
        host.presentation.configure(parts: host.parts, on: host.head)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(host.features.allSatisfy { ($0.animationKeys() ?? []).isEmpty }, "Layout after cancellation is not another result event.")
    }

    @MainActor func testHeadReplacementAndNilDetachOnlyOwnedFeaturesAndDoNotReplay() throws {
        let host = try FacePresentationHost(.gentleRetry); defer { host.close() }
        let unrelated = CALayer(); unrelated.name = "owner-sigh-anchor"; host.head.addSublayer(unrelated)
        host.presentation.play(performance: .gentleRetry, duration: 0.92, startTime: CACurrentMediaTime())
        let oldFeatures = host.features
        let replacement = CALayer(); replacement.frame = CGRect(x: 20, y: 400, width: 180, height: 140)
        replacement.contents = host.parts.base.cgImage
        host.window.rootViewController?.view.layer.addSublayer(replacement)
        host.presentation.configure(parts: host.parts, on: replacement)
        XCTAssertTrue(host.features.isEmpty)
        XCTAssertTrue(unrelated.superlayer === host.head)
        XCTAssertTrue(oldFeatures.allSatisfy { $0.superlayer === replacement && ($0.animationKeys() ?? []).isEmpty })
        assertRest(replacement.sublayers ?? [])
        for (layer, source) in zip(replacement.sublayers ?? [], [host.parts.openEyes, host.parts.closedEyes, host.parts.restMouth, host.parts.activeMouth]) {
            XCTAssertEqual(layer.bounds.width, source.frame.width * replacement.bounds.width, accuracy: 0.0001)
            XCTAssertEqual(layer.position.x, source.frame.midX * replacement.bounds.width, accuracy: 0.0001)
            XCTAssertEqual(layer.bounds.height, source.frame.height * replacement.bounds.height, accuracy: 0.0001)
            XCTAssertEqual(layer.position.y, source.frame.midY * replacement.bounds.height, accuracy: 0.0001)
            XCTAssertNotNil(layer.contents, "Every feature is a supplied raster image.")
        }
        host.presentation.play(performance: .gentleRetry, duration: 0.92, startTime: CACurrentMediaTime())
        host.presentation.configure(parts: nil, on: replacement)
        XCTAssertTrue((replacement.sublayers ?? []).isEmpty)
        XCTAssertTrue(oldFeatures.allSatisfy { $0.superlayer == nil && ($0.animationKeys() ?? []).isEmpty })
        host.presentation.configure(parts: host.parts, on: replacement)
        XCTAssertTrue((replacement.sublayers ?? []).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        host.presentation.configure(parts: host.parts, on: nil)
        XCTAssertTrue((replacement.sublayers ?? []).isEmpty)
    }
}
