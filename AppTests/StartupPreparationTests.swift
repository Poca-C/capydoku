import XCTest
import Combine
@testable import Capydoku

private enum StartupPreparationTestError: Error { case unavailable, timedOut }

@MainActor private final class StartupPreparationGate {
    var result: Result<Void, Error>?
    func wait() async throws {
        while result == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        try Task.checkCancellation()
        try result!.get()
    }
    func succeed() { result = .success(()) }
    func fail() { result = .failure(StartupPreparationTestError.unavailable) }
}

@MainActor private final class PreparationResources: StartupResources {
    var calls = 0
    var gates: [StartupPreparationGate] = []
    func prepare() async throws {
        calls += 1
        if !gates.isEmpty { try await gates.removeFirst().wait() }
    }
}

@MainActor private final class PreparationPermissions: StartupPermissions {
    var calls: [String] = []
    var notificationGates: [StartupPreparationGate] = []
    var trackingGates: [StartupPreparationGate] = []
    func notifications() async throws {
        calls.append("notifications")
        if !notificationGates.isEmpty { try await notificationGates.removeFirst().wait() }
    }
    func tracking() async throws {
        calls.append("tracking")
        if !trackingGates.isEmpty { try await trackingGates.removeFirst().wait() }
    }
}

final class StartupPreparationTests: XCTestCase {
    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StartupPreparation-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Startup did not reach the expected controlled boundary")
                throw StartupPreparationTestError.timedOut
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func savedConsent(_ root: URL) throws -> StartupConsent? {
        try DurableStateFile<StartupConsent>(url: root.appendingPathComponent("consent.json")).load()
    }

    @MainActor private func acceptInSave(_ root: URL, notifications: Bool = false, tracking: Bool = false) throws {
        var consent = StartupConsent()
        consent.acceptedVersion = StartupController.consentVersion
        consent.acceptedAt = Date(timeIntervalSince1970: 1_800_000_000)
        consent.notificationsCompleted = notifications
        consent.trackingCompleted = tracking
        try DurableStateFile<StartupConsent>(url: root.appendingPathComponent("consent.json")).save(consent)
    }

    @MainActor func testResourcesAndBothPresentationStagesPrecedeWelcomeAndAnyPermission() async throws {
        let root = directory(), resources = PreparationResources(), permissions = PreparationPermissions()
        let gate = StartupPreparationGate(); resources.gates = [gate]
        let controller = StartupController(directory: root, permissions: permissions,
            resources: resources, timing: StartupPresentationTiming(loadingMinimum: 0, brandMinimum: 0.05))
        var stages: [StartupStage] = []
        let observation = controller.$stage.sink { stages.append($0) }
        defer { observation.cancel() }
        var accepted = 0, ready = 0
        controller.onAccepted = { accepted += 1 }; controller.onReady = { ready += 1 }
        let beginning = Task { await controller.begin() }
        defer { beginning.cancel() }
        try await waitUntil { resources.calls == 1 }
        XCTAssertEqual(controller.stage, .loading)
        XCTAssertTrue(permissions.calls.isEmpty)
        await controller.accept()
        XCTAssertNil(controller.consent.acceptedVersion)
        gate.succeed()
        try await waitUntil { controller.stage == .brandLoading }
        XCTAssertTrue(permissions.calls.isEmpty)
        XCTAssertEqual(accepted, 0)
        await beginning.value
        XCTAssertEqual(controller.stage, .welcome)
        XCTAssertTrue(stages.contains(.loading))
        XCTAssertTrue(stages.contains(.brandLoading))
        XCTAssertTrue(permissions.calls.isEmpty)
        XCTAssertEqual(ready, 0)
        XCTAssertNil(try savedConsent(root))
    }

