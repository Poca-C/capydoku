import Foundation
import CryptoKit

/// Small, infrequently changed app state uses the same integrity and recovery
/// guarantees as player progress. Legacy plain JSON remains readable.
struct DurableStateFile<Value: Codable> {
    let url: URL
    var backupURL: URL { url.appendingPathExtension("backup") }
    private struct Envelope: Codable { let version: Int; let payload: Data; let checksum: String }
    private func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func decode(_ data: Data) throws -> Value {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            guard envelope.version == 1, envelope.checksum == checksum(envelope.payload) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try JSONDecoder().decode(Value.self, from: envelope.payload)
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
    func load() throws -> Value? {
        var lastError: Error?
        for candidate in [url, backupURL] where FileManager.default.fileExists(atPath: candidate.path) {
            do { return try decode(Data(contentsOf: candidate)) }
            catch { lastError = error }
        }
        if let lastError { throw lastError }
        return nil
    }
    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for candidate in [url, backupURL] where FileManager.default.fileExists(atPath: candidate.path) {
            let previous = try Data(contentsOf: candidate)
            if (try? decode(previous)) == nil {
                let retained = url.appendingPathExtension("preserved-\(checksum(previous).prefix(16))")
                if !FileManager.default.fileExists(atPath: retained.path) { try previous.write(to: retained, options: .atomic) }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        let bytes = try encoder.encode(Envelope(version: 1, payload: payload, checksum: checksum(payload)))
        // Mirror the latest committed small state so a single damaged file does
        // not forget a consent or an already consumed one-time presentation.
        try bytes.write(to: backupURL, options: .atomic)
        try bytes.write(to: url, options: .atomic)
    }
}
