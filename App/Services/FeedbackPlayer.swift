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
    /// Cached handles are leased to exactly one Playing object at a time. File
    /// sharing (mark/swipe) never shares an active playback cursor or fade task.
    private final class PreparedEffect {
        let file: String
        let handle: AudioPlaybackHandle
        var leased = false
        var ready = false
        var preparationTask: AudioScheduledTask?
        init(file: String, handle: AudioPlaybackHandle) { self.file = file; self.handle = handle }
    }
    private final class Playing {
        let key: String
        let clip: AudioClipPolicy
        let handle: AudioPlaybackHandle
        let started: TimeInterval
        var remainingLoops: Int
        var loopTask: AudioScheduledTask?
        var naturalFadeTask: AudioScheduledTask?
        var fadeCompletionTask: AudioScheduledTask?
        var playbackEndTask: AudioScheduledTask?
        var prepared: PreparedEffect?
        var retired = false
        init(key: String, clip: AudioClipPolicy, handle: AudioPlaybackHandle, started: TimeInterval) {
            self.key = key; self.clip = clip; self.handle = handle; self.started = started; remainingLoops = clip.loops
        }
    }
    private struct Pending {
        let key: String
        let swipe: Bool
        let dueAt: TimeInterval
        let task: AudioScheduledTask
        let action: () -> Void
    }
    private(set) var settings = Settings()
    private(set) var validationErrors: [String] = []
    private(set) var usesLocalTestAudio = false
    private let manifest: ReferenceAudioManifest
    private let resource: (String) -> URL?
    private let makePlayer: (URL) -> AudioPlaybackHandle?
    private let schedule: Scheduler
    private let clock: () -> TimeInterval
    private let sessionControl: (Bool) -> Bool
    private let haptics: HapticFeedbackPlayer
    private let suppressProductionAudio: Bool
    private let usesInjectedPlayer: Bool
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
    private var lastLocalSwipeCue: TimeInterval?
    private var observers: [NSObjectProtocol] = []
    private var preparedEffects: [String: [PreparedEffect]] = [:]
    private var preparedPoolEnabled = false
    private var preparationGeneration = 0
    private var rewarmTask: Task<Void, Never>?
    // Cache budgets, not gameplay concurrency limits. Overflow uses an uncached
    // player and still obeys the imported event/concurrency-group policy.
    private let preparedTotalLimit = 24
    private let preparedFileLimit = 6
    private var preparedCount: Int { preparedEffects.values.reduce(0) { $0 + $1.count } }


    init(manifest: ReferenceAudioManifest? = nil, resourceResolver: ((String) -> URL?)? = nil,
         playerFactory: ((URL) -> AudioPlaybackHandle?)? = nil, scheduler: Scheduler? = nil,
         clock: (() -> TimeInterval)? = nil, sessionControl: ((Bool) -> Bool)? = nil,
         observeSystem: Bool = true, hapticEmitter: ((FeedbackEvent) -> Void)? = nil,
         hapticDriver: HapticFeedbackDriver? = nil) {
        let bundledManifest = Bundle.main.url(forResource: "audio-manifest", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(ReferenceAudioManifest.self, from: $0) } ?? .silent
        let localImport = manifest == nil && !bundledManifest.referenceVerified ? LocalTestAudioImport.load() : nil
        self.manifest = manifest ?? localImport?.manifest ?? bundledManifest
        usesLocalTestAudio = localImport != nil
        resource = resourceResolver ?? { name in
            if let localImport { return localImport.resource(name) }
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
        let feedbackClock = clock ?? { ProcessInfo.processInfo.systemUptime }
        self.clock = feedbackClock
        haptics = HapticFeedbackPlayer(
            driver: hapticDriver ?? (Self.isTesting || hapticEmitter != nil ? nil : UIKitHapticFeedbackDriver()),
            clock: feedbackClock, observer: hapticEmitter)
        self.sessionControl = sessionControl ?? { active in
            do {
                let session = AVAudioSession.sharedInstance()
                if active { try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers]) }
                try session.setActive(active, options: active ? [] : [.notifyOthersOnDeactivation])
                return true
            } catch { return false }
        }
        usesInjectedPlayer = playerFactory != nil
        suppressProductionAudio = playerFactory == nil && Self.isTesting
        validationErrors = self.manifest.validationErrors(resourceExists: { resource($0) != nil }, validateUnverified: usesLocalTestAudio)
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
            let resumesExplicitly = settings.music && interrupted
            if settings.music { interrupted = false } // Explicit user re-enable may resume after a non-resumable interruption.
            transition(settings.music ? .musicEnabled : .musicDisabled)
            if resumesExplicitly { requestEffectPreparation() }
        }
        if previous.sound != settings.sound || previous.voice != settings.voice {
            discardPreparedEffects()
            requestEffectPreparation()
        }
        syncHaptics()
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
        syncHaptics()
        let contextChanged = old.page != updated.page || old.level != updated.level || old.overlay != updated.overlay
        let newBlocks = updated.blocks.subtracting(old.blocks)
        if !newBlocks.intersection([.paused, .advertisement, .background]).isEmpty {
            cancelTransient(); discardPreparedEffects()
        }
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
        if !old.blocks.intersection([.paused, .advertisement, .background]).isEmpty && !musicBlocked { requestEffectPreparation() }
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
        haptics.play(event, acceptedIn: context)
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
    func beginSwipe() { endSwipe(cancelled: true); swiping = true; haptics.prepareForInput() }
    func playMarks(count: Int) {
        guard count > 0, blocks.isEmpty, !interrupted else { return }
        haptics.playMarks(count: count)
        guard let clip = playable("swipe_x"), let policy = manifest.swipe else { return }
        if !swiping { swiping = true }
        if usesLocalTestAudio, policy.mode == .perCell, clip.delay == 0 {
            // Local listening policy: acknowledge the cells arriving now,
            // coalescing dense batches instead of playing stale cells later.
            let now = clock()
            let cadence = max(clip.minimumInterval, policy.cadenceSeconds)
            guard lastLocalSwipeCue.map({ now - $0 >= cadence }) ?? true else { return }
            lastLocalSwipeCue = now
            scheduleClip("swipe_x", after: 0, swipe: true)
            return
        }
        if policy.mode == .continuous {
            if !effects.values.contains(where: { $0.key == "swipe_x" }) && !pending.values.contains(where: { $0.swipe }) { enqueue("swipe_x", swipe: true) }
        } else {
            let times = swipeQueue.enqueue(count: count, now: clock(), delay: clip.delay, minimumInterval: clip.minimumInterval, policy: policy)
            for time in times { scheduleClip("swipe_x", after: max(0, time - clock()), swipe: true) }
        }
    }
    func endSwipe(cancelled: Bool = false) {
        let policy = cancelled ? manifest.swipe?.cancel : manifest.swipe?.end
        // A normal finishCurrent lift may share the same main-queue turn as the
        // last accepted marks. Complete at most one already-due cue before
        // discarding the queue; never play future cells early or drain a long tail.
        if !cancelled, swiping, policy == .finishCurrent,
           let due = pending.values.filter({ $0.swipe && $0.dueAt <= clock() }).min(by: { $0.dueAt < $1.dueAt }) {
            due.task.cancel()
            due.action()
        }
        swiping = false
        lastLocalSwipeCue = nil
        for (id, item) in pending where item.swipe { item.task.cancel(); pending.removeValue(forKey: id) }
        swipeQueue.cancel()
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
        if began { interrupted = true; cancelTransient(); discardPreparedEffects(); transition(.interruptionBegan) }
        else if shouldResume { interrupted = false; transition(.interruptionEnded); requestEffectPreparation() }
        syncHaptics()
        // No shouldResume means no automatic restart, even if a later settings refresh occurs.
    }
    func handleMediaServicesReset() {
        cancelTransient(); discardPreparedEffects(); if let music { stop(music) }; music = nil
        musicTransitionTask?.cancel(); musicTransitionTask = nil; sessionReady = false
        transition(.mediaReset); requestEffectPreparation()
    }
    private static var isTesting: Bool { ProcessInfo.processInfo.arguments.contains("-ui-testing") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
    private var trusted: Bool { (manifest.referenceVerified || usesLocalTestAudio) && validationErrors.isEmpty && !suppressProductionAudio }
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
        let dueAt = clock() + max(0, delay)
        let action = { [weak self] in
            guard let self, self.pending.removeValue(forKey: id) != nil else { return }
            if swipe { self.swipeQueue.consumed() }
            guard let clip = self.playable(key, acceptedIn: triggerContext), (!swipe || self.swiping) else { return }
            self.effects = self.effects.filter { _, item in
                if !item.handle.isPlaying {
                    self.stop(item); return false
                }; return true
            }
            let existing = self.effects.filter {
                if let group = clip.concurrencyGroup { return $0.value.clip.concurrencyGroup == group }
                return $0.value.key == key
            }
            if existing.count >= clip.maximumConcurrent {
                if clip.overflow == .dropNewest { return }
                if let oldest = existing.min(by: { $0.value.started < $1.value.started }) { self.stop(oldest.value); self.effects.removeValue(forKey: oldest.key) }
            }
            if let playing = self.newPlayer(key: key, clip: clip) {
                self.effects[id] = playing; self.start(playing, restart: false)
                if !playing.handle.isPlaying { self.stop(playing); self.effects.removeValue(forKey: id) }
                else { self.schedulePreparedPlaybackEnd(playing, id: id) }
            }
        }
        if usesLocalTestAudio, delay <= 0 {
            // An already accepted local move has no requested delay. Starting
            // here prevents rendering or other queued work from postponing its
            // sound. Imported formal scheduling remains unchanged.
            pending[id] = Pending(key: key, swipe: swipe, dueAt: dueAt,
                                  task: AudioScheduledTask {}, action: action)
            action()
        } else {
            let task = schedule(delay, action)
            pending[id] = Pending(key: key, swipe: swipe, dueAt: dueAt, task: task, action: action)
        }
    }
    private func newPlayer(key: String, clip: AudioClipPolicy) -> Playing? {
        guard trusted else { return nil }
        let cached = preparedPoolEnabled && clip.group != .music && clip.loops == 0
            ? preparedEffects[clip.file]?.first(where: { !$0.leased && $0.ready }) : nil
        let handle: AudioPlaybackHandle
        if let cached { handle = cached.handle }
        else {
            guard let url = resource(clip.file), let created = makePlayer(url) else { return nil }
            handle = created
        }
        guard valid(handle, for: clip) else { return nil }
        handle.numberOfLoops = clip.loopRange == nil ? clip.loops : 0
        handle.currentTime = 0
        if cached == nil, !handle.prepareToPlay() { return nil }
        let playing = Playing(key: key, clip: clip, handle: handle, started: clock())
        if let cached { cached.leased = true; cached.ready = false; playing.prepared = cached }
        return playing
    }
    private func valid(_ handle: AudioPlaybackHandle, for clip: AudioClipPolicy) -> Bool {
        handle.duration.isFinite && handle.duration > 0
            && (clip.loopRange.map { $0.end <= handle.duration } ?? true)
            && clip.fadeIn <= handle.duration && clip.fadeOut <= handle.duration
    }
    /// Called during the existing loading stage. It never calls play(), adds a
    /// cue or changes imported timing; yielding between handles keeps it cancellable.
    func prepareShortEffects() async {
        preparedPoolEnabled = true
        let generation = preparationGeneration
        guard trusted, !interrupted, !musicBlocked else { return }
        // prepareToPlay may allocate audio resources. Configure ambient mixing
        // before preparation so warming cannot adopt a default exclusive category.
        if !Self.isTesting && !usesInjectedPlayer {
            do { try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers]) }
            catch { return }
        }
        let clips = manifest.clips.sorted { $0.key < $1.key }.map(\.value)
            .filter { $0.group != .music && $0.loops == 0 && enabled($0) }
        var visited = Set<String>()
        for clip in clips where visited.insert(clip.file).inserted {
            // A transient prepare failure must not occupy a dead cache slot.
            // Retry each idle, unready entry once per explicit warm request;
            // never loop until success or touch a leased playback cursor.
            for entry in preparedEffects[clip.file] ?? [] where !entry.leased && !entry.ready {
                guard !Task.isCancelled, generation == preparationGeneration, !interrupted, !musicBlocked, enabled(clip) else { return }
                entry.preparationTask?.cancel(); entry.preparationTask = nil
                entry.handle.currentTime = 0; entry.handle.numberOfLoops = 0; entry.handle.volume = 0
                entry.ready = entry.handle.prepareToPlay()
                await Task.yield()
            }
            let capacity = min(preparedFileLimit, clips.filter { $0.file == clip.file }.reduce(0) { $0 + $1.maximumConcurrent })
            while (preparedEffects[clip.file]?.count ?? 0) < capacity && preparedCount < preparedTotalLimit {
                guard !Task.isCancelled, generation == preparationGeneration, !interrupted, !musicBlocked,
                      enabled(clip), let url = resource(clip.file), let handle = makePlayer(url), valid(handle, for: clip) else { return }
                handle.currentTime = 0; handle.numberOfLoops = 0; handle.volume = 0
                guard handle.prepareToPlay() else { break }
                let entry = PreparedEffect(file: clip.file, handle: handle); entry.ready = true
                preparedEffects[clip.file, default: []].append(entry)
                await Task.yield()
            }
        }
    }
    private func requestEffectPreparation() {
        guard preparedPoolEnabled, trusted, !interrupted, !musicBlocked else { return }
        rewarmTask?.cancel()
        rewarmTask = Task { [weak self] in await self?.prepareShortEffects() }
    }
    private func discardPreparedEffects() {
        preparationGeneration += 1; rewarmTask?.cancel(); rewarmTask = nil
        for entry in preparedEffects.values.flatMap({ $0 }) { entry.preparationTask?.cancel() }
        preparedEffects.removeAll()
    }
    private func releasePreparedEffect(_ item: Playing) {
        guard let entry = item.prepared else { return }
        entry.leased = false; entry.ready = false
        let generation = preparationGeneration
        entry.preparationTask = schedule(0) { [weak self, weak entry] in
            guard let self, let entry, generation == self.preparationGeneration, !entry.leased,
                  !self.interrupted, !self.musicBlocked,
                  self.preparedEffects[entry.file]?.contains(where: { $0 === entry }) == true,
                  self.manifest.clips.values.contains(where: { $0.file == entry.file && self.enabled($0) }) else { return }
            entry.handle.currentTime = 0; entry.handle.numberOfLoops = 0; entry.handle.volume = 0
            entry.ready = entry.handle.prepareToPlay()
        }
    }
    private func schedulePreparedPlaybackEnd(_ item: Playing, id: UUID) {
        guard item.prepared != nil else { return }
        // A small cleanup tolerance does not alter playback. If the device still
        // reports active audio, the normal next-event sweep owns its retirement.
        item.playbackEndTask = schedule(item.handle.duration + 0.04) { [weak self, weak item] in
            guard let self, let item, self.effects[id] === item, !item.handle.isPlaying else { return }
            self.stop(item); self.effects.removeValue(forKey: id)
        }
    }
    private func start(_ item: Playing, restart: Bool) {
        item.retired = false
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
        guard !item.retired else { return }
        item.retired = true
        item.loopTask?.cancel(); item.naturalFadeTask?.cancel(); item.fadeCompletionTask?.cancel(); item.playbackEndTask?.cancel()
        item.handle.stop(); releasePreparedEffect(item)
    }
    private func cancelTransient() {
        for item in pending.values { item.task.cancel() }; pending.removeAll()
        for item in effects.values { stop(item) }; effects.removeAll()
        swiping = false; lastLocalSwipeCue = nil; swipeQueue.cancel()
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
    private func syncHaptics() {
        haptics.update(enabled: settings.haptic, environment: environment, interrupted: interrupted)
    }
}
