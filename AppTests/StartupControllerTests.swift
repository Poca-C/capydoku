import XCTest
@testable import Capydoku

@MainActor private final class OrderedPermissions: StartupPermissions {
    var calls: [String] = []
    func notifications() async { calls.append("notifications") }
    func tracking() async { calls.append("tracking") }
}
@MainActor private final class InterruptedPermissions: StartupPermissions {
    var calls: [String] = []
    func notifications() async {
        calls.append("notifications")
        if calls.count == 1 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
    }
    func tracking() async { calls.append("tracking") }
}
final class StartupControllerTests: XCTestCase {
    @MainActor func testAcceptPrecedesPermissionsAndRestartsNeverRequestAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let permissions = OrderedPermissions()
        let controller = StartupController(directory: root, permissions: permissions)
        var events: [String] = []
        controller.onAccepted = { events.append("accepted"); XCTAssertTrue(permissions.calls.isEmpty) }
        controller.onReady = { events.append("ready"); XCTAssertEqual(permissions.calls, ["notifications", "tracking"]) }
        await controller.begin()
        XCTAssertEqual(controller.stage, .welcome)
        XCTAssertTrue(permissions.calls.isEmpty)
        await controller.accept()
        await controller.accept()
        XCTAssertEqual(events, ["accepted", "ready"])
        XCTAssertEqual(controller.stage, .ready)
        XCTAssertNotNil(controller.consent.acceptedAt)
        let restored = StartupController(directory: root, permissions: permissions)
        await restored.begin()
        XCTAssertEqual(restored.stage, .ready)
        XCTAssertEqual(permissions.calls, ["notifications", "tracking"])
    }
    @MainActor func testFailedConsentWriteDoesNotRequestSystemPermissions() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not a directory".utf8).write(to: file)
        let permissions = OrderedPermissions()
        let controller = StartupController(directory: file, permissions: permissions)
        await controller.begin(); await controller.accept()
        XCTAssertEqual(controller.stage, .welcome)
        XCTAssertTrue(permissions.calls.isEmpty)
        XCTAssertNil(controller.consent.acceptedAt)
        XCTAssertNotNil(controller.errorMessage)
    }

    @MainActor func testDamagedConsentRestoresLatestBackupWithoutRequestingAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let permissions = OrderedPermissions()
        let controller = StartupController(directory: root, permissions: permissions)
        await controller.begin(); await controller.accept()
        try Data("damaged".utf8).write(to: root.appendingPathComponent("consent.json"))
        let restored = StartupController(directory: root, permissions: permissions)
        await restored.begin()
        XCTAssertEqual(restored.stage, .ready)
        XCTAssertEqual(restored.consent, controller.consent)
        XCTAssertEqual(permissions.calls, ["notifications", "tracking"])
    }

    @MainActor func testFirstLaunchOverrideCannotBeHiddenByHostTestEnvironment() {
        let host = ["XCTestConfigurationFilePath": "test-host"]
        XCTAssertFalse(StartupController.shouldSkipForTests(arguments: ["-ui-testing", "-test-first-launch"], environment: host))
        XCTAssertFalse(StartupController.shouldSkipForTests(arguments: ["-test-first-launch"], environment: host))
        XCTAssertTrue(StartupController.shouldSkipForTests(arguments: [], environment: host))
        XCTAssertTrue(StartupController.shouldSkipForTests(arguments: ["-ui-testing"], environment: [:]))
        XCTAssertFalse(StartupController.shouldSkipForTests(arguments: [], environment: [:]))
    }

    @MainActor func testCancellationDoesNotPretendPermissionCompletedAndCanResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let permissions = InterruptedPermissions()
        let controller = StartupController(directory: root, permissions: permissions)
        await controller.begin()
        let accepting = Task { await controller.accept() }
        try await Task.sleep(nanoseconds: 20_000_000)
        accepting.cancel(); await accepting.value
        XCTAssertFalse(controller.consent.notificationsCompleted)
        XCTAssertFalse(controller.consent.trackingCompleted)
        await controller.begin()
        XCTAssertEqual(controller.stage, .ready)
        XCTAssertEqual(permissions.calls, ["notifications", "notifications", "tracking"])
    }
}
