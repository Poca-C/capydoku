import Foundation
import CryptoKit
import CapydokuCore

struct GameplayConfigurationTarget: Codable, Equatable, Sendable {
    var platform: String = "iOS"
    var appVersion: String
    var environment: String
    static var current: Self {
        Self(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "internal",
             environment: "internal_demo")
    }
}

struct GameplayConfigurationRequest {
    var target: GameplayConfigurationTarget
    var baselineSHA256: String
    var currentConfigVersion: String?
    var currentRevision: Int
}

/// Internal adapter contract, not a claim about a supplier SDK's wire format.
/// The payload is the exact imported JSON bytes; its checksum has no canonical-JSON ambiguity.
struct GameplayConfigurationResponse: Codable, Sendable {
    var schemaVersion: Int = 1
    var target: GameplayConfigurationTarget
    var revision: Int
    var configurationData: Data
    var sha256: String
}

protocol GameplayConfigurationProvider {
    /// May complete on any queue. Completion is a final response; the store rejects
    /// duplicate, cancelled and late callbacks. Return a cancellation closure when supported.
    func fetch(_ request: GameplayConfigurationRequest,
               completion: @escaping (Result<GameplayConfigurationResponse, Error>) -> Void) -> (() -> Void)?
}

struct GameplayConfigurationDiagnostics: Codable {
    enum Source: String, Codable { case unavailable, bundled, cache, remote }
    var target: GameplayConfigurationTarget
    var source: Source = .unavailable
    var configVersion: String?
    var revision = 0
    var fetchedAt: Date?
    var isRefreshing = false
    var lastError: String?
    var recoveredBackup = false
}

private struct ConfigurationFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor
final class GameplayConfigurationStore {
    private struct CacheRecord: Codable, Sendable {
        var schemaVersion = 1
        var response: GameplayConfigurationResponse
        var fetchedAt: Date
        var acceptedVersionHashes: [String: String]
    }
    private struct CacheEnvelope: Codable {
        var schemaVersion = 1
        var payload: Data
        var checksum: String
    }
    private struct StorageContext: Sendable {
        var target: GameplayConfigurationTarget
        var baseline: ReferenceGameplayBaseline
        var bundledVersion: String?
        var bundledSHA256: String
        var cacheURL: URL
        var backupURL: URL { cacheURL.appendingPathExtension("backup") }
    }
    private(set) var configuration: ReferenceGameplayConfiguration?
    private(set) var diagnostics: GameplayConfigurationDiagnostics
    var onChange: ((ReferenceGameplayConfiguration?) -> Void)?
    private let target: GameplayConfigurationTarget
    private let provider: GameplayConfigurationProvider?
    private let timeout: TimeInterval
    private let uptime: () -> TimeInterval
    private let cacheURL: URL
    private var backupURL: URL { cacheURL.appendingPathExtension("backup") }
    private var baseline: ReferenceGameplayBaseline?
    private var storage: StorageContext?
    private var currentPayloadSHA256: String?
    private var acceptedVersionHashes: [String: String] = [:]
    private var requestID: UUID?
    private var processingResponse = false
    private var cancelRequest: (() -> Void)?
    private var deadline: DispatchWorkItem?
    private var nextAttemptUptime: TimeInterval = 0
    nonisolated private static let maximumPayloadBytes = 2 * 1_024 * 1_024

