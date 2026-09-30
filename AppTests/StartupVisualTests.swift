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
        let background = try capture(rig, name: "welcome-transition-02-background-settled")
        XCTAssertEqual(controller.stage, .welcome)
        XCTAssertNil(controller.consent.acceptedVersion)
        XCTAssertTrue(permissions.calls.isEmpty)
        lifecycle.phase = .active
        lifecycle.reduceMotion = true
        try await Task.sleep(nanoseconds: 260_000_000)
        let reduced = try capture(rig, name: "welcome-transition-03-reduce-motion-view-override")
        XCTAssertEqual(background, reduced, "Lifecycle cleanup must retain the complete unaccepted Welcome card.")
        lifecycle.reduceMotion = false
        try await Task.sleep(nanoseconds: 260_000_000)
        let settled = try capture(rig, name: "welcome-transition-04-foreground-settled")
        XCTAssertEqual(reduced, settled, "Re-enabling motion cannot restart loading, hide Welcome, or change its final layout.")
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
