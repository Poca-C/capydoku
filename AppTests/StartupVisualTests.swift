import XCTest
import SwiftUI
import UIKit
import CapydokuCore
@testable import Capydoku

private final class StartupVisualIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}

private final class StartupVisualRewards: RewardProvider {
    var loads: [RewardKind] = []
    var presentations: [String] = []
    func preload(placement: RewardKind, completion: @escaping (RewardReadiness) -> Void) {
        loads.append(placement)
        completion(.ready)
    }
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) {
        presentations.append(offerID)
    }
}

@MainActor private final class StartupVisualPermissions: StartupPermissions {
    var calls: [String] = []
    func notifications() async throws { calls.append("notifications") }
    func tracking() async throws { calls.append("tracking") }
}

@MainActor private final class StartupVisualHeldPermissions: StartupPermissions {
    private var notificationCompletion: CheckedContinuation<Void, Never>?
    var calls: [String] = []
    func notifications() async throws {
        calls.append("notifications")
        await withCheckedContinuation { notificationCompletion = $0 }
    }
    func tracking() async throws { calls.append("tracking") }
    func completeNotifications() {
        let pending = notificationCompletion
        notificationCompletion = nil
        pending?.resume()
    }
}

@MainActor private final class StartupVisualLifecycle: ObservableObject {
    @Published var phase: ScenePhase = .active
    @Published var reduceMotion = false
    @Published var lowPower = false
}

private struct HomeVisualLifecycleHost: View {
    @ObservedObject var lifecycle: StartupVisualLifecycle
    var body: some View {
        HomeView(lowPowerOverride: lifecycle.lowPower)
            .environment(\.scenePhase, lifecycle.phase)
            .environment(\.capyMotionOverride, lifecycle.reduceMotion)
            .background(CapyPalette.cream.ignoresSafeArea())
    }
}

private struct StartupVisualLifecycleHost: View {
    let controller: StartupController
    @ObservedObject var lifecycle: StartupVisualLifecycle
    var body: some View {
        StartupFlowView(controller: controller, reduceMotionOverride: lifecycle.reduceMotion)
            .environment(\.scenePhase, lifecycle.phase)
    }
}

@MainActor private final class StartupVisualResources: StartupResources {
    private var continuation: CheckedContinuation<Void, Error>?
    private var released = false
    private(set) var preparations = 0

    func prepare() async throws {
        preparations += 1
        if released { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
        try Task.checkCancellation()
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume(returning: ())
    }
}

@MainActor private final class StartupVisualHost {
    let host: UIHostingController<AnyView>
    let window: UIWindow
    private let previousWindow: UIWindow?

    init<Content: View>(_ content: Content) throws {
        host = UIHostingController(rootView: AnyView(content))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousWindow?.makeKeyAndVisible()
    }
}

/// Original Word [272, 274, 278] and image23 supply the comparison scope:
/// distinct Loading and Brand Loading pages, then the real Welcome overlay.
/// These hosted screenshots do not simulate system permission dialogs or prove
/// original timing, readable glyph bounds, device VoiceOver, or real Reduce Motion.
/// The controller's one-second brand hold below is an explicit test fixture.
final class StartupVisualTests: XCTestCase {
    @MainActor private func homeMascotPixels(_ rig: StartupVisualHost, frame: CGRect, name: String? = nil) throws -> WelcomeRaster {
        rig.host.view.layoutIfNeeded()
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: rig.host.view.bounds).image { _ in
            drawn = rig.host.view.drawHierarchy(in: rig.host.view.bounds, afterScreenUpdates: false)
        }
        XCTAssertTrue(drawn)
        if let name {
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cgImage.width) / rig.host.view.bounds.width
        // Fixed region around the upper face/body; the title below cannot
        // create a false movement result. Normalize the crop into its own
        // pixel buffer so retained source row strides cannot include the page.
        let area = CGRect(x: frame.minX - 6, y: frame.minY - 10, width: frame.width + 12, height: frame.height - 12)
        let pixels = CGRect(x: area.minX * scale, y: area.minY * scale,
                            width: area.width * scale, height: area.height * scale).integral
        return try WelcomeRaster(XCTUnwrap(cgImage.cropping(to: pixels)))
    }

