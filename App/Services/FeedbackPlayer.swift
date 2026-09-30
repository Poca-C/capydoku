import AVFoundation
import UIKit

enum FeedbackEvent: Equatable { case tap, mark, erase, correct, wrong, win, combo(Int) }

@MainActor
protocol AudioPlaybackHandle: AnyObject {
    var isPlaying: Bool { get }
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var volume: Float { get set }
    var numberOfLoops: Int { get set }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
    func setVolume(_ volume: Float, fadeDuration: TimeInterval)
}
extension AVAudioPlayer: AudioPlaybackHandle {}

@MainActor
final class AudioScheduledTask {
    private var cancellation: (() -> Void)?
    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    func cancel() { cancellation?(); cancellation = nil }
}

/// Only validated, reviewed imports with resolvable resources may play. Injection is
/// used by contract tests; the production resolver requires an existing bundled file.
@MainActor
final class FeedbackPlayer {
    struct Settings: Equatable {
        var sound = true
        var haptic = true
        var voice = false
        var music = false
    }
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> AudioScheduledTask
    private final class Playing {
        let key: String
        let clip: AudioClipPolicy
        let handle: AudioPlaybackHandle
        let started: TimeInterval
        var remainingLoops: Int
        var loopTask: AudioScheduledTask?
        var naturalFadeTask: AudioScheduledTask?
        var fadeCompletionTask: AudioScheduledTask?
        init(key: String, clip: AudioClipPolicy, handle: AudioPlaybackHandle, started: TimeInterval) {
            self.key = key; self.clip = clip; self.handle = handle; self.started = started; remainingLoops = clip.loops
        }
    }
    private struct Pending { let key: String; let swipe: Bool; let task: AudioScheduledTask }
    private(set) var settings = Settings()
    private(set) var validationErrors: [String] = []
    private let manifest: ReferenceAudioManifest
    private let resource: (String) -> URL?
    private let makePlayer: (URL) -> AudioPlaybackHandle?
    private let schedule: Scheduler
    private let clock: () -> TimeInterval
    private let sessionControl: (Bool) -> Bool
    private let hapticEmitter: ((FeedbackEvent) -> Void)?
    private let suppressProductionAudio: Bool
    private(set) var environment = FeedbackEnvironment(page: .startup)
    private var blocks: Set<FeedbackAudioBlock> { environment.blocks }
    private var musicBlocked: Bool { !blocks.intersection([.paused, .advertisement, .background]).isEmpty }
    private var interrupted = false
    private var sessionReady = false
    private var effects: [UUID: Playing] = [:]
    private var music: Playing?
    private var musicTransitionTask: AudioScheduledTask?
    private var lastTimes: [String: TimeInterval] = [:]
    private var pending: [UUID: Pending] = [:]
    private var swipeQueue = SwipeAudioQueue()
    private var swiping = false
    private var observers: [NSObjectProtocol] = []