    @MainActor func testResourceCompletionInBackgroundCannotAdvanceOrConsumeLoadingDisplayTime() async throws {
        let resources = PreparationResources(), permissions = PreparationPermissions()
        let gate = StartupPreparationGate(); resources.gates = [gate]
        let controller = StartupController(directory: directory(), permissions: permissions,
            resources: resources, timing: StartupPresentationTiming(loadingMinimum: 0.06, brandMinimum: 0.02))
        let beginning = Task { await controller.begin() }
        defer { beginning.cancel() }
        try await waitUntil { resources.calls == 1 }
        controller.setActive(false)
        gate.succeed()
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(controller.stage, .loading)
        XCTAssertTrue(permissions.calls.isEmpty)
        controller.setActive(true)
        XCTAssertEqual(controller.stage, .loading)
        await beginning.value
        XCTAssertEqual(controller.stage, .welcome)
        XCTAssertEqual(resources.calls, 1)
        XCTAssertTrue(permissions.calls.isEmpty)
    }

    @MainActor func testBrandPresentationPausesWhileBackgroundedAndAlreadyAcceptedPermissionsWait() async throws {
        let root = directory(), resources = PreparationResources(), permissions = PreparationPermissions()
        try acceptInSave(root)
        let controller = StartupController(directory: root, permissions: permissions,
            resources: resources, timing: StartupPresentationTiming(loadingMinimum: 0, brandMinimum: 0.08))
        let beginning = Task { await controller.begin() }
        defer { beginning.cancel() }
        try await waitUntil { controller.stage == .brandLoading }
        controller.setActive(false)
        try await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertEqual(controller.stage, .brandLoading)
        XCTAssertTrue(permissions.calls.isEmpty)
        controller.setActive(true)
        XCTAssertEqual(controller.stage, .brandLoading)
        await beginning.value
        XCTAssertEqual(controller.stage, .ready)
        XCTAssertEqual(permissions.calls, ["notifications", "tracking"])
    }

    @MainActor func testDuplicateBeginCannotReenterResourceOrPermissionWorkAndCallbacksFireOnce() async throws {
        let root = directory(), resources = PreparationResources(), permissions = PreparationPermissions()
        try acceptInSave(root)
        let resourceGate = StartupPreparationGate(), permissionGate = StartupPreparationGate()
        resources.gates = [resourceGate]; permissions.notificationGates = [permissionGate]
        let controller = StartupController(directory: root, permissions: permissions, resources: resources, timing: .immediate)
        var accepted = 0, ready = 0
        controller.onAccepted = { accepted += 1 }; controller.onReady = { ready += 1 }
        let beginning = Task { await controller.begin() }
        defer { beginning.cancel() }
        try await waitUntil { resources.calls == 1 }
        await controller.begin(); await controller.begin()
        XCTAssertEqual(resources.calls, 1)
        resourceGate.succeed()
        try await waitUntil { permissions.calls == ["notifications"] }
        await controller.begin(); await controller.accept()
        XCTAssertEqual(permissions.calls, ["notifications"])
        permissionGate.succeed()
        await beginning.value
        await controller.begin(); await controller.accept()
        XCTAssertEqual(resources.calls, 1)
        XCTAssertEqual(permissions.calls, ["notifications", "tracking"])
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(ready, 1)
    }

    @MainActor func testResourceFailureAndCancellationDoNotCompleteStartupAndCanRetry() async throws {
        let root = directory(), resources = PreparationResources(), permissions = PreparationPermissions()
        let failed = StartupPreparationGate(), cancelled = StartupPreparationGate()
        failed.fail(); resources.gates = [failed, cancelled]
        let controller = StartupController(directory: root, permissions: permissions, resources: resources, timing: .immediate)
        await controller.begin()
        XCTAssertEqual(controller.stage, .loading)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(permissions.calls.isEmpty)
        let retry = Task { await controller.begin() }
        defer { retry.cancel() }
        try await waitUntil { resources.calls == 2 }
        retry.cancel(); await retry.value
        XCTAssertNotEqual(controller.stage, .ready)
        XCTAssertNil(controller.consent.acceptedAt)
        XCTAssertNil(try savedConsent(root))
        await controller.begin()
        XCTAssertEqual(resources.calls, 3)
        XCTAssertEqual(controller.stage, .welcome)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(permissions.calls.isEmpty)
    }