    init(directory: URL, target: GameplayConfigurationTarget, bundledData: Data?,
         provider: GameplayConfigurationProvider? = nil, timeout: TimeInterval = 5,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.target = target; self.provider = provider
        self.uptime = uptime
        self.timeout = timeout.isFinite ? min(30, max(0.01, timeout)) : 5
        diagnostics = GameplayConfigurationDiagnostics(target: target)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let namespace = Self.digest((try? encoder.encode(target)) ?? Data())
        cacheURL = directory.appendingPathComponent("remote-configuration", isDirectory: true)
            .appendingPathComponent(namespace + ".json")
        guard target.platform == "iOS", !target.appVersion.isEmpty, !target.environment.isEmpty else {
            diagnostics.lastError = "The configuration target is invalid."; return
        }
        guard let bundledData else {
            diagnostics.lastError = "No frozen bundled baseline is installed; remote configuration remains disabled."; return
        }
        do {
            guard bundledData.count <= Self.maximumPayloadBytes else { throw ConfigurationFailure(message: "Bundled configuration exceeds its size budget.") }
            let bundled = try ReferenceGameplayConfiguration.load(data: bundledData)
            try bundled.validate(requireFrozen: true)
            configuration = bundled; baseline = bundled.baseline
            currentPayloadSHA256 = Self.digest(bundledData)
            if let version = bundled.configVersion { acceptedVersionHashes[version] = Self.digest(bundledData) }
            if let baseline = bundled.baseline {
                storage = StorageContext(target: target, baseline: baseline, bundledVersion: bundled.configVersion,
                                         bundledSHA256: Self.digest(bundledData), cacheURL: cacheURL)
            }
            diagnostics.source = .bundled; diagnostics.configVersion = bundled.configVersion
        } catch { diagnostics.lastError = error.localizedDescription; return }
        loadCachedConfiguration()
    }

    deinit { deadline?.cancel(); cancelRequest?() }

    /// No network wait on startup/navigation. Foreground retries have a technical
    /// 30-second cooldown, separate from every gameplay/ad frequency configuration.
    func refresh(force: Bool = false) {
        guard requestID == nil, force || uptime() >= nextAttemptUptime else { return }
        guard let baseline, let configuration else { return }
        guard let provider else {
            diagnostics.lastError = "No remote configuration provider is configured."; return
        }
        let id = UUID(); requestID = id; diagnostics.isRefreshing = true
        nextAttemptUptime = uptime() + 30
        let request = GameplayConfigurationRequest(target: target, baselineSHA256: baseline.sourceArchiveSHA256,
                                                   currentConfigVersion: configuration.configVersion,
                                                   currentRevision: diagnostics.revision)
        let work = DispatchWorkItem { [weak self] in
            self?.finish(id: id, result: .failure(ConfigurationFailure(message: "Remote configuration request timed out.")))
        }
        deadline = work; DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        cancelRequest = provider.fetch(request) { [weak self] result in
            Task { @MainActor [weak self] in self?.finish(id: id, result: result) }
        }
    }

    private func finish(id: UUID, result: Result<GameplayConfigurationResponse, Error>) {
        guard id == requestID, !processingResponse else { return }
        // Claim the callback before cancellation. The network deadline stops when
        // its final response arrives; validation and writes run off the UI thread.
        processingResponse = true; deadline?.cancel(); deadline = nil
        let cancel = cancelRequest; cancelRequest = nil; cancel?()
        guard let storage else { complete(id: id, result: .failure(ConfigurationFailure(message: "Frozen baseline is unavailable."))); return }
        let revision = diagnostics.revision, version = configuration?.configVersion, checksum = currentPayloadSHA256
        let versionHashes = acceptedVersionHashes
        Task.detached(priority: .utility) { [weak self] in
            let processed: Result<(CacheRecord, ReferenceGameplayConfiguration), Error> = Result {
                let response = try result.get()
                let value = try Self.validated(response, context: storage)
                guard response.revision >= revision else { throw ConfigurationFailure(message: "Stale configuration revision rejected.") }
                if response.revision == revision, response.sha256 != checksum {
                    throw ConfigurationFailure(message: "A configuration revision cannot change its payload.")
                }
                if value.configVersion == version, response.sha256 != checksum {
                    throw ConfigurationFailure(message: "A configuration version cannot be reused for changed contents.")
                }
                var accepted = versionHashes
                if let name = value.configVersion {
                    if let previous = accepted[name], previous != response.sha256 {
                        throw ConfigurationFailure(message: "A previously accepted configuration version cannot be reused for changed contents.")
                    }
                    accepted[name] = response.sha256
                }
                let record = CacheRecord(response: response, fetchedAt: Date(), acceptedVersionHashes: accepted)
                // Publish only after the cache commits, so cold starts agree.
                try Self.persist(record, context: storage)
                return (record, value)
            }
            await self?.complete(id: id, result: processed)
        }
    }

