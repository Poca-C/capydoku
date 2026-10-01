import Foundation

enum FeedbackAudioPage: String, Codable, CaseIterable { case startup, home, game, settings, checkIn }
enum FeedbackAudioOverlay: String, Codable, CaseIterable { case none, tutorial, settings, debug, hint, won, lost, challenge, loading, notice, error }
enum FeedbackAudioBlock: String, CaseIterable { case paused, advertisement, background, inputLocked }
struct FeedbackEnvironment: Equatable {
    var page: FeedbackAudioPage
    var level: Int?
    var overlay: FeedbackAudioOverlay = .none
    var blocks: Set<FeedbackAudioBlock> = []
}
enum AudioFlowEvent: String, Codable, CaseIterable {
    case contextChanged, levelEntered, levelExited, pause, resume, adStarted, adEnded
    case background, foreground, inputLocked, inputUnlocked, interruptionBegan, interruptionEnded
    case mediaReset, musicEnabled, musicDisabled
    case startupEntered, homeEntered, gameEntered, settingsEntered, checkInEntered
    case tutorialOpened, settingsOpened, debugOpened, hintOpened, won, lost, challengeOpened
    case loadingBegan, noticeOpened, errorOpened, overlayClosed
}
enum AudioMusicAction: String, Codable { case unchanged, pause, resume, restart, stop }
enum AudioGroup: String, Codable { case music, sound, voice }
enum AudioOverflow: String, Codable { case dropNewest, stopOldest }
enum AudioSwipeMode: String, Codable { case perCell, continuous }
enum AudioSwipeStop: String, Codable { case immediately, finishCurrent }
enum AudioContextChange: String, Codable { case followCurrentScope, completeInTriggerScope }

struct AudioScope: Codable, Equatable {
    var pages: [FeedbackAudioPage]
    var overlays: [FeedbackAudioOverlay]
    var levels: [Int]?
    func allows(page: FeedbackAudioPage, level: Int?, overlay: FeedbackAudioOverlay) -> Bool {
        guard pages.contains(page), overlays.contains(overlay) else { return false }
        return levels.map { values in level.map(values.contains) ?? false } ?? true
    }
}
struct AudioLoopRange: Codable, Equatable { var start: Double; var end: Double }
struct AudioClipPolicy: Codable, Equatable {
    var file: String
    var group: AudioGroup
    var volume: Float
    var delay: Double
    var minimumInterval: Double
    var maximumConcurrent: Int
    var overflow: AudioOverflow
    var loops: Int
    var loopRange: AudioLoopRange?
    var fadeIn: Double
    var fadeOut: Double
    var contextChange: AudioContextChange
    var scope: AudioScope
    /// Optional shared effect channel. Absence retains the original per-event limit.
    var concurrencyGroup: String? = nil
}
struct AudioSwipePolicy: Codable, Equatable {
    var mode: AudioSwipeMode
    var cadenceSeconds: Double
    var maximumQueued: Int
    var end: AudioSwipeStop
    var cancel: AudioSwipeStop
}
struct AudioButtonPolicy: Codable, Equatable { var playWhenDisabled: Bool }
struct AudioComboCue: Codable, Equatable { var count: Int; var event: String }
struct AudioComboPolicy: Codable, Equatable { var cues: [AudioComboCue]; var repeatLast: Bool }
struct ComboFeedbackPresentation: Equatable {
    var text: String
    var delay: TimeInterval
}

/// A verified import must explicitly describe playback choices. No missing field is
/// replaced with a guessed reference value. The current unverified empty manifest stays silent.
struct ReferenceAudioManifest: Codable {
    var version: String
    var referenceVerified: Bool
    var clips: [String: AudioClipPolicy]
    var musicTransitions: [String: AudioMusicAction]?
    var swipe: AudioSwipePolicy?
    var buttons: [String: AudioButtonPolicy]?
    var combo: AudioComboPolicy?

    static let silent = ReferenceAudioManifest(version: "missing", referenceVerified: false, clips: [:])
    static let allowedEvents: Set<String> = ["background_music", "button_tap", "mark_x", "swipe_x", "erase_x", "double_tap_correct", "double_tap_wrong", "nice", "great", "excellent"]
    static let comboEvents: Set<String> = ["nice", "great", "excellent"]