    @MainActor func testBrandCancellationCannotEnterWelcomeUntilPreparationResumes() async throws {
        let resources = PreparationResources(), permissions = PreparationPermissions()
        let controller = StartupController(directory: directory(), permissions: permissions,
            resources: resources, timing: StartupPresentationTiming(loadingMinimum: 0, brandMinimum: 0.06))
        let beginning = Task { await controller.begin() }
        defer { beginning.cancel() }
        try await waitUntil { controller.stage == .brandLoading }
        beginning.cancel(); await beginning.value
        XCTAssertNotEqual(controller.stage, .ready)
        XCTAssertTrue(permissions.calls.isEmpty)
        await controller.begin()
        XCTAssertEqual(controller.stage, .welcome)
        XCTAssertTrue(permissions.calls.isEmpty)
    }

    @MainActor func testPermissionThrowDoesNotMarkCompletionOrReplayLoadingStagesOnRetry() async throws {
        let root = directory(), resources = PreparationResources(), permissions = PreparationPermissions()
        let failed = StartupPreparationGate(); failed.fail(); permissions.notificationGates = [failed]
        let controller = StartupController(directory: root, permissions: permissions, resources: resources, timing: .immediate)
        var accepted = 0, ready = 0
        controller.onAccepted = { accepted += 1 }; controller.onReady = { ready += 1 }
        await controller.begin(); await controller.accept()
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.consent.notificationsCompleted)
        XCTAssertFalse(controller.consent.trackingCompleted)
        XCTAssertFalse(try XCTUnwrap(savedConsent(root)).notificationsCompleted)
        XCTAssertEqual(permissions.calls, ["notifications"])
        var retryStages: [StartupStage] = []
        let observation = controller.$stage.sink { retryStages.append($0) }
        defer { observation.cancel() }
        await controller.begin()
        XCTAssertEqual(controller.stage, .ready)
        XCTAssertEqual(resources.calls, 1)
        XCTAssertFalse(retryStages.contains(.loading))
        XCTAssertFalse(retryStages.contains(.brandLoading))
        XCTAssertEqual(permissions.calls, ["notifications", "notifications", "tracking"])
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(ready, 1)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor func testExistingNotificationRequestMayFinishInBackgroundButTrackingCannotStartThere() async throws {
        let root = directory(), resources = PreparationResources(), permissions = PreparationPermissions()
        let notifications = StartupPreparationGate(); permissions.notificationGates = [notifications]
        let controller = StartupController(directory: root, permissions: permissions, resources: resources, timing: .immediate)
        await controller.begin()
        let accepting = Task { await controller.accept() }
        defer { accepting.cancel() }
        try await waitUntil { permissions.calls == ["notifications"] }
        controller.setActive(false)
        notifications.succeed()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(permissions.calls, ["notifications"])
        XCTAssertNotEqual(controller.stage, .ready)
        controller.setActive(true)
        await accepting.value
        XCTAssertEqual(controller.stage, .ready)
        XCTAssertEqual(permissions.calls, ["notifications", "tracking"])
        XCTAssertTrue(controller.consent.notificationsCompleted)
        XCTAssertTrue(controller.consent.trackingCompleted)
    }