    private func complete(id: UUID, result: Result<(CacheRecord, ReferenceGameplayConfiguration), Error>) {
        guard requestID == id else { return }
        requestID = nil; processingResponse = false; diagnostics.isRefreshing = false
        switch result {
        case .success(let (record, value)):
            configuration = value; currentPayloadSHA256 = record.response.sha256
            acceptedVersionHashes = record.acceptedVersionHashes
            diagnostics.source = .remote; diagnostics.configVersion = value.configVersion
            diagnostics.revision = record.response.revision; diagnostics.fetchedAt = record.fetchedAt
            diagnostics.lastError = nil; diagnostics.recoveredBackup = false
        case .failure(let error): diagnostics.lastError = error.localizedDescription
        }
        onChange?(configuration)
    }

    nonisolated private static func validated(_ response: GameplayConfigurationResponse, context: StorageContext) throws -> ReferenceGameplayConfiguration {
        guard response.schemaVersion == 1, response.target == context.target, response.revision > 0,
              response.configurationData.count <= Self.maximumPayloadBytes,
              response.sha256 == Self.digest(response.configurationData) else {
            throw ConfigurationFailure(message: "Configuration schema, target, revision, size or checksum is invalid.")
        }
        let value = try ReferenceGameplayConfiguration.load(data: response.configurationData)
        try value.validate(requireFrozen: true)
        guard value.baseline == context.baseline else {
            throw ConfigurationFailure(message: "A remote response cannot replace the project's approved frozen baseline.")
        }
        if value.configVersion == context.bundledVersion, response.sha256 != context.bundledSHA256 {
            throw ConfigurationFailure(message: "The bundled configuration version cannot be reused for changed contents.")
        }
        return value
    }

