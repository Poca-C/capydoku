import AVFoundation
import UIKit

enum FeedbackEvent {
    case tap, mark, erase, correct, wrong, win, combo(Int)
}

/// Only reviewed, imported audio is played. Missing reference assets stay silent:
/// no synthesized music, replacement voice, victory jingle or extra reward sound.
@MainActor
final class FeedbackPlayer {
    struct Settings: Equatable {
        var sound = true
        var haptic = true
        var voice = false
        var music = false
    }
    struct Clip: Decodable {
        let file: String
        let group: String
        let volume: Float
        let delay: Double
        let minimumInterval: Double
        let maximumConcurrent: Int
        let loops: Int
    }
    struct Manifest: Decodable {
        let version: String
        let referenceVerified: Bool
        let clips: [String: Clip]
    }
    private(set) var settings = Settings()
    private let manifest: Manifest
    private var paused = false
    private var interrupted = false
    private var effects: [(String, AVAudioPlayer)] = []
    private var musicPlayer: AVAudioPlayer?
    private var sessionReady = false
    private var lastTimes: [String: TimeInterval] = [:]
    private var pending: [DispatchWorkItem] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        manifest = Bundle.main.url(forResource: "audio-manifest", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            ?? Manifest(version: "missing", referenceVerified: false, clips: [:])
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                self.sessionReady = false
                if type == .began { self.interrupted = true; self.stopTransientAudio() }
                else {
                    self.interrupted = false
                    if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.updateMusic() }
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopTransientAudio(); self.musicPlayer = nil; self.sessionReady = false
                self.interrupted = false; self.updateMusic()
            }
        })
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func apply(settings: Settings) {
        self.settings = settings
        for (key, player) in effects {
            let group = manifest.clips[key]?.group
            if (group == "sound" && !settings.sound) || (group == "voice" && !settings.voice) { player.stop() }
        }
        updateMusic()
    }
    func setPaused(_ value: Bool) {
        paused = value
        if value {
            stopTransientAudio()
            if sessionReady { try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]); sessionReady = false }
        } else { updateMusic() }
    }
    func play(_ event: FeedbackEvent) {
        guard !paused else { return }
        if settings.haptic && !isTesting { haptic(event) }
        let key: String
        switch event {
        case .tap: key = "button_tap"
        case .mark: key = "mark_x"
        case .erase: key = "erase_x"
        case .correct: key = "double_tap_correct"
        case .wrong: key = "double_tap_wrong"
        case .combo(let count): key = count >= 4 ? "excellent" : count == 3 ? "great" : "nice"
        case .win: return // Original section 5 forbids adding a victory sound.
        }
        playClip(key)
    }
    func playMarks(count: Int) {
        guard count > 0, !paused else { return }
        if settings.haptic && !isTesting { UISelectionFeedbackGenerator().selectionChanged() }
        // One event per newly added X; imported timing/concurrency controls the cadence.
        for _ in 0..<count { playClip("swipe_x") }
    }
    private func enabled(_ clip: Clip) -> Bool {
        clip.group == "voice" ? settings.voice : clip.group == "music" ? settings.music : settings.sound
    }
    private func player(_ clip: Clip) -> AVAudioPlayer? {
        guard !clip.file.contains("/"), !clip.file.contains(".."),
              clip.volume.isFinite, (0...1).contains(clip.volume),
              let url = Bundle.main.url(forResource: clip.file, withExtension: nil),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.volume = clip.volume; player.numberOfLoops = max(-1, clip.loops); player.prepareToPlay()
        return player
    }
    private func playClip(_ key: String) {
        guard !paused, !interrupted, !isTesting, manifest.referenceVerified,
              let clip = manifest.clips[key], enabled(clip), clip.delay.isFinite,
              clip.minimumInterval.isFinite, clip.delay >= 0, clip.delay <= 10 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastTimes[key] ?? -.infinity) >= max(0, clip.minimumInterval) else { return }
        lastTimes[key] = now
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.paused, !self.interrupted, self.enabled(clip), self.prepareSession(), let player = self.player(clip) else { return }
            self.effects.removeAll { !$0.1.isPlaying }
            let limit = max(1, min(clip.maximumConcurrent, 16))
            if self.effects.filter({ $0.0 == key }).count >= limit,
               let index = self.effects.firstIndex(where: { $0.0 == key }) { self.effects.remove(at: index).1.stop() }
            self.effects.append((key, player)); player.play()
        }
        pending.removeAll { $0.isCancelled }
        if pending.count > 128 { pending.removeFirst(pending.count - 128) }
        pending.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + clip.delay, execute: work)
    }
    private var isTesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    private func prepareSession() -> Bool {
        guard !paused, !interrupted else { return false }
        if sessionReady { return true }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true); sessionReady = true
        } catch { sessionReady = false }
        return sessionReady
    }
    private func updateMusic() {
        guard settings.music, !paused, !interrupted, !isTesting, manifest.referenceVerified,
              let clip = manifest.clips["background_music"], prepareSession() else { musicPlayer?.pause(); return }
        if musicPlayer == nil { musicPlayer = player(clip) }
        musicPlayer?.play()
    }
    private func stopTransientAudio() {
        pending.forEach { $0.cancel() }; pending.removeAll()
        effects.forEach { $0.1.stop() }; effects.removeAll(); musicPlayer?.pause()
    }
    private func haptic(_ event: FeedbackEvent) {
        switch event {
        case .wrong: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .win: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .correct, .combo: UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.75)
        case .tap, .mark, .erase: UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