    private func homeInkCenter(_ raster: WelcomeRaster) throws -> CGFloat {
        var total = 0, yTotal = 0
        for y in 0..<raster.height {
            for x in 0..<raster.width {
                let offset = (y * raster.width + x) * 4
                let r = Int(raster.pixels[offset]), g = Int(raster.pixels[offset + 1]), b = Int(raster.pixels[offset + 2])
                if r - g > 20 && g - b > 10 && b < 190 && r > 80 {
                    total += 1; yTotal += y
                }
            }
        }
        XCTAssertGreaterThan(total, 100, "The sampled region must contain visible mascot ink.")
        return CGFloat(yTotal) / CGFloat(max(1, total))
    }

    @MainActor private func assertHomeStill(_ rig: StartupVisualHost, frame: CGRect, reason: String) async throws {
        try await Task.sleep(nanoseconds: 180_000_000)
        let first = try homeMascotPixels(rig, frame: frame)
        try await Task.sleep(nanoseconds: 700_000_000)
        let second = try homeMascotPixels(rig, frame: frame)
        XCTAssertTrue(first.pixels == second.pixels, "The actually rendered mascot must stop: " + reason)
    }

    @MainActor private func assertHomeMovesWithinOriginalRange(_ rig: StartupVisualHost, frame: CGRect, name: String? = nil) async throws {
        try await Task.sleep(nanoseconds: 180_000_000)
        let first = try homeMascotPixels(rig, frame: frame, name: name.map { $0 + "-early" })
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let second = try homeMascotPixels(rig, frame: frame, name: name.map { $0 + "-later" })
        XCTAssertTrue(first.pixels != second.pixels, "Visible normal Home must retain its actual gentle float.")
        let scale = CGFloat(first.width) / (frame.width + 12)
        let distance = abs(try homeInkCenter(first) - homeInkCenter(second)) / scale
        XCTAssertGreaterThan(distance, 0.35, "Actual mascot ink must move, rather than a predicate merely allowing motion.")
        XCTAssertLessThanOrEqual(distance, 6.5, "Returning from coverage must not accumulate a larger displacement than the original six-point range.")
    }