    nonisolated private static func read(_ url: URL, context: StorageContext) throws -> (CacheRecord, ReferenceGameplayConfiguration) {
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumPayloadBytes * 3 else { throw ConfigurationFailure(message: "Configuration cache exceeds its size budget.") }
        let envelope = try JSONDecoder().decode(CacheEnvelope.self, from: data)
        guard envelope.schemaVersion == 1, envelope.checksum == digest(envelope.payload) else {
            throw ConfigurationFailure(message: "Configuration cache integrity check failed.")
        }
        let record = try JSONDecoder().decode(CacheRecord.self, from: envelope.payload)
        guard record.schemaVersion == 1, record.fetchedAt.timeIntervalSince1970.isFinite else {
            throw ConfigurationFailure(message: "Configuration cache metadata is invalid.")
        }
        let value = try validated(record.response, context: context)
        guard let version = value.configVersion, record.acceptedVersionHashes[version] == record.response.sha256,
              context.bundledVersion.map({ record.acceptedVersionHashes[$0] == context.bundledSHA256 }) == true,
              record.acceptedVersionHashes.allSatisfy({ !$0.key.isEmpty && $0.value.count == 64 && $0.value.allSatisfy { $0.isHexDigit && !$0.isUppercase } }) else {
            throw ConfigurationFailure(message: "Configuration version history is invalid.")
        }
        return (record, value)
    }
    private func loadCachedConfiguration() {
        var rejected: [String] = []
        guard let storage else { return }
        for url in [cacheURL, backupURL] where FileManager.default.fileExists(atPath: url.path) {
            do {
                let (record, value) = try Self.read(url, context: storage)
                configuration = value; currentPayloadSHA256 = record.response.sha256
                acceptedVersionHashes = record.acceptedVersionHashes
                diagnostics.source = .cache; diagnostics.configVersion = value.configVersion
                diagnostics.revision = record.response.revision; diagnostics.fetchedAt = record.fetchedAt
                diagnostics.recoveredBackup = url == backupURL
                diagnostics.lastError = rejected.isEmpty ? nil : "Invalid primary configuration cache; restored the previous valid cache."
                return
            } catch { rejected.append(error.localizedDescription) }
        }
        if !rejected.isEmpty { diagnostics.lastError = "No valid configuration cache; using bundled defaults. " + rejected.joined(separator: " ") }
    }
    nonisolated private static func persist(_ record: CacheRecord, context: StorageContext) throws {
        let manager = FileManager.default
        let cacheURL = context.cacheURL, backupURL = context.backupURL
        try manager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Never overwrite a valid backup with a corrupt primary.
        if let (previous, _) = try? read(cacheURL, context: context) {
            try bytes(for: previous).write(to: backupURL, options: .atomic)
        }
        let bytes = try bytes(for: record)
        try bytes.write(to: cacheURL, options: .atomic)
        // A first successful fetch has a recovery copy too. The primary is already
        // committed; failure of this optional extra copy cannot roll back success.
        if !manager.fileExists(atPath: backupURL.path) { try? bytes.write(to: backupURL, options: .atomic) }
    }
    nonisolated private static func bytes(for record: CacheRecord) throws -> Data {
        let payload = try JSONEncoder().encode(record)
        return try JSONEncoder().encode(CacheEnvelope(payload: payload, checksum: digest(payload)))
    }
    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Usable HTTPS transport for the internal adapter contract. No endpoint is
/// bundled today. A supplier SDK can instead implement GameplayConfigurationProvider.
final class HTTPGameplayConfigurationProvider: GameplayConfigurationProvider {
    private let endpoint: URL
    private let session: URLSession
    init(endpoint: URL, session: URLSession? = nil) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 5
        self.session = session ?? URLSession(configuration: configuration)
    }
    static func configured(in bundle: Bundle = .main) -> HTTPGameplayConfigurationProvider? {
        guard let raw = bundle.object(forInfoDictionaryKey: "CapydokuRemoteConfigURL") as? String,
              let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return Self(endpoint: url)
    }
    func fetch(_ request: GameplayConfigurationRequest,
               completion: @escaping (Result<GameplayConfigurationResponse, Error>) -> Void) -> (() -> Void)? {
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            completion(.failure(ConfigurationFailure(message: "A trusted HTTPS configuration endpoint is required."))); return nil
        }
        let reserved = Set(["platform", "app_version", "environment", "baseline_sha256", "config_version", "revision"])
        components.queryItems = (components.queryItems ?? []).filter { !reserved.contains($0.name) } + [
            URLQueryItem(name: "platform", value: request.target.platform),
            URLQueryItem(name: "app_version", value: request.target.appVersion),
            URLQueryItem(name: "environment", value: request.target.environment),
            URLQueryItem(name: "baseline_sha256", value: request.baselineSHA256),
            URLQueryItem(name: "config_version", value: request.currentConfigVersion),
            URLQueryItem(name: "revision", value: String(request.currentRevision))
        ]
        guard let url = components.url else {
            completion(.failure(ConfigurationFailure(message: "The configuration request URL is invalid."))); return nil
        }
        var http = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: http) { data, response, error in
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                      response.url?.scheme == "https", let data, data.count <= 3 * 1_024 * 1_024 else {
                    throw ConfigurationFailure(message: "Remote configuration HTTP response is invalid.")
                }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(object.keys) == Set(["schemaVersion", "target", "revision", "configurationData", "sha256"]),
                      let target = object["target"] as? [String: Any],
                      Set(target.keys) == Set(["platform", "appVersion", "environment"]) else {
                    throw ConfigurationFailure(message: "Unexpected fields in remote configuration response.")
                }
                completion(.success(try JSONDecoder().decode(GameplayConfigurationResponse.self, from: data)))
            } catch { completion(.failure(error)) }
        }
        task.resume()
        return { task.cancel() }
    }
}
