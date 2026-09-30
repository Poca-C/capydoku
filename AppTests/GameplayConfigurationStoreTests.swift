import XCTest
import CryptoKit
import CapydokuCore
@testable import Capydoku

private final class StoreTestProvider: GameplayConfigurationProvider {
    var requests: [GameplayConfigurationRequest] = []
    var callbacks: [(Result<GameplayConfigurationResponse, Error>) -> Void] = []
    var cancellations = 0
    func fetch(_ request: GameplayConfigurationRequest,
               completion: @escaping (Result<GameplayConfigurationResponse, Error>) -> Void) -> (() -> Void)? {
        requests.append(request); callbacks.append(completion)
        return { [weak self] in self?.cancellations += 1 }
    }
}

private final class ConfigurationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class GameplayConfigurationStoreTests: XCTestCase {
    private let target = GameplayConfigurationTarget(appVersion: "service-test-only", environment: "testing")
    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func configuration(_ version: String, mutate: ((inout [String: Any]) -> Void)? = nil) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "reference-gameplay-synthetic-row", withExtension: "json"))
        let row = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        var object: [String: Any] = [
            "schemaVersion": 1, "status": "frozen", "configVersion": version,
            "baseline": ["product": "Pawdoku", "storeVersion": "synthetic-only",
                         "capturedAt": "2026-09-30T00:00:00Z", "device": "synthetic-only", "osVersion": "synthetic-only",
                         "sourceArchiveSHA256": String(repeating: "a", count: 64), "evidenceFiles": ["synthetic-only"]],
            "importedSourceSHA256": String(repeating: "b", count: 64),
            "levels": (1...150).map { ["level": $0, "configuration": row] }
        ]
        mutate?(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func response(_ data: Data, revision: Int = 1) -> GameplayConfigurationResponse {
        .init(target: target, revision: revision, configurationData: data, sha256: digest(data))
    }
    @MainActor private func wait(_ store: GameplayConfigurationStore) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 3
        while store.diagnostics.isRefreshing {
            guard ProcessInfo.processInfo.systemUptime < end else { XCTFail("Configuration operation did not finish."); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor private func fetch(_ response: GameplayConfigurationResponse, into store: GameplayConfigurationStore,
                                  provider: StoreTestProvider) async throws {
        store.refresh(force: true)
        try XCTUnwrap(provider.callbacks.last)(.success(response))
        try await wait(store)
    }
    private func primary(_ root: URL) throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("remote-configuration"),
                                                              includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
    }

    @MainActor func testSuccessCachesExactValidatedPayloadVersionAndFetchTime() async throws {
        let root = directory(), provider = StoreTestProvider(), bundled = try configuration("test-v1")
        let store = GameplayConfigurationStore(directory: root, target: target, bundledData: bundled, provider: provider)
        XCTAssertEqual(store.configuration?.configVersion, "test-v1")
        XCTAssertEqual(store.diagnostics.source, .bundled)
        let began = Date()
        var changes = 0
        store.onChange = { _ in XCTAssertTrue(Thread.isMainThread); changes += 1 }
        try await fetch(response(try configuration("test-v2"), revision: 2), into: store, provider: provider)
        XCTAssertEqual(store.configuration?.configVersion, "test-v2")
        XCTAssertEqual(store.diagnostics.source, .remote)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.diagnostics.fetchedAt), began)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(provider.requests.first?.target, target)
        XCTAssertEqual(provider.requests.first?.baselineSHA256, String(repeating: "a", count: 64))
        let restored = GameplayConfigurationStore(directory: root, target: target, bundledData: bundled)
        XCTAssertEqual(restored.configuration, store.configuration)
        XCTAssertEqual(restored.diagnostics.source, .cache)
        XCTAssertEqual(restored.diagnostics.revision, 2)
        XCTAssertEqual(restored.diagnostics.fetchedAt, store.diagnostics.fetchedAt)
    }

    @MainActor func testFailuresKeepLatestSuccessAndRetryIsThrottledWithoutBlocking() async throws {
        let root = directory(), provider = StoreTestProvider(), bundled = try configuration("test-v1")
        let store = GameplayConfigurationStore(directory: root, target: target, bundledData: bundled, provider: provider)
        store.refresh(); provider.callbacks[0](.failure(URLError(.notConnectedToInternet)))
        try await wait(store)
        XCTAssertEqual(store.configuration?.configVersion, "test-v1")
        XCTAssertEqual(store.diagnostics.source, .bundled)
        store.refresh(); XCTAssertEqual(provider.requests.count, 1)
        try await fetch(response(try configuration("test-v2")), into: store, provider: provider)
        store.refresh(force: true); provider.callbacks.last?(.failure(URLError(.networkConnectionLost)))
        try await wait(store)
        XCTAssertEqual(store.configuration?.configVersion, "test-v2")
        XCTAssertNotNil(store.diagnostics.lastError)
        XCTAssertEqual(GameplayConfigurationStore(directory: root, target: target, bundledData: bundled).configuration?.configVersion, "test-v2")
    }

    @MainActor func testTimeoutDuplicateAndOldCallbacksCannotOverwriteANewerRequest() async throws {
        let provider = StoreTestProvider(), bundled = try configuration("test-v1")
        let store = GameplayConfigurationStore(directory: directory(), target: target, bundledData: bundled,
                                                provider: provider, timeout: 0.04)
        store.refresh(); store.refresh(force: true)
        XCTAssertEqual(provider.requests.count, 1)
        try await wait(store)
        XCTAssertTrue(store.diagnostics.lastError?.contains("timed out") == true)
        XCTAssertEqual(provider.cancellations, 1)
        store.refresh(force: true)
        provider.callbacks[0](.success(response(try configuration("late-v2"), revision: 9)))
        let accepted = response(try configuration("test-v3"), revision: 3)
        let callback = try XCTUnwrap(provider.callbacks.last)
        DispatchQueue.global().async { callback(.success(accepted)); callback(.failure(URLError(.cancelled))) }
        try await wait(store)
        XCTAssertEqual(store.configuration?.configVersion, "test-v3")
        XCTAssertNil(store.diagnostics.lastError)
        XCTAssertEqual(store.diagnostics.revision, 3)
        XCTAssertEqual(provider.cancellations, 2)
    }

    @MainActor func testRejectsWrongTargetBaselineAnswersChecksumAndReusedVersions() async throws {
        let provider = StoreTestProvider(), bundled = try configuration("test-v1")
        let store = GameplayConfigurationStore(directory: directory(), target: target, bundledData: bundled, provider: provider)
        let good = response(try configuration("test-v2"), revision: 2)
        try await fetch(good, into: store, provider: provider)
        var wrongEnvironment = response(try configuration("test-v3"), revision: 3); wrongEnvironment.target.environment = "production"
        var wrongVersion = wrongEnvironment; wrongVersion.target = target; wrongVersion.target.appVersion = "another-app-version"
        var wrongChecksum = response(try configuration("test-v3"), revision: 3); wrongChecksum.sha256 = String(repeating: "0", count: 64)
        let anotherBaseline = try configuration("test-v3") { object in
            var baseline = object["baseline"] as! [String: Any]; baseline["storeVersion"] = "not-approved"; object["baseline"] = baseline
        }
        let forbidden = try configuration("test-v3") { $0["solution"] = [0, 1, 2, 3] }
        let reusedVersion = try configuration("test-v2") { $0["importedSourceSHA256"] = String(repeating: "c", count: 64) }
        let invalid = [wrongEnvironment, wrongVersion, wrongChecksum, response(anotherBaseline, revision: 3),
                       response(forbidden, revision: 3), response(reusedVersion, revision: 3),
                       response(try configuration("stale"), revision: 1), response(try configuration("changed"), revision: 2)]
        for rejected in invalid {
            try await fetch(rejected, into: store, provider: provider)
            XCTAssertEqual(store.configuration?.configVersion, "test-v2")
            XCTAssertEqual(store.diagnostics.revision, 2)
            XCTAssertNotNil(store.diagnostics.lastError)
        }
    }

    @MainActor func testCorruptPrimaryUsesPreviousValidBackupAndDualCorruptionUsesBundle() async throws {
        let root = directory(), provider = StoreTestProvider(), bundled = try configuration("test-v1")
        let store = GameplayConfigurationStore(directory: root, target: target, bundledData: bundled, provider: provider)
        try await fetch(response(try configuration("test-v2"), revision: 2), into: store, provider: provider)
        try await fetch(response(try configuration("test-v3"), revision: 3), into: store, provider: provider)
        let url = try primary(root)
        try Data("damaged".utf8).write(to: url)
        let recovered = GameplayConfigurationStore(directory: root, target: target, bundledData: bundled)
        XCTAssertEqual(recovered.configuration?.configVersion, "test-v2")
        XCTAssertTrue(recovered.diagnostics.recoveredBackup)
        try Data("damaged too".utf8).write(to: url.appendingPathExtension("backup"))
        let fallback = GameplayConfigurationStore(directory: root, target: target, bundledData: bundled)
        XCTAssertEqual(fallback.configuration?.configVersion, "test-v1")
        XCTAssertEqual(fallback.diagnostics.source, .bundled)
        XCTAssertNotNil(fallback.diagnostics.lastError)
    }

    @MainActor func testCacheMetadataIntegrityAndEnvironmentNamespaceAreEnforced() async throws {
        let root = directory(), provider = StoreTestProvider(), bundled = try configuration("test-v1")
        let store = GameplayConfigurationStore(directory: root, target: target, bundledData: bundled, provider: provider)
        try await fetch(response(try configuration("test-v2"), revision: 2), into: store, provider: provider)
        let url = try primary(root)
        var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var record = try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: envelope["payload"] as! String))) as! [String: Any]
        record["fetchedAt"] = 123
        envelope["payload"] = try JSONSerialization.data(withJSONObject: record).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        let recovered = GameplayConfigurationStore(directory: root, target: target, bundledData: bundled)
        XCTAssertTrue(recovered.diagnostics.recoveredBackup)
        XCTAssertEqual(recovered.configuration?.configVersion, "test-v2")
        var isolated = target; isolated.environment = "production"
        let production = GameplayConfigurationStore(directory: root, target: isolated, bundledData: bundled)
        XCTAssertEqual(production.configuration?.configVersion, "test-v1")
        XCTAssertEqual(production.diagnostics.source, .bundled)
    }

    @MainActor func testPersistenceFailureKeepsLastConfigurationAndRetryCanCommit() async throws {
        let root = directory(), provider = StoreTestProvider(), bundled = try configuration("test-v1")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appendingPathComponent("remote-configuration")
        try Data("not a directory".utf8).write(to: blocked)
        let store = GameplayConfigurationStore(directory: root, target: target, bundledData: bundled, provider: provider)
        let fetched = response(try configuration("test-v2"))
        try await fetch(fetched, into: store, provider: provider)
        XCTAssertEqual(store.configuration?.configVersion, "test-v1")
        XCTAssertNotNil(store.diagnostics.lastError)
        try FileManager.default.removeItem(at: blocked)
        try await fetch(fetched, into: store, provider: provider)
        XCTAssertEqual(store.configuration?.configVersion, "test-v2")
        XCTAssertEqual(GameplayConfigurationStore(directory: root, target: target, bundledData: bundled).configuration?.configVersion, "test-v2")
    }

    @MainActor func testHistoricalVersionHashesSurviveColdStartAndRejectChangedVersionReuse() async throws {
        let root = directory(), provider = StoreTestProvider(), bundled = try configuration("test-v1")
        let store = GameplayConfigurationStore(directory: root, target: target, bundledData: bundled, provider: provider)
        try await fetch(response(try configuration("test-v2"), revision: 2), into: store, provider: provider)
        try await fetch(response(try configuration("test-v3"), revision: 3), into: store, provider: provider)
        try await fetch(response(try configuration("test-v4"), revision: 4), into: store, provider: provider)
        let reloaded = GameplayConfigurationStore(directory: root, target: target, bundledData: bundled, provider: provider)
        let rewritten = try configuration("test-v2") { $0["importedSourceSHA256"] = String(repeating: "c", count: 64) }
        try await fetch(response(rewritten, revision: 5), into: reloaded, provider: provider)
        XCTAssertEqual(reloaded.configuration?.configVersion, "test-v4")
        XCTAssertTrue(reloaded.diagnostics.lastError?.contains("previously accepted") == true)
        // An intentional rollback may use the exact earlier payload with a new revision.
        try await fetch(response(try configuration("test-v2"), revision: 6), into: reloaded, provider: provider)
        XCTAssertEqual(reloaded.configuration?.configVersion, "test-v2")
        XCTAssertEqual(reloaded.diagnostics.revision, 6)
    }

    @MainActor func testAutomaticRetryUsesMonotonicElapsedTime() async throws {
        var clock: TimeInterval = 100
        let provider = StoreTestProvider()
        let store = GameplayConfigurationStore(directory: directory(), target: target,
                                                bundledData: try configuration("test-v1"), provider: provider, uptime: { clock })
        store.refresh(); provider.callbacks[0](.failure(URLError(.notConnectedToInternet)))
        try await wait(store)
        clock = 129; store.refresh(); XCTAssertEqual(provider.requests.count, 1)
        clock = 130; store.refresh(); XCTAssertEqual(provider.requests.count, 2)
        provider.callbacks[1](.failure(URLError(.notConnectedToInternet)))
        try await wait(store)
    }

    @MainActor func testHTTPTransportCarriesOnlyConfigurationContextAndPreservesRawPayload() async throws {
        let expected = response(try configuration("test-v2"))
        let bytes = try JSONEncoder().encode(expected)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigurationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ConfigurationURLProtocol.handler = nil }
        ConfigurationURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(Set(values.keys), Set(["platform", "app_version", "environment", "baseline_sha256", "config_version", "revision"]))
            XCTAssertEqual(values["environment"], "testing")
            XCTAssertEqual(values["app_version"], "service-test-only")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, bytes)
        }
        let provider = HTTPGameplayConfigurationProvider(endpoint: URL(string: "https://configuration.invalid/config?environment=wrong")!, session: session)
        let result: Result<GameplayConfigurationResponse, Error> = await withCheckedContinuation { continuation in
            _ = provider.fetch(.init(target: target, baselineSHA256: String(repeating: "a", count: 64), currentConfigVersion: "test-v1", currentRevision: 0)) { continuation.resume(returning: $0) }
        }
        let loaded = try result.get()
        XCTAssertEqual(loaded.configurationData, expected.configurationData)
        XCTAssertEqual(loaded.sha256, expected.sha256)
    }

    @MainActor func testHTTPTransportRejectsNonHTTPSUnexpectedFieldsAndHTTPFailure() async throws {
        let request = GameplayConfigurationRequest(target: target, baselineSHA256: String(repeating: "a", count: 64), currentConfigVersion: "test-v1", currentRevision: 0)
        let sessionConfiguration = URLSessionConfiguration.ephemeral; sessionConfiguration.protocolClasses = [ConfigurationURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel(); ConfigurationURLProtocol.handler = nil }
        var calls = 0
        ConfigurationURLProtocol.handler = { request in calls += 1; return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data()) }
        for endpoint in ["http://configuration.invalid/config", "https://configuration.invalid/config"] {
            let provider = HTTPGameplayConfigurationProvider(endpoint: URL(string: endpoint)!, session: session)
            let result: Result<GameplayConfigurationResponse, Error> = await withCheckedContinuation { continuation in
                _ = provider.fetch(request) { continuation.resume(returning: $0) }
            }
            XCTAssertThrowsError(try result.get())
        }
        XCTAssertEqual(calls, 1, "An insecure URL is rejected before any request.")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response(try configuration("test-v2")))) as! [String: Any]
        object["answer"] = [1, 2]
        let unexpected = try JSONSerialization.data(withJSONObject: object)
        ConfigurationURLProtocol.handler = { request in (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, unexpected) }
        let provider = HTTPGameplayConfigurationProvider(endpoint: URL(string: "https://configuration.invalid/config")!, session: session)
        let result: Result<GameplayConfigurationResponse, Error> = await withCheckedContinuation { continuation in
            _ = provider.fetch(request) { continuation.resume(returning: $0) }
        }
        XCTAssertThrowsError(try result.get())
    }
}
