import Foundation
import CryptoKit

/// Local, user-authorized listening experiment. This is never a verified reference
/// import: the shipped production manifest remains separate and unmodified.
struct LocalTestAudioImport {
    static let directoryName = "LocalReferenceAudio"
    struct Envelope: Codable {
        let schemaVersion: Int
        let purpose: String
        let allowedEnvironment: String
        let referenceVerified: Bool
        let files: [String: String]
        let playback: ReferenceAudioManifest
    }
    let manifest: ReferenceAudioManifest
    let directory: URL

    static func load(bundle: Bundle = .main) -> Self? {
        #if DEBUG
        guard AppBuildConfiguration(info: bundle.infoDictionary ?? [:], bundleIdentifier: bundle.bundleIdentifier ?? "").environment == .demo,
              let resources = bundle.resourceURL else { return nil }
        return load(directory: resources.appendingPathComponent(directoryName), environment: .demo)
        #else
        return nil
        #endif
    }

    /// A checksum is provenance/integrity, not a claim about rights or reference fidelity.
    static func load(directory: URL, environment: AppEnvironment) -> Self? {
        #if DEBUG
        guard environment == .demo,
              let data = try? Data(contentsOf: directory.appendingPathComponent("local-test-audio.json")),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1, envelope.purpose == "local-user-authorized-audio-test",
              envelope.allowedEnvironment == "internal_demo", !envelope.referenceVerified,
              !envelope.playback.referenceVerified, !envelope.playback.clips.isEmpty,
              Set(envelope.files.keys) == Set(envelope.playback.clips.values.map(\.file)) else { return nil }
        let errors = envelope.playback.validationErrors(resourceExists: { name in
            guard let expected = envelope.files[name], expected.count == 64,
                  expected.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  name.hasPrefix("meow-test-"),
                  let bytes = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return false }
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == expected
        }, validateUnverified: true)
        guard errors.isEmpty else { return nil }
        var playback = envelope.playback
        // Demo tuning only: AppModel emits these after a committed find/life
        // loss and already rejects duplicate input. The original [335/336]
        // requires a cue for each accepted move; the experimental 150ms
        // throttle incorrectly silenced distinct moves. Keep source files,
        // other cue policies and the separate formal import unchanged.
        for event in ["double_tap_correct", "double_tap_wrong"] {
            playback.clips[event]?.minimumInterval = 0
        }
        return Self(manifest: playback, directory: directory)
        #else
        return nil
        #endif
    }

    func resource(_ name: String) -> URL? {
        guard manifest.clips.values.contains(where: { $0.file == name }) else { return nil }
        let url = directory.appendingPathComponent(name)
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? url : nil
    }
}
