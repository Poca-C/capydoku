import Foundation
import CoreFoundation

enum AppEnvironment: String, Codable, CaseIterable {
    case demo = "internal_demo"
    case testing, staging, production, unconfigured
}

/// Build-owned routing only. Launch arguments and downloaded gameplay settings
/// cannot turn one environment into another or enable an unconfigured service.
struct AppBuildConfiguration: Encodable, Equatable {
    let environment: AppEnvironment
    let bundleIdentifier: String
    let analyticsEnabled: Bool
    let remoteConfigurationEndpoint: URL?

    static var current: Self {
        Self(info: Bundle.main.infoDictionary ?? [:], bundleIdentifier: Bundle.main.bundleIdentifier ?? "unconfigured")
    }

    init(info: [String: Any], bundleIdentifier: String) {
        environment = (info["CapydokuEnvironment"] as? String).flatMap(AppEnvironment.init(rawValue:)) ?? .unconfigured
        self.bundleIdentifier = bundleIdentifier
        analyticsEnabled = environment != .unconfigured && Self.enabled(info["CapydokuAnalyticsEnabled"])
        if environment != .unconfigured,
           Self.enabled(info["CapydokuRemoteConfigurationEnabled"]),
           info["CapydokuRemoteConfigurationEnvironment"] as? String == environment.rawValue,
           let raw = info["CapydokuRemoteConfigurationURL"] as? String,
           let url = URL(string: raw), url.scheme == "https", let host = url.host, !host.isEmpty,
           url.user == nil, url.password == nil, url.fragment == nil {
            remoteConfigurationEndpoint = url
        } else { remoteConfigurationEndpoint = nil }
    }

    private static func enabled(_ value: Any?) -> Bool {
        if let value = value as? String { return value == "YES" }
        if let value = value as? NSNumber {
            // Reject numbers such as 2 rather than silently interpreting them as true.
            return CFGetTypeID(value) == CFBooleanGetTypeID() && value.boolValue
        }
        return false
    }

    var analyticsEnvironment: String {
        environment == .demo ? "internal-demo-offline" : environment.rawValue + "-offline"
    }
    var storageDirectoryName: String {
        environment == .demo ? "Capydoku" : "Capydoku-" + environment.rawValue
    }
    var identityServicePrefix: String {
        // The original Demo alone retains access to its historical identity.
        if environment == .demo && bundleIdentifier == "com.capydoku.demo" {
            return "com.capydoku.demo.analytics.namespace."
        }
        return bundleIdentifier + ".analytics." + environment.rawValue + ".namespace."
    }
    var permitsLegacyDemoIdentity: Bool {
        environment == .demo && bundleIdentifier == "com.capydoku.demo"
    }
}