    func validationErrors(resourceExists: (String) -> Bool, validateUnverified: Bool = false) -> [String] {
        guard referenceVerified || validateUnverified else { return [] }
        var errors: [String] = []
        if version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("version is empty") }
        if clips.isEmpty { errors.append("verified manifest has no clips") }
        for (key, clip) in clips {
            if !Self.allowedEvents.contains(key) { errors.append("unsupported event: \(key)") }
            let name = clip.file
            let suffix = (name as NSString).pathExtension.lowercased()
            if name.isEmpty || name.contains("/") || name.contains("\\") || name.contains("..")
                || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                || !["wav", "mp3", "m4a", "aif", "aiff", "caf"].contains(suffix) {
                errors.append("unsafe or unsupported resource path: \(key)")
            } else if !resourceExists(name) { errors.append("missing resource: \(key)") }
            if key == "background_music" ? clip.group != .music : (!Self.comboEvents.contains(key) && clip.group != .sound) || (Self.comboEvents.contains(key) && clip.group == .music) {
                errors.append("invalid group: \(key)")
            }
            if !clip.volume.isFinite || !(0...1).contains(clip.volume) { errors.append("invalid volume: \(key)") }
            for (field, value) in [("delay", clip.delay), ("minimumInterval", clip.minimumInterval), ("fadeIn", clip.fadeIn), ("fadeOut", clip.fadeOut)] {
                if !value.isFinite || value < 0 { errors.append("invalid \(field): \(key)") }
            }
            // Operational bounds reject unsupported imports; they are not reference defaults.
            if !(1...256).contains(clip.maximumConcurrent) { errors.append("unsupported concurrency: \(key)") }
            if let group = clip.concurrencyGroup {
                let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
                if group.isEmpty || group.count > 64 || group.unicodeScalars.contains(where: { !permitted.contains($0) }) {
                    errors.append("invalid concurrency group: \(key)")
                }
                if clip.group == .music { errors.append("music cannot share an effect concurrency group: \(key)") }
            }
            if clip.loops < -1 { errors.append("invalid loop count: \(key)") }
            if let range = clip.loopRange, !range.start.isFinite || !range.end.isFinite || range.start < 0 || range.end <= range.start || clip.loops == 0 {
                errors.append("invalid loop range: \(key)")
            }
            if clip.scope.pages.isEmpty || Set(clip.scope.pages).count != clip.scope.pages.count
                || clip.scope.overlays.isEmpty || Set(clip.scope.overlays).count != clip.scope.overlays.count
                || clip.scope.levels.map({ $0.isEmpty || $0.contains(where: { $0 < 1 }) || Set($0).count != $0.count }) == true {
                errors.append("invalid scope: \(key)")
            }
        }
        let groups = Dictionary(grouping: clips.values.filter { $0.concurrencyGroup != nil }, by: { $0.concurrencyGroup! })
        for (name, members) in groups {
            if Set(members.map(\.group.rawValue)).count != 1 || Set(members.map(\.maximumConcurrent)).count != 1
                || Set(members.map(\.overflow.rawValue)).count != 1 {
                errors.append("inconsistent concurrency group policy: \(name)")
            }
        }
        if clips["background_music"] != nil {
            guard let transitions = musicTransitions else { return errors + ["missing explicit music transitions"] }
            let required = Set(AudioFlowEvent.allCases.map(\.rawValue))
            if Set(transitions.keys) != required { errors.append("music transitions must cover the supported flow events exactly") }
            for event in [AudioFlowEvent.pause, .adStarted, .background, .interruptionBegan, .musicDisabled] {
                if let action = transitions[event.rawValue], action != .pause && action != .stop { errors.append("blocking transition must pause or stop: \(event.rawValue)") }
            }
        }
        if clips["swipe_x"] != nil {
            if let swipe {
                if !swipe.cadenceSeconds.isFinite || swipe.cadenceSeconds < 0 || !(1...256).contains(swipe.maximumQueued) { errors.append("invalid swipe queue policy") }
                if swipe.mode == .continuous && clips["swipe_x"]?.loops != -1 { errors.append("continuous swipe requires an explicit continuous clip loop") }
            } else { errors.append("missing swipe policy") }
        }
        if clips["button_tap"] != nil && (buttons?.isEmpty ?? true) { errors.append("missing button mapping") }
        if !Set(clips.keys).intersection(Self.comboEvents).isEmpty {
            if let combo {
                if combo.cues.isEmpty || Set(combo.cues.map(\.count)).count != combo.cues.count
                    || combo.cues.contains(where: { $0.count < 1 || !Self.comboEvents.contains($0.event) || clips[$0.event] == nil }) { errors.append("invalid combo mapping") }
            } else { errors.append("missing combo mapping") }
        }
        return errors.sorted()
    }
    func musicAction(for event: AudioFlowEvent) -> AudioMusicAction? { musicTransitions?[event.rawValue] }
    func comboEvent(count: Int) -> String? {
        guard let combo else { return nil }
        if let cue = combo.cues.first(where: { $0.count == count }) { return cue.event }
        guard combo.repeatLast, let last = combo.cues.max(by: { $0.count < $1.count }), count > last.count else { return nil }
        return last.event
    }
}

/// Pure queue planning makes each newly marked cell a distinct scheduled event.
/// The caller must pass only marks actually applied by the game engine.
struct SwipeAudioQueue {
    private(set) var nextTime: TimeInterval?
    private(set) var queued = 0
    mutating func enqueue(count: Int, now: TimeInterval, delay: TimeInterval, minimumInterval: TimeInterval, policy: AudioSwipePolicy) -> [TimeInterval] {
        guard count > 0 else { return [] }
        let accepted = min(count, max(0, policy.maximumQueued - queued))
        let spacing = max(policy.cadenceSeconds, minimumInterval)
        var time = max(now + delay, nextTime ?? now + delay)
        var result: [TimeInterval] = []
        for _ in 0..<accepted { result.append(time); time += spacing }
        queued += accepted; nextTime = time
        return result
    }
    mutating func consumed() { queued = max(0, queued - 1) }
    mutating func cancel() { queued = 0; nextTime = nil }
}
