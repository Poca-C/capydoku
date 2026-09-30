import Foundation
import UserNotifications
import AppTrackingTransparency
import UIKit

enum StartupStage: String { case loading, welcome, notifications, tracking, ready }
struct StartupConsent: Codable, Equatable {
    var acceptedVersion: String?
    var acceptedAt: Date?
    var dataUseSystemManaged = true
    var notificationsCompleted = false
    var trackingCompleted = false
}

@MainActor
protocol StartupPermissions {
    func notifications() async
    func tracking() async
}
struct SystemStartupPermissions: StartupPermissions {
    func notifications() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
    func tracking() async {
        // ATT only presents when active. Data Use is an OS-managed regional prompt;
        // iOS exposes no application API that can force it, so we never imitate it.
        while UIApplication.shared.applicationState != .active {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
        }
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }
}

@MainActor
final class StartupController: ObservableObject {
    static let consentVersion = "internal-demo-review-v1"
    @Published private(set) var stage: StartupStage = .loading
    @Published private(set) var consent = StartupConsent()
    @Published var errorMessage: String?
    private let url: URL
    private let permissions: StartupPermissions
    private let skip: Bool
    private var begun = false
    private var advancing = false
    var onAccepted: (() -> Void)?
    var onReady: (() -> Void)?

    static func shouldSkipForTests(arguments: [String], environment: [String: String]) -> Bool {
        // A dedicated first-launch UI test always overrides the host-test convenience bypass.
        guard !arguments.contains("-test-first-launch") else { return false }
        return arguments.contains("-ui-testing") || environment["XCTestConfigurationFilePath"] != nil
    }

    init(directory: URL, permissions: StartupPermissions? = nil, skip: Bool = false) {
        url = directory.appendingPathComponent("consent.json")
        self.permissions = permissions ?? SystemStartupPermissions(); self.skip = skip
        if let saved = try? DurableStateFile<StartupConsent>(url: url).load(),
           saved.acceptedVersion == nil || saved.acceptedAt != nil { consent = saved }
    }
    func begin() async {
        guard !begun || (consent.acceptedVersion == Self.consentVersion && stage != .ready && !advancing) else { return }; begun = true
        if skip { stage = .ready; return }
        // Resource loading is complete before permissions. This short brand transition
        // is cancellable and never waits for a third-party SDK or a network response.
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { begun = false; return }
        if consent.acceptedVersion != Self.consentVersion { stage = .welcome }
        else { onAccepted?(); await advancePermissions() }
    }
    func accept() async {
        guard stage == .welcome, !advancing else { return }
        var updated = consent
        updated.acceptedVersion = Self.consentVersion; updated.acceptedAt = Date()
        guard persist(updated) else { return }
        onAccepted?()
        await advancePermissions()
    }
    private func advancePermissions() async {
        guard !advancing else { return }; advancing = true
        defer { advancing = false }
        if !consent.notificationsCompleted {
            stage = .notifications
            await permissions.notifications()
            guard !Task.isCancelled else { return }
            var updated = consent; updated.notificationsCompleted = true
            guard persist(updated) else { stage = .welcome; return }
        }
        if !consent.trackingCompleted {
            stage = .tracking
            await permissions.tracking()
            guard !Task.isCancelled else { return }
            var updated = consent; updated.trackingCompleted = true
            guard persist(updated) else { stage = .welcome; return }
        }
        stage = .ready; onReady?()
    }
    private func persist(_ updated: StartupConsent) -> Bool {
        do {
            try DurableStateFile<StartupConsent>(url: url).save(updated)
            consent = updated; return true
        } catch { errorMessage = "Your preferences could not be saved. Please try again."; return false }
    }
}
