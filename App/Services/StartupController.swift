import Foundation
import UserNotifications
import AppTrackingTransparency
import UIKit

enum StartupStage: String { case loading, brandLoading, welcome, notifications, tracking, ready }
struct StartupConsent: Codable, Equatable {
    var acceptedVersion: String?
    var acceptedAt: Date?
    var dataUseSystemManaged = true
    var notificationsCompleted = false
    var trackingCompleted = false
}

@MainActor
protocol StartupPermissions {
    func notifications() async throws
    func tracking() async throws
}
struct SystemStartupPermissions: StartupPermissions {
    func notifications() async throws {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        try await waitForActiveApplication()
        _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
    func tracking() async throws {
        // ATT only presents when active. Data Use is an OS-managed regional prompt;
        // iOS exposes no application API that can force it, so we never imitate it.
        try await waitForActiveApplication()
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }
    private func waitForActiveApplication() async throws {
        while UIApplication.shared.applicationState != .active {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
    }
}

/// Explicit internal-Demo presentation values, not frozen Pawdoku timing.
/// No percentage is inferred from elapsed time, and background time is excluded.
struct StartupPresentationTiming {
    let loadingMinimum: TimeInterval
    let brandMinimum: TimeInterval
    static let demo = Self(loadingMinimum: 0.45, brandMinimum: 0.65)
    static let immediate = Self(loadingMinimum: 0, brandMinimum: 0)
}

@MainActor
protocol StartupResources {
    func prepare() async throws
}

struct BundledStartupResources: StartupResources {
    func prepare() async throws {
        // The model has already decoded local gameplay data. Warm the bundled
        // theme images used by startup and the first screens before permissions.
        // No third-party network, advertising or unprovided audio is loaded here.
        for name in ["CapyMascot", "CapyFace", "CapyCheckIn", "CapySad"] {
            try Task.checkCancellation()
            guard let image = UIImage(named: name), image.size.width > 0, image.size.height > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            await Task.yield()
        }
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
    private let resources: StartupResources
    private let timing: StartupPresentationTiming
    private let skip: Bool
    private var active: Bool
    private var preparing = false
    private var preparationComplete = false
    private var advancing = false
    private var acceptedDelivered = false
    var onAccepted: (() -> Void)?
    var onReady: (() -> Void)?

    static func shouldSkipForTests(arguments: [String], environment: [String: String]) -> Bool {
        // A dedicated first-launch UI test always overrides the host-test convenience bypass.
        guard !arguments.contains("-test-first-launch") else { return false }
        return arguments.contains("-ui-testing") || environment["XCTestConfigurationFilePath"] != nil
    }

    init(directory: URL, permissions: StartupPermissions? = nil, skip: Bool = false,
         resources: StartupResources? = nil, timing: StartupPresentationTiming = .demo,
         active: Bool = true) {
        url = directory.appendingPathComponent("consent.json")
        self.permissions = permissions ?? SystemStartupPermissions(); self.skip = skip
        self.resources = resources ?? BundledStartupResources(); self.timing = timing; self.active = active
        if let saved = try? DurableStateFile<StartupConsent>(url: url).load(),
           saved.acceptedVersion == nil || saved.acceptedAt != nil { consent = saved }
    }
    func setActive(_ value: Bool) { active = value }

    func begin() async {
        guard stage != .ready, !preparing, !advancing else { return }
        errorMessage = nil
        if skip { stage = .ready; onReady?(); return }
        if !preparationComplete {
            preparing = true
            defer { preparing = false }
            do {
                stage = .loading
                try await waitForForeground()
                try await resources.prepare()
                try await holdVisible(for: timing.loadingMinimum)
                stage = .brandLoading
                try await holdVisible(for: timing.brandMinimum)
                preparationComplete = true
            } catch is CancellationError { return }
            catch {
                errorMessage = "The game resources could not be loaded. Please try again."
                return
            }
        }
        if consent.acceptedVersion != Self.consentVersion { stage = .welcome }
        else { notifyAccepted(); await advancePermissions() }
    }
    func accept() async {
        guard stage == .welcome, !advancing else { return }
        errorMessage = nil
        var updated = consent
        updated.acceptedVersion = Self.consentVersion; updated.acceptedAt = Date()
        guard persist(updated) else { return }
        notifyAccepted()
        await advancePermissions()
    }
    private func notifyAccepted() {
        guard !acceptedDelivered else { return }
        acceptedDelivered = true; onAccepted?()
    }
    private func waitForForeground() async throws {
        while !active { try await Task.sleep(nanoseconds: 50_000_000) }
        try Task.checkCancellation()
    }
    private func holdVisible(for duration: TimeInterval) async throws {
        var remaining = max(0, duration)
        while remaining > 0 {
            try await waitForForeground()
            let interval = min(remaining, 0.05)
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if active { remaining -= interval }
        }
        try await waitForForeground()
    }
    private func advancePermissions() async {
        guard !advancing else { return }; advancing = true
        defer { advancing = false }
        do {
            if !consent.notificationsCompleted {
                try await waitForForeground()
                stage = .notifications
                try await permissions.notifications()
                try Task.checkCancellation()
                var updated = consent; updated.notificationsCompleted = true
                guard persist(updated) else { return }
            }
            if !consent.trackingCompleted {
                try await waitForForeground()
                stage = .tracking
                try await permissions.tracking()
                try Task.checkCancellation()
                var updated = consent; updated.trackingCompleted = true
                guard persist(updated) else { return }
            }
            try await waitForForeground()
            stage = .ready; onReady?()
        } catch is CancellationError { return }
        catch {
            errorMessage = "The system permission request could not finish. Please try again."
        }
    }
    private func persist(_ updated: StartupConsent) -> Bool {
        do {
            try DurableStateFile<StartupConsent>(url: url).save(updated)
            consent = updated; return true
        } catch { errorMessage = "Your preferences could not be saved. Please try again."; return false }
    }
}