    @MainActor func testActualHomeHonorsRootReducedMotionOverrideAcrossRenderedFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("home-motion-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        XCTAssertFalse(UIAccessibility.isReduceMotionEnabled,
            "This hosted regression requires the simulator's existing system setting to allow motion; the test does not change it.")
        var mascotFrame: CGRect?
        let rig = try StartupVisualHost(RootView(reduceMotionOverride: true)
            .environmentObject(model).environment(\.scenePhase, .active)
            .environment(\.capyLayoutObserver, { name, frame in
                if name == "home_mascot" { mascotFrame = frame }
            }))
        defer {
            rig.close(); model.flushPendingSaves()
            try? FileManager.default.removeItem(at: directory)
        }
        try await Task.sleep(nanoseconds: 180_000_000)
        let frame = try XCTUnwrap(mascotFrame)
        XCTAssertEqual(frame.width, 98, accuracy: 0.5)
        XCTAssertEqual(frame.height, 98, accuracy: 0.5)
        let first = try homeMascotPixels(rig, frame: frame, name: "home-reduced-override-early")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let second = try homeMascotPixels(rig, frame: frame, name: "home-reduced-override-later")
        XCTAssertTrue(first.pixels == second.pixels, "Root's reduced-motion override must keep the actual Home mascot still even when the system setting allows motion.")
        XCTAssertEqual(model.screen, .home)
    }

    @MainActor func testActualHomeFloatStopsForMotionCoverageSceneAndPowerThenResumesWithoutAccumulation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("home-lifecycle-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        let before = model.progress
        let lifecycle = StartupVisualLifecycle()
        var mascotFrame: CGRect?
        // This real HomeView remains visible while model coverage flags change;
        // an opaque Root modal cannot conceal an incorrectly running loop.
        let rig = try StartupVisualHost(HomeVisualLifecycleHost(lifecycle: lifecycle)
            .environmentObject(model).environment(\.appLanguage, .simplifiedChinese)
            .environment(\.capyLayoutObserver, { name, frame in if name == "home_mascot" { mascotFrame = frame } }))
        defer {
            rig.close(); model.flushPendingSaves()
            try? FileManager.default.removeItem(at: directory)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let frame = try XCTUnwrap(mascotFrame)
        XCTAssertEqual(frame.size, CGSize(width: 98, height: 98))
        try await assertHomeMovesWithinOriginalRange(rig, frame: frame, name: "home-normal-float")
        lifecycle.reduceMotion = true
        try await assertHomeStill(rig, frame: frame, reason: "reduced motion after an active loop")
        lifecycle.reduceMotion = false; model.sheet = .settings
        try await assertHomeStill(rig, frame: frame, reason: "settings covers Home")
        model.sheet = .debug
        try await assertHomeStill(rig, frame: frame, reason: "debug covers Home")
        model.sheet = nil
        try await assertHomeMovesWithinOriginalRange(rig, frame: frame)
        model.loading = true
        try await assertHomeStill(rig, frame: frame, reason: "loading covers Home")
        model.loading = false; model.notice = "Home lifecycle test"
        try await assertHomeStill(rig, frame: frame, reason: "an alert covers Home")
        model.notice = nil; lifecycle.phase = .background
        try await assertHomeStill(rig, frame: frame, reason: "the hosted scene is in the background")
        lifecycle.phase = .active; lifecycle.lowPower = true
        try await assertHomeStill(rig, frame: frame, reason: "low power is enabled")
        lifecycle.lowPower = false
        try await assertHomeMovesWithinOriginalRange(rig, frame: frame, name: "home-resumed-float")
        model.screen = .checkIn
        try await assertHomeStill(rig, frame: frame, reason: "Home is no longer the selected screen")
        model.screen = .home
        try await assertHomeMovesWithinOriginalRange(rig, frame: frame)
        XCTAssertEqual(model.progress, before, "Decorative lifecycle changes cannot create a board, spend inventory or change saved settings.")
        XCTAssertTrue(rig.host.view.isUserInteractionEnabled)
    }

    @MainActor func testActualRootHomeFloatsAgainAfterLeavingAndReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("home-root-return-" + UUID().uuidString)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        model.progress.tutorialCompleted = true
        var mascotFrame: CGRect?
        let rig = try StartupVisualHost(RootView(reduceMotionOverride: false)
            .environmentObject(model).environment(\.scenePhase, .active)
            .environment(\.capyLayoutObserver, { name, frame in if name == "home_mascot" { mascotFrame = frame } }))
        defer {
            rig.close(); model.flushPendingSaves()
            try? FileManager.default.removeItem(at: directory)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        try await assertHomeMovesWithinOriginalRange(rig, frame: XCTUnwrap(mascotFrame))
        model.start(level: 6)
        try await Task.sleep(nanoseconds: 150_000_000)
        let session = try XCTUnwrap(model.session)
        XCTAssertEqual(model.screen, .game)
        model.home()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await assertHomeMovesWithinOriginalRange(rig, frame: XCTUnwrap(mascotFrame), name: "home-root-return")
        XCTAssertEqual(model.screen, .home)
        XCTAssertEqual(model.session?.id, session.id)
        XCTAssertEqual(model.session?.found, session.found)
        XCTAssertEqual(model.session?.score, session.score)
    }

    @MainActor private func waitFor(_ message: String, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = try XCTUnwrap(condition() ? true : nil, message)
    }

    @MainActor private func capture(_ rig: StartupVisualHost, name: String, afterScreenUpdates: Bool = false) throws -> Data {
        rig.host.view.layoutIfNeeded()
        XCTAssertEqual(rig.host.view.bounds.size, rig.window.bounds.size)
        XCTAssertGreaterThan(rig.window.bounds.width, 300)
        XCTAssertGreaterThan(rig.window.bounds.height, 500)
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: rig.window.bounds).image { _ in
            drawn = rig.host.view.drawHierarchy(in: rig.host.view.bounds, afterScreenUpdates: afterScreenUpdates)
        }
        XCTAssertTrue(drawn, "The actual hosted hierarchy must render successfully.")
        XCTAssertEqual(image.size, rig.window.bounds.size)
        let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 16, "A black or empty image is not visual evidence.")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return try XCTUnwrap(image.pngData())
    }

    private struct WelcomeRaster {
        let width: Int
        let height: Int
        var pixels: [UInt8]

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { storage in
                let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: image.width,
                    height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            pixels = bytes
        }

        func bounds(in rect: CGRect? = nil, matching predicate: (ArraySlice<UInt8>) -> Bool) -> CGRect? {
            let area = rect ?? CGRect(x: 0, y: 0, width: width, height: height)
            var left = width, top = height, right = -1, bottom = -1
            for y in Int(area.minY)..<Int(area.maxY) {
                for x in Int(area.minX)..<Int(area.maxX) {
                    let offset = (y * width + x) * 4
                    if predicate(pixels[offset..<(offset + 4)]) {
                        left = min(left, x); top = min(top, y)
                        right = max(right, x); bottom = max(bottom, y)
                    }
                }
            }
            guard right >= left, bottom >= top else { return nil }
            return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }

        func crop(_ rect: CGRect) -> Data {
            var bytes = Data()
            for y in Int(rect.minY)..<Int(rect.maxY) {
                let start = (y * width + Int(rect.minX)) * 4
                bytes.append(contentsOf: pixels[start..<(start + Int(rect.width) * 4)])
            }
            return bytes
        }

        mutating func fill(_ rect: CGRect, with color: [UInt8]) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    let offset = (y * width + x) * 4
                    pixels.replaceSubrange(offset..<(offset + 4), with: color)
                }
            }
        }
    }

    @MainActor private func assertSameWelcomeAllowingAcceptTextPixelAlignment(
        _ first: Data, _ second: Data, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var a = try WelcomeRaster(XCTUnwrap(UIImage(data: first)?.cgImage))
        var b = try WelcomeRaster(XCTUnwrap(UIImage(data: second)?.cgImage))
        XCTAssertEqual(a.width, b.width, message, file: file, line: line)
        XCTAssertEqual(a.height, b.height, message, file: file, line: line)
        guard a.width == b.width, a.height == b.height else { return }
        if a.pixels == b.pixels { return }

        // The 17e evidence shows the exact same Accept glyphs shifted by one
        // physical pixel only. A scale/opacity compositing difference is the
        // suspected cause, not a verified explanation. Locate the actual orange
        // capsule from its rendered theme color; never hard-code device bounds.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let fillImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            UIColor(CapyPalette.actionOrange).setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let themePixel = try WelcomeRaster(XCTUnwrap(fillImage.cgImage)).pixels
        // UIKit and SwiftUI may quantize a theme component differently by one
        // 8-bit step. Use that only to locate the actual solid fill in A; both
        // images must then match that exact rendered color, with no tolerance.
        var candidates: [UInt32: Int] = [:]
        for offset in stride(from: 0, to: a.pixels.count, by: 4) {
            let pixel = Array(a.pixels[offset..<(offset + 4)])
            guard zip(pixel, themePixel).allSatisfy({ abs(Int($0.0) - Int($0.1)) <= 1 }) else { continue }
            let key = pixel.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            candidates[key, default: 0] += 1
        }
        let fillKey = try XCTUnwrap(candidates.max(by: { $0.value < $1.value })?.key, message, file: file, line: line)
        let orange = [24, 16, 8, 0].map { UInt8((fillKey >> $0) & 255) }
        let capsuleA = try XCTUnwrap(a.bounds { $0.elementsEqual(orange) }, message, file: file, line: line)
        let capsuleB = try XCTUnwrap(b.bounds { $0.elementsEqual(orange) }, message, file: file, line: line)
        XCTAssertEqual(capsuleA, capsuleB, "The Accept capsule must retain its exact pixel bounds. " + message, file: file, line: line)
        guard capsuleA == capsuleB else { return }
        // The capsule's central strip has a solid fill, away from rounded edges.
        // Its only foreground is the white Accept text; all other pixels below
        // still have to match exactly, including the complete capsule outline.
        let textArea = capsuleA.insetBy(dx: ceil(capsuleA.height / 2) + 2, dy: 2)
        XCTAssertGreaterThan(textArea.width, 0, message, file: file, line: line)
        guard textArea.width > 0, textArea.height > 0 else { return }
        let glyphA = try XCTUnwrap(a.bounds(in: textArea) { !$0.elementsEqual(orange) }, message, file: file, line: line)
        let glyphB = try XCTUnwrap(b.bounds(in: textArea) { !$0.elementsEqual(orange) }, message, file: file, line: line)
        XCTAssertEqual(glyphA.size, glyphB.size, "Accept glyph dimensions must match exactly. " + message, file: file, line: line)
        XCTAssertEqual(glyphA.minX, glyphB.minX, "Accept text cannot move horizontally. " + message, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(glyphA.minY - glyphB.minY), 1,
            "Only one physical pixel of vertical glyph alignment is allowed. " + message, file: file, line: line)
        XCTAssertEqual(a.crop(glyphA), b.crop(glyphB), "Every Accept glyph pixel must match after alignment. " + message, file: file, line: line)
        a.fill(glyphA, with: orange)
        b.fill(glyphB, with: orange)
        XCTAssertEqual(Data(a.pixels), Data(b.pixels),
            "Every pixel outside the Accept glyphs must match exactly. " + message, file: file, line: line)
    }

    @MainActor private func assertBeforeAcceptance(_ model: AppModel, permissions: StartupVisualPermissions,
                                                 rewards: StartupVisualRewards) {
        XCTAssertFalse(model.analytics.enabled)
        XCTAssertTrue(model.analytics.events.isEmpty)
        XCTAssertTrue(permissions.calls.isEmpty)
        XCTAssertTrue(rewards.loads.isEmpty, "Preparing either startup page must not preload an advertisement.")
        XCTAssertTrue(rewards.presentations.isEmpty)
        XCTAssertTrue(model.progress.rewardLedger.isEmpty)
    }

    @MainActor func testActualStartupFlowRendersBothStagesBeforeWelcomeWithoutEarlySideEffects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("startup-flow-visual-" + UUID().uuidString)
        let identity = StartupVisualIdentity(), rewards = StartupVisualRewards()
        let model = AppModel(saveDirectory: directory, rewardProvider: rewards, runsTimer: false,
                             feedbackEnabled: false, startupBypassForTesting: false,
                             analyticsIdentityStore: identity)
        defer {
            model.flushPendingSaves()
            try? FileManager.default.removeItem(at: directory)
        }
        // An existing playable board makes an accidental startupReady/preload observable.
        model.start(level: 1)
        let before = model.progress
        let permissions = StartupVisualPermissions(), resources = StartupVisualResources()
        let controller = StartupController(directory: directory, permissions: permissions, resources: resources,
            timing: StartupPresentationTiming(loadingMinimum: 0, brandMinimum: 1), active: true)
        let rig = try StartupVisualHost(
            StartupFlowView(controller: controller, scenePhaseOverride: .active)
                .environmentObject(model)
                .environment(\.scenePhase, .active)
        )
        defer { resources.release(); rig.close() }

        try await waitFor("The actual flow must begin preparing its resources.") { resources.preparations == 1 }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(controller.stage, .loading)
        assertBeforeAcceptance(model, permissions: permissions, rewards: rewards)
        let loading = try capture(rig, name: "startup-flow-01-loading-resource-gate")

        resources.release()
        try await waitFor("Resource completion must reveal the separate brand page.") { controller.stage == .brandLoading }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(controller.stage, .brandLoading)
        assertBeforeAcceptance(model, permissions: permissions, rewards: rewards)
        let brand = try capture(rig, name: "startup-flow-02-brand-demo-one-second-hold")
        XCTAssertNotEqual(loading, brand, "The two startup stages must render different pages.")

        try await waitFor("The untouched first-launch flow must stop at Welcome.") { controller.stage == .welcome }
        // Capture settled artwork after the explicit 0.18s Demo entrance.
        try await Task.sleep(nanoseconds: 260_000_000)
        let welcome = try capture(rig, name: "startup-flow-03-welcome-before-accept")
        XCTAssertNotEqual(brand, welcome, "The real Welcome overlay must be present above the brand page.")
        XCTAssertNil(controller.consent.acceptedAt)
        XCTAssertNil(controller.consent.acceptedVersion)
        XCTAssertFalse(controller.consent.notificationsCompleted)
        XCTAssertFalse(controller.consent.trackingCompleted)
        XCTAssertEqual(resources.preparations, 1)
        assertBeforeAcceptance(model, permissions: permissions, rewards: rewards)
        XCTAssertEqual(model.progress, before, "Rendering startup cannot change the saved board or inventory.")
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testWelcomePresentationLifecycleAndFailedAcceptDoNotAdvancePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("startup-welcome-transition-" + UUID().uuidString)
        let identity = StartupVisualIdentity(), rewards = StartupVisualRewards()
        let model = AppModel(saveDirectory: directory, rewardProvider: rewards, runsTimer: false,
                             feedbackEnabled: false, startupBypassForTesting: false,
                             analyticsIdentityStore: identity)
        let resources = StartupVisualResources(), permissions = StartupVisualHeldPermissions()
        let controller = StartupController(directory: directory, permissions: permissions,
            resources: resources, timing: .immediate, active: true)
        let lifecycle = StartupVisualLifecycle()
        let rig = try StartupVisualHost(StartupVisualLifecycleHost(controller: controller, lifecycle: lifecycle)
            .environmentObject(model))
        defer {
            permissions.completeNotifications(); resources.release(); rig.close()
            model.flushPendingSaves()
            try? FileManager.default.removeItem(at: directory)
        }
        try await waitFor("The hosted flow must start its actual resource gate.") { resources.preparations == 1 }
        // The model may reach its gate before the new hosting window commits
        // its first frame. Prove that Loading is drawable before releasing it;
        // otherwise an immediate Welcome sample can capture an empty window.
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(controller.stage, .loading)
        _ = try capture(rig, name: "welcome-transition-00-loading-host-ready", afterScreenUpdates: true)
        resources.release()
        try await waitFor("The actual flow must stop for consent.") { controller.stage == .welcome }
        // Yield briefly for the first transition frame, while targeting the
        // early part of the 0.18s entrance for the background interruption.
        try await Task.sleep(nanoseconds: 40_000_000)
        _ = try capture(rig, name: "welcome-transition-01-entrance-sample")
        // Interrupt an entrance using the view's real scenePhase input. This
        // is a hosted lifecycle test, not an OS background or VoiceOver test.
        lifecycle.phase = .background
        try await Task.sleep(nanoseconds: 260_000_000)
        let background = try capture(rig, name: "welcome-transition-02-background-settled", afterScreenUpdates: true)
        XCTAssertEqual(controller.stage, .welcome)
        XCTAssertNil(controller.consent.acceptedVersion)
        XCTAssertTrue(permissions.calls.isEmpty)
        lifecycle.phase = .active
        lifecycle.reduceMotion = true
        try await Task.sleep(nanoseconds: 260_000_000)
        let reduced = try capture(rig, name: "welcome-transition-03-reduce-motion-view-override", afterScreenUpdates: true)
        try assertSameWelcomeAllowingAcceptTextPixelAlignment(background, reduced, "Lifecycle cleanup must retain the complete unaccepted Welcome card.")
        lifecycle.reduceMotion = false
        try await Task.sleep(nanoseconds: 260_000_000)
        let settled = try capture(rig, name: "welcome-transition-04-foreground-settled", afterScreenUpdates: true)
        try assertSameWelcomeAllowingAcceptTextPixelAlignment(reduced, settled, "Re-enabling motion cannot restart loading, hide Welcome, or change its final layout.")
        XCTAssertEqual(background, settled, "Returning to the same motion mode must reproduce the exact full image.")
        XCTAssertTrue(model.analytics.events.isEmpty)
        XCTAssertTrue(rewards.loads.isEmpty)

        // A directory at the consent file path creates a real persistence
        // failure. Presentation must keep following the unchanged stage.
        let consentURL = directory.appendingPathComponent("consent.json")
        try FileManager.default.createDirectory(at: consentURL, withIntermediateDirectories: true)
        await controller.accept()
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.stage, .welcome)
        XCTAssertNil(controller.consent.acceptedVersion)
        XCTAssertTrue(permissions.calls.isEmpty)
        XCTAssertTrue(rewards.loads.isEmpty)
        try FileManager.default.removeItem(at: consentURL)
        controller.errorMessage = nil
        let accepting = Task { await controller.accept() }
        defer { accepting.cancel() }
        try await waitFor("Successful persistence must lead to the real notification step.") { permissions.calls == ["notifications"] }
        try await Task.sleep(nanoseconds: 260_000_000)
        let permissionBackground = try capture(rig, name: "welcome-transition-05-notification-pending-brand-only")
        XCTAssertNotEqual(settled, permissionBackground, "The accepted card must finish exiting while the brand page remains.")
        XCTAssertEqual(controller.stage, .notifications, "Animation completion cannot skip a pending system permission.")
        XCTAssertEqual(controller.consent.acceptedVersion, StartupController.consentVersion)
        XCTAssertFalse(controller.consent.notificationsCompleted)
        XCTAssertFalse(controller.consent.trackingCompleted)
        XCTAssertTrue(rewards.loads.isEmpty)
        permissions.completeNotifications()
        await accepting.value
        XCTAssertEqual(permissions.calls, ["notifications", "tracking"])
        XCTAssertEqual(controller.stage, .ready)
    }

    @MainActor func testActualStartupArtworkAtDeviceSizeAndLargeTypeWithReducedMotionOverride() async throws {
        let variants: [(name: String, type: DynamicTypeSize, reduced: Bool)] = [
            ("device-size-default-type", .large, false),
            ("device-size-accessibility3-reduce-motion-view-override", .accessibility3, true)
        ]
        for variant in variants {
            for brand in [false, true] {
                let content: AnyView
                if brand {
                    content = AnyView(StartupBrandView(isPreparing: true, reduceMotionOverride: variant.reduced))
                } else {
                    content = AnyView(StartupLoadingView(isPreparing: true, reduceMotionOverride: variant.reduced))
                }
                let rig = try StartupVisualHost(content.dynamicTypeSize(variant.type).environment(\.scenePhase, .active))
                defer { rig.close() }
                try await Task.sleep(nanoseconds: 100_000_000)
                _ = try capture(rig, name: "startup-artwork-\(brand ? "brand" : "loading")-\(variant.name)")
                // Bounds above cover the hosted viewport. Human screenshot review
                // must still check text clipping, safe-area spacing and composition;
                // SwiftUI's view bounds alone cannot prove internal glyph visibility.
            }
        }
    }
}