    @MainActor func testInactiveAcceptedLaunchNeverRequestsPermissionsUntilForeground() async throws {
        let root = directory(), resources = PreparationResources(), permissions = PreparationPermissions()
        try acceptInSave(root)
        let controller = StartupController(directory: root, permissions: permissions,
            resources: resources, timing: .immediate, active: false)
        var accepted = 0, ready = 0
        controller.onAccepted = { accepted += 1 }; controller.onReady = { ready += 1 }
        let beginning = Task { await controller.begin() }
        defer { beginning.cancel() }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.stage, .loading)
        XCTAssertTrue(permissions.calls.isEmpty)
        XCTAssertEqual(accepted, 0)
        XCTAssertEqual(ready, 0)
        controller.setActive(true)
        await beginning.value
        XCTAssertEqual(controller.stage, .ready)
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(ready, 1)
    }

    @MainActor func testPermissionCompletionWriteFailureKeepsStepIncompleteAndRetriesWithoutReloadingResources() async throws {
        let root = directory(), resources = PreparationResources(), permissions = PreparationPermissions()
        let notifications = StartupPreparationGate(); permissions.notificationGates = [notifications]
        let controller = StartupController(directory: root, permissions: permissions, resources: resources, timing: .immediate)
        var accepted = 0, ready = 0
        controller.onAccepted = { accepted += 1 }; controller.onReady = { ready += 1 }
        await controller.begin()
        let accepting = Task { await controller.accept() }
        defer { accepting.cancel() }
        try await waitUntil { permissions.calls == ["notifications"] }
        let backup = root.appendingPathComponent("consent.json.backup")
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        notifications.succeed(); await accepting.value
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.consent.notificationsCompleted)
        XCTAssertFalse(try XCTUnwrap(savedConsent(root)).notificationsCompleted)
        XCTAssertEqual(permissions.calls, ["notifications"])
        XCTAssertEqual(ready, 0)
        try FileManager.default.removeItem(at: backup)
        await controller.begin()
        XCTAssertEqual(controller.stage, .ready)
        XCTAssertEqual(resources.calls, 1)
        XCTAssertEqual(permissions.calls, ["notifications", "notifications", "tracking"])
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(ready, 1)
    }

    @MainActor func testTrackingCancellationPreservesCompletedNotificationsAndNewControllerPreparesAgain() async throws {
        let root = directory(), resources = PreparationResources(), permissions = PreparationPermissions()
        let tracking = StartupPreparationGate(); permissions.trackingGates = [tracking]
        let controller = StartupController(directory: root, permissions: permissions, resources: resources, timing: .immediate)
        await controller.begin()
        let accepting = Task { await controller.accept() }
        defer { accepting.cancel() }
        try await waitUntil { permissions.calls == ["notifications", "tracking"] }
        accepting.cancel(); await accepting.value
        XCTAssertTrue(controller.consent.notificationsCompleted)
        XCTAssertFalse(controller.consent.trackingCompleted)
        let saved = try XCTUnwrap(savedConsent(root))
        XCTAssertTrue(saved.notificationsCompleted)
        XCTAssertFalse(saved.trackingCompleted)
        let nextResources = PreparationResources(), nextPermissions = PreparationPermissions()
        let nextGate = StartupPreparationGate(); nextResources.gates = [nextGate]
        let restored = StartupController(directory: root, permissions: nextPermissions, resources: nextResources, timing: .immediate)
        let beginning = Task { await restored.begin() }
        defer { beginning.cancel() }
        try await waitUntil { nextResources.calls == 1 }
        XCTAssertEqual(restored.stage, .loading)
        XCTAssertTrue(nextPermissions.calls.isEmpty)
        nextGate.succeed(); await beginning.value
        XCTAssertEqual(restored.stage, .ready)
        XCTAssertEqual(nextPermissions.calls, ["tracking"])
        XCTAssertTrue(restored.consent.trackingCompleted)
    }

    @MainActor func testCompletedConsentStillPreparesResourcesOnEveryNewControllerWithoutPermissionReplay() async throws {
        let root = directory()
        try acceptInSave(root, notifications: true, tracking: true)
        for _ in 0..<2 {
            let resources = PreparationResources(), permissions = PreparationPermissions()
            let controller = StartupController(directory: root, permissions: permissions, resources: resources, timing: .immediate)
            var accepted = 0, ready = 0
            controller.onAccepted = { accepted += 1 }; controller.onReady = { ready += 1 }
            await controller.begin(); await controller.begin()
            XCTAssertEqual(resources.calls, 1)
            XCTAssertTrue(permissions.calls.isEmpty)
            XCTAssertEqual(controller.stage, .ready)
            XCTAssertEqual(accepted, 1)
            XCTAssertEqual(ready, 1)
        }
    }
}