    init(manifest: ReferenceAudioManifest? = nil, resourceResolver: ((String) -> URL?)? = nil,
         playerFactory: ((URL) -> AudioPlaybackHandle?)? = nil, scheduler: Scheduler? = nil,
         clock: (() -> TimeInterval)? = nil, sessionControl: ((Bool) -> Bool)? = nil,
         observeSystem: Bool = true, hapticEmitter: ((FeedbackEvent) -> Void)? = nil) {
        self.manifest = manifest ?? Bundle.main.url(forResource: "audio-manifest", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(ReferenceAudioManifest.self, from: $0) } ?? .silent
        resource = resourceResolver ?? { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: nil),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }
        makePlayer = playerFactory ?? { try? AVAudioPlayer(contentsOf: $0) }
        schedule = scheduler ?? { delay, action in
            let work = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
            return AudioScheduledTask { work.cancel() }
        }
        self.clock = clock ?? { ProcessInfo.processInfo.systemUptime }
        self.hapticEmitter = hapticEmitter
        self.sessionControl = sessionControl ?? { active in
            do {
                let session = AVAudioSession.sharedInstance()
                if active { try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers]) }
                try session.setActive(active, options: active ? [] : [.notifyOthersOnDeactivation])
                return true
            } catch { return false }
        }
        suppressProductionAudio = playerFactory == nil && Self.isTesting
        validationErrors = self.manifest.validationErrors { resource($0) != nil }
        if observeSystem {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                Task { @MainActor [weak self] in
                    guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                    self?.handleInterruption(began: type == .began, shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
                }
            })
            observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleMediaServicesReset() }
            })
        }
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func apply(settings: Settings) {
        let previous = self.settings; self.settings = settings
        for (id, item) in pending where manifest.clips[item.key].map({ !enabled($0) }) ?? true { item.task.cancel(); pending.removeValue(forKey: id) }
        for (id, item) in effects where !enabled(item.clip) { stop(item); effects.removeValue(forKey: id) }
        if !settings.sound { endSwipe(cancelled: true) }
        if previous.music != settings.music {
            if settings.music { interrupted = false } // Explicit user re-enable may resume after a non-resumable interruption.
            transition(settings.music ? .musicEnabled : .musicDisabled)
        }
    }
    func setContext(page: FeedbackAudioPage, level: Int? = nil, overlay: FeedbackAudioOverlay = .none) {
        setEnvironment(FeedbackEnvironment(page: page, level: level, overlay: overlay, blocks: blocks))
    }
    /// Commit all routing inputs before handling any transition. Removing an ad block
    /// while entering the background can therefore never cause an intermediate resume.
    func setEnvironment(_ updated: FeedbackEnvironment) {
        let old = environment
        guard old != updated else { return }
        environment = updated
        let contextChanged = old.page != updated.page || old.level != updated.level || old.overlay != updated.overlay
        let newBlocks = updated.blocks.subtracting(old.blocks)
        if !newBlocks.intersection([.paused, .advertisement, .background]).isEmpty { cancelTransient() }
        else {
            if contextChanged || newBlocks.contains(.inputLocked) { endSwipe(cancelled: true) }
            if contextChanged { cancelOutOfScopeAudio() }
        }
        if old.page == .game && (updated.page != .game || old.level != updated.level) { transition(.levelExited) }
        if contextChanged { transition(.contextChanged) }
        if old.page != updated.page {
            let events: [FeedbackAudioPage: AudioFlowEvent] = [.startup: .startupEntered, .home: .homeEntered, .game: .gameEntered, .settings: .settingsEntered, .checkIn: .checkInEntered]
            if let event = events[updated.page] { transition(event) }
        }
        if updated.page == .game && (old.page != .game || old.level != updated.level) { transition(.levelEntered) }
        if old.overlay != updated.overlay {
            let events: [FeedbackAudioOverlay: AudioFlowEvent] = [.none: .overlayClosed, .tutorial: .tutorialOpened, .settings: .settingsOpened, .debug: .debugOpened, .hint: .hintOpened, .won: .won, .lost: .lost, .challenge: .challengeOpened, .loading: .loadingBegan, .notice: .noticeOpened, .error: .errorOpened]
            if let event = events[updated.overlay] { transition(event) }
        }
        // A fixed ordering is part of the adapter contract, not a guessed source-game rule.
        for reason in FeedbackAudioBlock.allCases where old.blocks.contains(reason) != updated.blocks.contains(reason) {
            transition(blockEvent(reason, active: updated.blocks.contains(reason)))
        }
        if music == nil { deactivateIfBlocked() }
    }
    /// Call with separate reasons so ending an ad cannot unpause a backgrounded app.
    func setBlocked(_ reason: FeedbackAudioBlock, active: Bool) {
        var updated = environment
        if active { updated.blocks.insert(reason) } else { updated.blocks.remove(reason) }
        setEnvironment(updated)
    }
    private func blockEvent(_ reason: FeedbackAudioBlock, active: Bool) -> AudioFlowEvent {
        let events: (AudioFlowEvent, AudioFlowEvent)
        switch reason {
        case .paused: events = (.pause, .resume)
        case .advertisement: events = (.adStarted, .adEnded)
        case .background: events = (.background, .foreground)
        case .inputLocked: events = (.inputLocked, .inputUnlocked)
        }
        return active ? events.0 : events.1
    }
    func setPaused(_ value: Bool) { setBlocked(.paused, active: value) }
    func playButton(id: String, enabled: Bool = true) {
        guard let rule = manifest.buttons?[id], enabled || rule.playWhenDisabled else { return }
        enqueue("button_tap")
    }
    var hasVerifiedComboConfiguration: Bool {
        manifest.referenceVerified && validationErrors.isEmpty && manifest.combo != nil
    }
    func comboPresentation(count: Int) -> ComboFeedbackPresentation? {
        guard hasVerifiedComboConfiguration, let key = manifest.comboEvent(count: count),
              let clip = manifest.clips[key] else { return nil }
        let text = ["nice": "Nice", "great": "Great", "excellent": "Excellent"][key]
        return text.map { ComboFeedbackPresentation(text: $0, delay: clip.delay) }
    }
    /// acceptedIn is reserved for an already committed gameplay action (such as
    /// an ad reveal that has just completed the board). It does not unlock input
    /// or bypass background/advertisement/pause blocks or the imported clip scope.
    func play(_ event: FeedbackEvent, acceptedIn context: FeedbackEnvironment? = nil) {
        if case .tap = event { playButton(id: "generic"); return }
        guard context == nil ? blocks.isEmpty : !musicBlocked, !interrupted else { return }
        // A Combo is an optional configured audio cue, not another physical move.
        // Dispatching every count must not add a second vibration to correct moves.
        if case .combo = event {} else if settings.haptic {
            if let hapticEmitter { hapticEmitter(event) }
            else if !Self.isTesting { haptic(event) }
        }
        switch event {
        case .tap: break
        case .mark: enqueue("mark_x", acceptedIn: context)
        case .erase: enqueue("erase_x", acceptedIn: context)
        case .correct: enqueue("double_tap_correct", acceptedIn: context)
        case .wrong: enqueue("double_tap_wrong", acceptedIn: context)
        case .combo(let count): if let key = manifest.comboEvent(count: count) { enqueue(key, acceptedIn: context) }
        case .win: break // No victory clip is allowed by original chapter 5.
        }
    }
    func beginSwipe() { endSwipe(cancelled: true); swiping = true }
    func playMarks(count: Int) {
        guard count > 0, blocks.isEmpty, !interrupted else { return }
        if settings.haptic && !Self.isTesting { UISelectionFeedbackGenerator().selectionChanged() }
        guard let clip = playable("swipe_x"), let policy = manifest.swipe else { return }
        if !swiping { swiping = true }
        if policy.mode == .continuous {
            if !effects.values.contains(where: { $0.key == "swipe_x" }) && !pending.values.contains(where: { $0.swipe }) { enqueue("swipe_x", swipe: true) }
        } else {
            let times = swipeQueue.enqueue(count: count, now: clock(), delay: clip.delay, minimumInterval: clip.minimumInterval, policy: policy)
            for time in times { scheduleClip("swipe_x", after: max(0, time - clock()), swipe: true) }
        }
    }
    func endSwipe(cancelled: Bool = false) {
        swiping = false
        for (id, item) in pending where item.swipe { item.task.cancel(); pending.removeValue(forKey: id) }
        swipeQueue.cancel()
        let policy = cancelled ? manifest.swipe?.cancel : manifest.swipe?.end
        // An infinite loop cannot finish naturally, so finishCurrent ends it at the next loop boundary.
        for (id, item) in effects where item.key == "swipe_x" {
            if policy == .finishCurrent {
                item.remainingLoops = 0; item.handle.numberOfLoops = 0
                scheduleEffectFadeOut(item, remainingLoops: 0)
            } else { stop(item); effects.removeValue(forKey: id) }
        }
    }
    func handleInterruption(began: Bool, shouldResume: Bool) {
        sessionReady = false
        if began { interrupted = true; cancelTransient(); transition(.interruptionBegan) }
        else if shouldResume { interrupted = false; transition(.interruptionEnded) }
        // No shouldResume means no automatic restart, even if a later settings refresh occurs.
    }
    func handleMediaServicesReset() {
        cancelTransient(); if let music { stop(music) }; music = nil
        musicTransitionTask?.cancel(); musicTransitionTask = nil; sessionReady = false
        transition(.mediaReset)
    }
    private static var isTesting: Bool { ProcessInfo.processInfo.arguments.contains("-ui-testing") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
    private var trusted: Bool { manifest.referenceVerified && validationErrors.isEmpty && !suppressProductionAudio }
    private func enabled(_ clip: AudioClipPolicy) -> Bool {
        switch clip.group { case .music: return settings.music; case .sound: return settings.sound; case .voice: return settings.voice }
    }
    private func playable(_ key: String, acceptedIn context: FeedbackEnvironment? = nil) -> AudioClipPolicy? {
        let accepted = context != nil
        guard trusted, !interrupted, let clip = manifest.clips[key], enabled(clip),
              (clip.group == .music || key == "button_tap" || accepted) ? !musicBlocked : blocks.isEmpty else { return nil }
        let scope = accepted && clip.contextChange == .completeInTriggerScope ? context! : environment
        guard clip.scope.allows(page: scope.page, level: scope.level, overlay: scope.overlay) else { return nil }
        return clip
    }
    private func prepareSession() -> Bool {
        if sessionReady { return true }
        sessionReady = sessionControl(true); return sessionReady
    }
    private func enqueue(_ key: String, swipe: Bool = false, acceptedIn context: FeedbackEnvironment? = nil) {
        guard let clip = playable(key, acceptedIn: context), clock() - (lastTimes[key] ?? -.infinity) >= clip.minimumInterval else { return }
        lastTimes[key] = clock(); scheduleClip(key, after: clip.delay, swipe: swipe, acceptedIn: context)
    }
    private func scheduleClip(_ key: String, after delay: TimeInterval, swipe: Bool, acceptedIn context: FeedbackEnvironment? = nil) {
        let id = UUID(), triggerContext = context ?? environment
        let task = schedule(delay) { [weak self] in
            guard let self, self.pending.removeValue(forKey: id) != nil else { return }
            if swipe { self.swipeQueue.consumed() }
            guard let clip = self.playable(key, acceptedIn: triggerContext), (!swipe || self.swiping) else { return }
            self.effects = self.effects.filter { _, item in
                if !item.handle.isPlaying {
                    item.loopTask?.cancel(); item.naturalFadeTask?.cancel(); item.fadeCompletionTask?.cancel(); return false
                }; return true
            }
            let existing = self.effects.filter { $0.value.key == key }
            if existing.count >= clip.maximumConcurrent {
                if clip.overflow == .dropNewest { return }
                if let oldest = existing.min(by: { $0.value.started < $1.value.started }) { self.stop(oldest.value); self.effects.removeValue(forKey: oldest.key) }
            }
            if let playing = self.newPlayer(key: key, clip: clip) { self.effects[id] = playing; self.start(playing, restart: false) }
        }
        pending[id] = Pending(key: key, swipe: swipe, task: task)
    }
    private func newPlayer(key: String, clip: AudioClipPolicy) -> Playing? {
        guard trusted, let url = resource(clip.file), let handle = makePlayer(url), handle.duration.isFinite, handle.duration > 0 else { return nil }
        if let loop = clip.loopRange, loop.end > handle.duration { return nil }
        guard clip.fadeIn <= handle.duration, clip.fadeOut <= handle.duration else { return nil }
        handle.numberOfLoops = clip.loopRange == nil ? clip.loops : 0
        guard handle.prepareToPlay() else { return nil }
        return Playing(key: key, clip: clip, handle: handle, started: clock())
    }
    private func start(_ item: Playing, restart: Bool) {
        guard prepareSession() else { return }
        if restart { item.handle.currentTime = 0; item.remainingLoops = item.clip.loops }
        item.handle.volume = item.clip.fadeIn > 0 ? 0 : item.clip.volume
        guard item.handle.play() else { return }
        item.handle.setVolume(item.clip.volume, fadeDuration: item.clip.fadeIn)
        scheduleLoop(item)
        if item.clip.group != .music { scheduleEffectFadeOut(item) }
    }
    private func scheduleLoop(_ item: Playing) {
        item.loopTask?.cancel(); item.loopTask = nil
        guard let range = item.clip.loopRange, item.remainingLoops != 0, item.handle.currentTime < range.end else { return }
        item.loopTask = schedule(range.end - item.handle.currentTime) { [weak self, weak item] in
            guard let self, let item, item.handle.isPlaying, item.remainingLoops != 0 else { return }
            if item.remainingLoops > 0 { item.remainingLoops -= 1 }
            item.handle.currentTime = range.start
            self.scheduleLoop(item)
        }
    }
    /// Effect fadeOut runs at the end of a finite playback, including its configured
    /// repeats. Explicit immediate cancellation and mute remain immediate; finishCurrent
    /// exits looping and retains the final natural fade. Music uses its flow transition fade.
    private func scheduleEffectFadeOut(_ item: Playing, remainingLoops: Int? = nil) {
        item.naturalFadeTask?.cancel(); item.fadeCompletionTask?.cancel()
        let loops = remainingLoops ?? item.remainingLoops
        guard item.clip.fadeOut > 0, loops >= 0 else { return }
        let cycle = item.clip.loopRange.map { $0.end - $0.start } ?? item.handle.duration
        let remaining = max(0, item.handle.duration - item.handle.currentTime) + cycle * Double(loops)
        guard remaining.isFinite else { stop(item); return }
        let duration = min(item.clip.fadeOut, remaining)
        item.naturalFadeTask = schedule(max(0, remaining - duration)) { [weak self, weak item] in
            guard let self, let item, item.handle.isPlaying else { return }
            item.handle.setVolume(0, fadeDuration: duration)
            item.fadeCompletionTask = self.schedule(duration) { [weak self, weak item] in
                guard let self, let item else { return }; self.stop(item)
            }
        }
    }
    private func stop(_ item: Playing) {
        item.loopTask?.cancel(); item.naturalFadeTask?.cancel(); item.fadeCompletionTask?.cancel(); item.handle.stop()
    }
    private func cancelTransient() {
        for item in pending.values { item.task.cancel() }; pending.removeAll()
        for item in effects.values { stop(item) }; effects.removeAll()
        swiping = false; swipeQueue.cancel()
    }
    private func cancelOutOfScopeAudio() {
        func obsolete(_ clip: AudioClipPolicy) -> Bool {
            clip.contextChange == .followCurrentScope && !clip.scope.allows(page: environment.page, level: environment.level, overlay: environment.overlay)
        }
        for (id, item) in pending where manifest.clips[item.key].map(obsolete) ?? true { item.task.cancel(); pending.removeValue(forKey: id) }
        for (id, item) in effects where obsolete(item.clip) { stop(item); effects.removeValue(forKey: id) }
    }
    private func transition(_ event: AudioFlowEvent) {
        guard trusted, let clip = manifest.clips["background_music"], let action = manifest.musicAction(for: event) else { return }
        let allowed = settings.music && !interrupted && !musicBlocked && clip.scope.allows(page: environment.page, level: environment.level, overlay: environment.overlay)
        if action == .unchanged && allowed { return }
        musicTransitionTask?.cancel(); musicTransitionTask = nil
        if !allowed && action != .stop && action != .pause { pauseMusic(stop: false, fade: clip.fadeOut); return }
        switch action {
        case .unchanged: break
        case .pause: pauseMusic(stop: false, fade: clip.fadeOut)
        case .stop: pauseMusic(stop: true, fade: clip.fadeOut)
        case .resume, .restart:
            guard allowed else { return }
            if action == .resume, let music, music.handle.isPlaying {
                music.handle.setVolume(clip.volume, fadeDuration: clip.fadeIn); scheduleLoop(music); return
            }
            musicTransitionTask = schedule(clip.delay) { [weak self] in
                guard let self, self.playable("background_music") != nil else { return }
                if self.music == nil { self.music = self.newPlayer(key: "background_music", clip: clip) }
                if let music = self.music { self.start(music, restart: action == .restart) }
            }
        }
    }
    private func pauseMusic(stop shouldStop: Bool, fade: Double) {
        guard let item = music else { return }
        item.handle.setVolume(0, fadeDuration: fade)
        if fade == 0 { if shouldStop { stop(item); music = nil } else { item.loopTask?.cancel(); item.handle.pause() }; deactivateIfBlocked(); return }
        musicTransitionTask = schedule(fade) { [weak self, weak item] in
            guard let self, let item, self.music === item else { return }
            if shouldStop { self.stop(item); self.music = nil } else { item.loopTask?.cancel(); item.handle.pause() }
            self.deactivateIfBlocked()
        }
    }
    private func deactivateIfBlocked() {
        if (musicBlocked || interrupted) && sessionReady { _ = sessionControl(false); sessionReady = false }
    }
    private func haptic(_ event: FeedbackEvent) {
        switch event {
        case .wrong: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .win: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .correct: UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.75)
        case .combo: break
        case .tap, .mark, .erase: UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
