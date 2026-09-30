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
    @MainActor private func waitFor(_ message: String, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = try XCTUnwrap(condition() ? true : nil, message)
    }

    @MainActor private func capture(_ rig: StartupVisualHost, name: String) throws -> Data {
        rig.host.view.layoutIfNeeded()
        XCTAssertEqual(rig.host.view.bounds.size, rig.window.bounds.size)
        XCTAssertGreaterThan(rig.window.bounds.width, 300)
        XCTAssertGreaterThan(rig.window.bounds.height, 500)
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: rig.window.bounds).image { _ in
            drawn = rig.host.view.drawHierarchy(in: rig.host.view.bounds, afterScreenUpdates: false)
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
        try await Task.sleep(nanoseconds: 80_000_000)
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
