import SwiftUI
import CapydokuCore

enum AppScreen { case home, game, checkIn }
enum AppSheet: String, Identifiable { case settings, debug, reward; var id: String { rawValue } }

@MainActor
final class AppModel: ObservableObject {
    @Published var progress = PlayerProgress()
    @Published var screen: AppScreen = .home
    @Published var sheet: AppSheet? { didSet { feedback.setPaused(!active || sheet == .reward) } }
    @Published var hint: PuzzleHint?
    @Published var loading = false
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published var rewardKind: RewardKind = .hint
    @Published var rewardScenario: RewardScenario = .success
    @Published var rewardBusy = false
    @Published var interstitialBusy = false
    @Published var challengePending = false
    @Published private(set) var referenceConfiguration: ReferenceGameplayConfiguration?
    @Published private(set) var lastGenerationReport: GenerationPipelineReport?
    private var winTransitionID: UUID?
    private var shownInterstitialWins = Set<UUID>()
    private var eligibleWinCount = 0
    private var lastInterstitialAt: Date?
    private var challengeSeen = false
    private var transitionToHome = false
    private struct WinAdState: Codable {
        var shown: Set<UUID>
        var eligibleCount: Int
        var lastShownAt: Date?
    }
    @Published private(set) var rewardRetryPending = false
    @Published var config = DemoConfig.default
    @Published var jumpLevel = "1"
    @Published var exportURL: URL?
    @Published var now = Date()
    let saveDirectory: URL
    let analytics: AnalyticsRecorder
    private let store: SaveStore
    private let saveQueue = DispatchQueue(label: "com.capydoku.progress-writes", qos: .utility)
    private let synchronousSaves: Bool
    private var saveRevision = 0
    private var levels: [Int: Puzzle] = [:]
    private var active = true
    private var timer: Timer?
    private var loadingID = UUID()
    private var generationCandidateLimitOverride: Int?
    private var generationRetryCounts: [Int: Int] = [:]
    private var activeOfferID: String?
    private var rewardDeadline: DispatchWorkItem?
    private var pendingRewardSignal: RewardSignal?
    private let rewardProvider: RewardProvider?
    private var activeRewardProvider: RewardProvider?
    private var rewardIsReady = false
    private var rewardWasPresented = false
    private var rewardWasReplenished = false
    private var startupFlowCompleted = false
    private var preloadedSessionID: UUID?
    private let interstitialProvider: InterstitialProvider?
    private var interstitialDeadline: DispatchWorkItem?
    private let rewardTimeout: TimeInterval
    private let feedbackEnabled: Bool
    private var lastRestartTime: TimeInterval = 0
    private var lastDirectTime: TimeInterval = 0
    private var lastSubmission: (cell: Int, time: TimeInterval)?
    private var hintSource = "level_config_free"
    private let feedback = FeedbackPlayer()

    init(saveDirectory: URL? = nil, rewardProvider: RewardProvider? = nil,
         rewardTimeout: TimeInterval = 5, runsTimer: Bool = true, feedbackEnabled: Bool = true, bundledPuzzles: [Puzzle]? = nil, interstitialProvider: InterstitialProvider? = nil, startupBypassForTesting: Bool = true) {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        #else
        let args: [String] = []
        #endif
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let testHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        // Unit tests instantiate AppModel without the startup view. This bypass cannot
        // apply to release builds or dedicated first-launch permission tests.
        startupFlowCompleted = startupBypassForTesting && testHost && !args.contains("-test-first-launch")
        #endif
        self.saveDirectory = saveDirectory ?? root.appendingPathComponent(args.contains("-ui-testing") ? "CapydokuUITesting" : testHost ? "CapydokuAppTestingHost" : "Capydoku", isDirectory: true)
        self.rewardProvider = rewardProvider
        self.interstitialProvider = interstitialProvider
        self.synchronousSaves = !runsTimer
        self.rewardTimeout = rewardTimeout.isFinite ? max(0.01, rewardTimeout) : 5
        self.feedbackEnabled = feedbackEnabled && !testHost
        if args.contains("-reset-demo") { try? FileManager.default.removeItem(at: self.saveDirectory) }
        self.analytics = AnalyticsRecorder(directory: self.saveDirectory)
        let packName = args.contains("-legacy-fixture") ? "levels-legacy-v2" : "levels"
        if let bundledPuzzles { levels = Dictionary(uniqueKeysWithValues: bundledPuzzles.map { ($0.id, $0) }) }
        else if let url = Bundle.main.url(forResource: packName, withExtension: "json") {
            do {
                let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
                levels = Dictionary(uniqueKeysWithValues: puzzles.map { ($0.id, $0) })
            } catch { errorMessage = "The packaged levels could not be loaded. \(error.localizedDescription)" }
        } else { errorMessage = "The level pack is missing from this build." }
        let packagedLevels = levels
        let legacy: [Puzzle] = Bundle.main.url(forResource: "levels-legacy-v2", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Puzzle].self, from: $0) } ?? []
        store = SaveStore(directory: self.saveDirectory, packagedPuzzle: { packagedLevels[$0] }, archivedPuzzles: { id in legacy.filter { $0.id == id } })
        let packError = errorMessage
        loadProgress()
        if let packError { errorMessage = packError }
        if let state = try? DurableStateFile<WinAdState>(url: self.saveDirectory.appendingPathComponent("win-ad-state.json")).load() {
            shownInterstitialWins = state.shown; eligibleWinCount = max(0, state.eligibleCount); lastInterstitialAt = state.lastShownAt
        }
        let challengeFile = DurableStateFile<Bool>(url: self.saveDirectory.appendingPathComponent("challenge-state.json"))
        challengeSeen = (try? challengeFile.load()) ?? false
        if !challengeSeen, let old = try? Data(contentsOf: self.saveDirectory.appendingPathComponent("challenge-10-seen")), old == Data("original-8.2".utf8) {
            challengeSeen = true
            try? challengeFile.save(true)
        }
        if let url = Bundle.main.url(forResource: "reference-gameplay", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            do { referenceConfiguration = try ReferenceGameplayConfiguration.load(data: data) }
            catch { errorMessage = "The imported reference configuration is invalid. \(error.localizedDescription)" }
        }
        applySettings()
        if runsTimer { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.now = Date()
                if self.active && self.screen == .game && self.sheet == nil && self.hint == nil && self.notice == nil && self.errorMessage == nil && self.session?.status == .playing {
                    self.progress.session?.advanceTime(by: 1)
                    if (self.progress.session?.elapsedSeconds ?? 0).truncatingRemainder(dividingBy: 10) < 1 { self.save() }
                }
            }
        } }
        if args.contains("-skip-tutorial") { progress.tutorialCompleted = true }
        if let i = args.firstIndex(of: "-generation-candidate-limit"), args.indices.contains(i + 1), let limit = Int(args[i + 1]) {
            generationCandidateLimitOverride = limit // Failure injection must not corrupt the saved session config.
        }
        if let i = args.firstIndex(of: "-level"), args.indices.contains(i + 1), let level = Int(args[i + 1]) {
            start(level: level)
        }
    }

    deinit { timer?.invalidate(); rewardDeadline?.cancel(); interstitialDeadline?.cancel() }

    var session: GameSession? { progress.session }
    var directVisible: Bool { session?.config.referenceGameplay?.directFind.visible ?? true }
    var directEnabled: Bool {
        guard let row = session?.config.referenceGameplay else { return true }
        return row.directFind.enabled && row.directFind.buttonState == .enabled && (progress.availableDirect > 0 || (row.adsEnabled && row.directFind.rewardedAdEnabled))
    }
    var hintEnabled: Bool {
        guard let row = session?.config.referenceGameplay else { return true }
        return row.hint.enabled && row.hint.buttonState == .enabled && (progress.availableHints > 0 || (row.adsEnabled && row.hint.rewardedAdEnabled))
    }
    var levelStartFreeAvailable: Bool {
        guard let row = session?.config.referenceGameplay else { return false }
        return row.adsEnabled && row.levelStartFreeAd.enabled && row.levelStartFreeAd.visible && row.levelStartFreeAd.buttonState == .enabled && progress.levelStartFreeRewardsRemaining > 0
    }
    var reviveAvailable: Bool {
        guard session?.status == .lost else { return false }
        if progress.freeRevivesRemaining > 0 { return true }
        guard let row = session?.config.referenceGameplay else { return true }
        return row.adsEnabled && row.revive.enabled && row.revive.rewardedAdEnabled
    }
    var reviveNeedsVideo: Bool { progress.freeRevivesRemaining == 0 }
    func revive() {
        guard reviveAvailable, sheet == nil, !rewardBusy else { return }
        if progress.freeRevivesRemaining > 0 {
            flushPendingSaves()
            do { _ = try store.transaction(progress: &progress) { $0.useFreeRevive() } }
            catch { errorMessage = "Your revival could not be saved. Please try again." }
        } else { offer(.revive) }
    }
    func levelStartFree() { guard levelStartFreeAvailable, canTouchBoard else { return }; offer(.levelStartFree) }
    private func configuration(for level: Int) -> DemoConfig {
        var value = config
        if let imported = referenceConfiguration, let row = imported.level(level) {
            value.version = imported.configVersion ?? value.version
            value.referenceGameplay = row
            value.initialLives = row.startingLives
            value.hintsPerLevel = row.hint.initialFreeCount
            value.directPerLevel = row.directFind.initialFreeCount
        }
        return value
    }
    var tutorial: TutorialStep? {
        guard let s = session, s.puzzle.id == 1, !progress.tutorialCompleted, s.status == .playing else { return nil }
        let steps = PuzzleHints.tutorial(puzzle: s.puzzle)
        return steps.indices.contains(progress.tutorialStep) ? steps[progress.tutorialStep] : nil
    }
    var tutorialCount: Int { session.map { PuzzleHints.tutorial(puzzle: $0.puzzle).count } ?? 0 }

    func loadProgress() {
        flushPendingSaves(); saveRevision += 1
        rewardDeadline?.cancel(); rewardDeadline = nil
        let loaded = store.load()
        hint = nil; activeOfferID = nil; rewardBusy = false
        activeRewardProvider = nil; rewardIsReady = false; rewardWasPresented = false; rewardWasReplenished = false
        rewardRetryPending = false; pendingRewardSignal = nil
        if sheet == .reward { sheet = nil }
        notice = nil; errorMessage = nil
        progress = loaded.progress
        if progress.session == nil { screen = .home }
        if let message = loaded.warning { notice = message }
    }

    /// Normal gestures enqueue immutable snapshots. Receipt transactions and background
    /// transitions flush the same queue before committing, so an older snapshot can never
    /// overwrite a later reward or a restored save.
    func save(force: Bool = false) {
        progress.captureSessionBalance()
        let snapshot = progress
        saveRevision += 1; let revision = saveRevision
        let store = store
        if force || synchronousSaves {
            do { try saveQueue.sync { try store.save(snapshot) } }
            catch { errorMessage = "Progress could not be saved: \(error.localizedDescription)" }
        } else {
            saveQueue.async { [weak self] in
                do { try store.save(snapshot) }
                catch {
                    let message = "Progress could not be saved: \(error.localizedDescription)"
                    DispatchQueue.main.async { if self?.saveRevision == revision { self?.errorMessage = message } }
                }
            }
        }
    }
    func flushPendingSaves() { saveQueue.sync {} }

    func startOrContinue() {
        if session != nil { screen = .game; trackLevelStart(); preloadRewardPlacementsIfNeeded() }
        else { start(level: progress.currentLevel) }
    }

    func start(level: Int) {
        guard !loading else { return }
        hint = nil
        if let puzzle = levels[level] {
            progress.begin(puzzle: puzzle, config: configuration(for: level))
            screen = .game; save(); trackLevelStart(); preloadRewardPlacementsIfNeeded(); return
        }
        guard level >= 151 && level <= 100_000 else {
            errorMessage = "This level is not included in the demo pack."; return
        }
        loading = true
        let request = UUID(); loadingID = request
        let configuration = configuration(for: level)
        let candidateLimit = generationCandidateLimitOverride ?? configuration.generatorCandidateLimit
        let retry = generationRetryCounts[level, default: 0]
        generationRetryCounts[level] = retry + 1
        let retrySeed: UInt64? = retry == 0 ? nil : (UInt64(level) &* 0x9E3779B97F4A7C15 &+ 0xCA9D0C0) ^ (UInt64(retry) &* 0xD1B54A32D192ED03)
        let packaged = Array(levels.values)
        let cacheDirectory = saveDirectory.appendingPathComponent("BoardCache")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> GenerationPipelineResult in
                let cached = ((try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []).compactMap { url -> Puzzle? in
                    guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
                    return try? JSONDecoder().decode(Puzzle.self, from: data)
                }
                let corpus = (packaged + cached).filter { $0.id != level }.map { SimilarityCorpusEntry(game: "CapyDoku", puzzle: $0) }
                return try PuzzleGenerator.generateAudited(level: level, seed: retrySeed, corpus: corpus, similarityConfiguration: .strict, maxAttempts: candidateLimit, timeBudgetMilliseconds: configuration.generatorBudgetMilliseconds)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadingID == request else { return }
                self.loading = false
                switch result {
                case .success(let generation):
                    self.lastGenerationReport = generation.report
                    guard let puzzle = generation.puzzle else {
                        self.errorMessage = "Generation stopped safely. Your current board is intact. Please retry. \(generation.report.termination)"; return
                    }
                    self.progress.begin(puzzle: puzzle, config: configuration)
                    self.screen = .game; self.save(); self.trackLevelStart(); self.preloadRewardPlacementsIfNeeded()
                case .failure(let error):
                    self.errorMessage = "Generation stopped safely. Your current board is intact. Please retry. \(error.localizedDescription)"
                }
            }
        }
    }

    func home() {
        if session?.status == .won { transitionAfterWin(toHome: true); return }
        trackLevelEnd("quit"); trackTutorialEnd("quit"); hint = nil; screen = .home; save()
    }
    func next() { transitionAfterWin(toHome: false) }
    private func transitionAfterWin(toHome: Bool) {
        guard startupFlowCompleted, let s = session, s.status == .won, !interstitialBusy, !challengePending, winTransitionID == nil else { return }
        transitionToHome = toHome; winTransitionID = s.id
        if let row = s.config.referenceGameplay, row.adsEnabled, row.interstitial.enabled,
           s.puzzle.id >= row.interstitial.startLevel, !shownInterstitialWins.contains(s.id),
           toHome ? row.interstitial.onReturnHome : row.interstitial.onNextLevel {
            let previous = WinAdState(shown: shownInterstitialWins, eligibleCount: eligibleWinCount, lastShownAt: lastInterstitialAt)
            shownInterstitialWins.insert(s.id); eligibleWinCount += 1
            let cooled = Date().timeIntervalSince(lastInterstitialAt ?? .distantPast) >= Double(row.interstitial.cooldownSeconds)
            if eligibleWinCount % max(1, row.interstitial.frequency) == 0 && cooled {
                lastInterstitialAt = Date()
                guard persistWinAdState(previous: previous) else { winTransitionID = nil; return }
                interstitialBusy = true; sheet = .reward
                let deadline = DispatchWorkItem { [weak self] in self?.finishInterstitial(winID: s.id) }
                interstitialDeadline = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(row.interstitial.adTimeoutSeconds), execute: deadline)
                (interstitialProvider ?? MockInterstitialProvider(scenario: rewardScenario)).present { [weak self] _ in
                    DispatchQueue.main.async { self?.finishInterstitial(winID: s.id) }
                }
                return
            }
            guard persistWinAdState(previous: previous) else { winTransitionID = nil; return }
        }
        completeWinTransition()
    }
    private func finishInterstitial(winID: UUID) {
        guard interstitialBusy, winTransitionID == winID else { return }
        interstitialDeadline?.cancel(); interstitialDeadline = nil
        interstitialBusy = false; sheet = nil; completeWinTransition()
    }
    private func persistWinAdState(previous: WinAdState) -> Bool {
        do {
            let state = WinAdState(shown: shownInterstitialWins, eligibleCount: eligibleWinCount, lastShownAt: lastInterstitialAt)
            try DurableStateFile<WinAdState>(url: saveDirectory.appendingPathComponent("win-ad-state.json")).save(state)
            return true
        } catch {
            shownInterstitialWins = previous.shown; eligibleWinCount = previous.eligibleCount; lastInterstitialAt = previous.lastShownAt
            errorMessage = "The level transition could not be saved. Please try again."; return false
        }
    }
    private func completeWinTransition() {
        guard let s = session, s.id == winTransitionID else { winTransitionID = nil; return }
        if transitionToHome { winTransitionID = nil; hint = nil; screen = .home; save(); return }
        if s.puzzle.id == 10 && !challengeSeen { challengePending = true; return }
        winTransitionID = nil; start(level: s.puzzle.id + 1)
    }
    func continueChallenge() {
        guard challengePending, let s = session, s.id == winTransitionID else { return }
        do {
            try DurableStateFile<Bool>(url: saveDirectory.appendingPathComponent("challenge-state.json")).save(true)
        } catch { errorMessage = "Your progress could not be saved. Please try again."; return }
        challengeSeen = true
        challengePending = false; winTransitionID = nil; start(level: s.puzzle.id + 1)
    }
    func restart() {
        let time = ProcessInfo.processInfo.systemUptime
        guard !loading, !rewardBusy, time - lastRestartTime > 0.4 else { return }
        guard session?.config.referenceGameplay?.failure.restartCreatesNewBoard != true else {
            errorMessage = "This imported configuration requires an alternate packaged board. That reference behavior is not available in this build. Your current progress is intact."
            return
        }
        lastRestartTime = time
        hint = nil
        if let s = session { track("level_restart", key: s.id.uuidString, parameters: ["restart_reason": s.status == .lost ? "after_fail" : "manual", "previous_fail_reason": s.status == .lost ? "life_zero" : "", "next_attempt_no": "\(s.attempt + 1)"]) }
        progress.restart(); save(); trackLevelStart()
    }

    private func tutorialAllows(_ action: String, cells: [Int]) -> Bool {
        guard let t = tutorial else { return true }
        return t.action == action && !cells.isEmpty && Set(cells).isSubset(of: Set(t.targetCells))
    }
    func advanceTutorial() {
        let completes = progress.tutorialStep + 1 >= tutorialCount
        if completes { trackTutorialEnd("complete") }
        progress.tutorialStep += 1
        if completes { progress.tutorialCompleted = true }
        save()
    }
    func skipTutorial() { trackTutorialEnd("quit"); progress.tutorialCompleted = true; save() }
    func replayTutorial() {
        progress.tutorialCompleted = false; progress.tutorialStep = 0; sheet = nil
        start(level: 1)
    }
    func toggle(_ cell: Int) {
        guard canTouchBoard, tutorialAllows("tap", cells: [cell]) else { return }
        let wasMarked = session?.marks.contains(cell) == true
        if progress.session?.toggleMark(at: cell) == true {
            feedback.play(wasMarked ? .erase : .mark)
            if tutorial != nil { advanceTutorial() }
            save()
        }
    }
    func mark(_ cells: [Int]) {
        guard canTouchBoard, tutorialAllows("swipe", cells: cells) else { return }
        let count = progress.session?.markMany(cells) ?? 0
        guard count > 0 else { return }
        feedback.playMarks(count: count)
        if let t = tutorial, Set(t.targetCells).isSubset(of: session?.marks ?? []) { advanceTutorial() }
        save()
    }
    func submit(_ cell: Int) {
        guard canTouchBoard, tutorialAllows("doubleTap", cells: [cell]) else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        // Ignore a duplicated delivery of this gesture, not all future attempts at this cell.
        if let last = lastSubmission, last.cell == cell, timestamp - last.time < 0.28 { return }
        lastSubmission = (cell, timestamp)
        let result = progress.session?.submit(cell: cell)
        switch result {
        case .correct:
            feedback.play(.correct)
            if tutorial != nil { advanceTutorial() }
            afterAction()
        case .incorrect: feedback.play(.wrong); if session?.status == .lost { trackLevelEnd("lose") }; save()
        default: break
        }
    }
    private func afterAction() {
        if progress.finishWin() { feedback.play(.win); trackLevelEnd("win") }
        else if let combo = session?.combo, combo > 1 { feedback.play(.combo(combo)) }
        save()
    }
    func direct() {
        let time = ProcessInfo.processInfo.systemUptime
        guard canTouchBoard, tutorial == nil, directVisible, directEnabled, time - lastDirectTime > 0.35 else { return }
        lastDirectTime = time
        if progress.availableDirect == 0 { offer(.direct); return }
        let before = progress.availableDirect
        if progress.directFind() != nil {
            trackBuff("direct_find", applied: true, before: before, after: progress.availableDirect, source: "level_config_free")
            feedback.play(.correct); afterAction()
        }
    }
    func showHint() {
        guard canTouchBoard, tutorial == nil, hintEnabled, let s = session, s.status == .playing else { return }
        guard let preview = PuzzleHints.next(puzzle: s.puzzle, found: s.found, marks: s.marks) else {
            notice = "Every useful exclusion is already marked. Try locating the remaining capybaras."; return
        }
        if progress.availableHints == 0 { offer(.hint); return }
        let before = progress.availableHints
        hintSource = session?.pendingRewardHint == true ? "rewarded_ad" : "level_config_free"
        if progress.consumeHint() {
            hint = preview; save()
            trackBuff("hint", applied: false, before: before, after: progress.availableHints, source: hintSource)
        }
    }
    func applyHint() {
        guard active, screen == .game, sheet == nil, !loading, !rewardBusy,
              session?.status == .playing, let hint else { return }
        _ = progress.session?.markMany(hint.cells)
        trackBuff("hint", applied: true, before: progress.availableHints, after: progress.availableHints, source: hintSource)
        self.hint = nil; feedback.play(.mark); save()
    }
    func offer(_ kind: RewardKind) {
        guard startupFlowCompleted, !loading, !rewardBusy, !interstitialBusy, sheet == nil, hint == nil, progress.canReceiveReward(kind) else { return }
        if let row = session?.config.referenceGameplay {
            let enabled: Bool
            switch kind {
            case .direct: enabled = row.directFind.rewardedAdEnabled
            case .hint: enabled = row.hint.rewardedAdEnabled
            case .revive: enabled = row.revive.enabled && row.revive.rewardedAdEnabled
            case .levelStartFree: enabled = row.levelStartFreeAd.enabled
            }
            guard row.adsEnabled && enabled else { return }
        }
        rewardKind = kind; sheet = .reward
        runReward()
    }
    func runReward() {
        guard startupFlowCompleted, active, sheet == .reward, !loading, !rewardBusy, !interstitialBusy else { return }
        if let offerID = activeOfferID, let signal = pendingRewardSignal {
            errorMessage = nil
            rewardBusy = true
            receive(signal, offerID: offerID)
            return
        }
        let offerID = UUID().uuidString
        do {
            flushPendingSaves()
            guard try store.prepareReward(offerID: offerID, kind: rewardKind, progress: &progress) else {
                notice = "This reward is not available right now."; sheet = nil; return
            }
            activeOfferID = offerID
            let provider = rewardProvider ?? MockRewardProvider(scenario: rewardScenario)
            activeRewardProvider = provider
            rewardIsReady = false; rewardWasPresented = false; rewardWasReplenished = false
            let placement = rewardKind == .direct ? "direct_find" : rewardKind == .levelStartFree ? "level_start_free" : rewardKind.rawValue
            let rewardType = rewardKind == .levelStartFree ? (session?.config.referenceGameplay?.levelStartFreeAd.reward.rawValue ?? "") : placement
            track("ad_offer_shown", key: offerID, parameters: ["offer_id": offerID, "placement_id": placement, "reward_type": rewardType, "buff_type": rewardKind == .revive ? "" : rewardType, "reward_amount": "\(rewardKind == .levelStartFree ? (session?.config.referenceGameplay?.levelStartFreeAd.rewardCount ?? 0) : 1)", "ad_type": "rewarded", "network": "simulation", "ad_unit_id": "internal-demo"])
            rewardBusy = true
            let deadline = DispatchWorkItem { [weak self] in self?.receive(.timedOut, offerID: offerID) }
            rewardDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + (session?.config.referenceGameplay.map { Double($0.rewardedAdTimeoutSeconds) } ?? rewardTimeout), execute: deadline)
            provider.preload(placement: rewardKind) { [weak self] readiness in
                // Readiness callbacks may arrive on any queue, repeatedly or after timeout.
                DispatchQueue.main.async { self?.receiveReadiness(readiness, offerID: offerID) }
            }
            // Preserve synchronous already-ready adapters without requiring an async tick.
            if provider.isReady(placement: rewardKind) { receiveReadiness(.ready, offerID: offerID) }
        } catch { errorMessage = "Reward could not start: \(error.localizedDescription)" }
    }

    private func receiveReadiness(_ readiness: RewardReadiness, offerID: String) {
        guard activeOfferID == offerID, rewardBusy, !rewardWasPresented, pendingRewardSignal == nil,
              progress.rewardLedger[offerID]?.state == .offered else { return }
        switch readiness {
        case .unavailable: receive(.failed, offerID: offerID)
        case .ready:
            rewardIsReady = true
            displayReadyReward(offerID: offerID)
        }
    }
    private func displayReadyReward(offerID: String) {
        guard startupFlowCompleted, active, sheet == .reward, activeOfferID == offerID,
              rewardBusy, rewardIsReady, !rewardWasPresented, pendingRewardSignal == nil,
              let provider = activeRewardProvider else { return }
        rewardWasPresented = true
        trackAdResult(offerID, status: "started", granted: false)
        provider.present(placement: rewardKind, offerID: offerID) { [weak self] signal in
            DispatchQueue.main.async { self?.receive(signal, offerID: offerID) }
        }
        // The local display boundary consumes one ready ad. Request its replacement
        // immediately; SDK adapters must coalesce loads per configured ad unit.
        if !rewardWasReplenished {
            rewardWasReplenished = true
            provider.replenish(placement: rewardKind)
        }
    }
    private func receive(_ signal: RewardSignal, offerID: String) {
        // A late duplicate must not dismiss a newer sheet or unlock a newer transaction.
        guard let record = progress.rewardLedger[offerID], record.state == .offered || record.state == .rewarded else { return }
        guard activeOfferID == offerID else { return }
        guard rewardBusy else { return } // A failed write retains the first result for explicit retry.
        rewardDeadline?.cancel(); rewardDeadline = nil
        rewardBusy = false
        pendingRewardSignal = signal
        flushPendingSaves()
        do {
            switch signal {
            case .earned:
                let result = try store.grantReward(offerID: offerID, progress: &progress)
                trackAdResult(offerID, status: "completed", granted: result != .ignored && result != .duplicate)
                sheet = nil
                switch result {
                case .hintReady: showHint()
                case .directRevealed: trackBuff("direct_find", applied: true, before: 0, after: 0, source: "rewarded_ad"); feedback.play(.correct); afterAction()
                case .inventoryGranted: break
                case .revived: break
                case .duplicate: break
                case .compensated: notice = "Reward saved to your inventory."
                case .ignored: break
                }
            case .cancelled, .failed, .timedOut:
                try store.cancelReward(offerID: offerID, progress: &progress)
                trackAdResult(offerID, status: signal == .cancelled ? "skipped" : "failed", granted: false)
                sheet = nil
                switch signal {
                case .cancelled: notice = "Simulation cancelled. No reward was issued."
                case .timedOut: notice = "The reward simulation timed out. No reward was issued. You can try again."
                default: notice = "Video unavailable. Please try again."
                }
            case .interrupted:
                try store.markRewardReceived(offerID: offerID, progress: &progress)
                sheet = nil
                notice = "Reward receipt saved. Use Recover save in Developer tools, or relaunch, to test interruption recovery."
            }
            activeOfferID = nil; pendingRewardSignal = nil; rewardRetryPending = false
            activeRewardProvider = nil; rewardIsReady = false
        } catch {
            rewardRetryPending = true
            errorMessage = "The reward could not be saved. Free up storage if needed, then tap Retry save. Your receipt is kept for this retry. \(error.localizedDescription)"
        }
    }
    private var canTouchBoard: Bool { active && screen == .game && !loading && !rewardBusy && !interstitialBusy && !challengePending && sheet == nil && hint == nil && session?.status == .playing }
    func claim() {
        now = Date()
        let outcome: CheckInOutcome
        flushPendingSaves()
        do {
            outcome = try store.transaction(progress: &progress) { $0.claimCheckIn(on: now, config: config) }
        } catch {
            errorMessage = "Your reward was not saved. Please retry. \(error.localizedDescription)"; return
        }
        switch outcome {
        case .claimed: break
        case .alreadyClaimed: notice = "You've already checked in today."
        case .clockRollback: notice = "Check-in is paused until the saved UTC date has passed."
        }
    }
    func uiTap() { feedback.play(.tap) }
    func applySettings() {
        let s = progress.settings
        feedback.apply(settings: .init(sound: feedbackEnabled && s.soundEnabled, haptic: feedbackEnabled && s.hapticsEnabled, voice: feedbackEnabled && s.voiceEnabled, music: feedbackEnabled && s.musicEnabled))
    }
    func settingsChanged() { applySettings(); save() }
    func setActive(_ value: Bool) {
        active = value; now = Date(); feedback.setPaused(!value || sheet == .reward)
        if value { analytics.beginSession(source: "resume") } else { analytics.endSession(reason: "background") }
        if !value { save(force: true) }
        else if let offerID = activeOfferID { displayReadyReward(offerID: offerID) }
    }
    func consentAccepted() { analytics.acceptConsent() }
    /// Called only after the startup view reaches Home, including optional permission completion.
    /// This permits local adapter use; it does not claim a real SDK/CMP has been initialized.
    func startupReady() {
        startupFlowCompleted = true
        preloadRewardPlacementsIfNeeded()
    }
    private func preloadRewardPlacementsIfNeeded() {
        guard startupFlowCompleted, let session, preloadedSessionID != session.id else { return }
        preloadedSessionID = session.id
        let placements: [RewardKind]
        if let row = session.config.referenceGameplay {
            guard row.adsEnabled else { return }
            var enabled: [RewardKind] = []
            if row.directFind.enabled && row.directFind.visible && row.directFind.rewardedAdEnabled && session.puzzle.id >= row.directFind.unlockLevel { enabled.append(.direct) }
            if row.hint.enabled && row.hint.visible && row.hint.rewardedAdEnabled && session.puzzle.id >= row.hint.unlockLevel { enabled.append(.hint) }
            if row.revive.enabled && row.revive.rewardedAdEnabled { enabled.append(.revive) }
            if row.levelStartFreeAd.enabled && row.levelStartFreeAd.visible { enabled.append(.levelStartFree) }
            placements = enabled
        } else {
            placements = [.direct, .hint, .revive] // Existing isolated Demo placements; not frozen SDK unit configuration.
        }
        let provider = rewardProvider ?? MockRewardProvider(scenario: rewardScenario)
        for placement in placements { provider.preload(placement: placement) { _ in } }
    }
    private func track(_ name: String, key: String, parameters: [String: String]) {
        guard let s = session else { return }
        analytics.record(name, key: key, level: s.puzzle.id, config: s.config.version, parameters: parameters)
    }
    private func trackLevelStart() {
        guard let s = session, s.status == .playing else { return }
        track("level_start", key: s.id.uuidString, parameters: ["attempt_no": "\(s.attempt)", "grid_size": "\(s.puzzle.size)x\(s.puzzle.size)", "is_tutorial": "\(tutorial != nil)", "direct_find_visible": "\(directVisible)", "direct_find_inventory": "\(progress.availableDirect)", "hint_inventory": "\(progress.availableHints)", "level_start_free_available": "\(levelStartFreeAvailable)"])
        if tutorial != nil { track("tutorial_start", key: s.id.uuidString, parameters: ["tutorial_id": "level-1-dynamic"]) }
    }
    private func trackLevelEnd(_ result: String) {
        guard let s = session, result != "quit" || s.status == .playing else { return }
        track("level_end", key: s.id.uuidString, parameters: ["result": result, "duration_sec": "\(Int(s.elapsedSeconds))", "attempt_no": "\(s.attempt)", "fail_reason": result == "lose" ? "life_zero" : result == "quit" ? "quit" : "", "life_remaining": "\(s.lives)"])
    }
    private func trackTutorialEnd(_ result: String) {
        guard tutorial != nil, let s = session else { return }
        track("tutorial_end", key: s.id.uuidString + ":" + result, parameters: ["tutorial_id": "level-1-dynamic", "result": result, "duration_sec": "\(Int(s.elapsedSeconds))"])
    }
    private func trackBuff(_ type: String, applied: Bool, before: Int, after: Int, source: String) {
        track("buff_use", key: UUID().uuidString, parameters: ["buff_type": type, "source": source, "applied": "\(applied)", "inventory_before": "\(before)", "inventory_after": "\(after)"])
    }
    private func trackAdResult(_ id: String, status: String, granted: Bool) {
        let placement = rewardKind == .direct ? "direct_find" : rewardKind == .levelStartFree ? "level_start_free" : rewardKind.rawValue
        track("ad_result", key: id + ":" + status, parameters: ["offer_id": id, "placement_id": placement, "status": status, "reward_granted": "\(granted)", "ad_type": "rewarded", "network": "simulation", "ad_unit_id": "internal-demo", "error_code": status == "failed" ? "simulation_failed" : ""])
    }
    func exportDiagnostics() {
        struct Report: Encodable {
            let generatedAt: Date; let build: String; let demoConfig: DemoConfig
            let progress: PlayerProgress; let levelPackCount: Int
            let referenceGameplay: ReferenceGameplayConfiguration?; let generationReport: GenerationPipelineReport?
        }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            let report = Report(generatedAt: Date(), build: "\(version) (\(build))", demoConfig: config, progress: progress, levelPackCount: levels.count, referenceGameplay: referenceConfiguration, generationReport: lastGenerationReport)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Capydoku-diagnostics.json")
            try encoder.encode(report).write(to: url, options: .atomic)
            exportURL = url
        } catch { errorMessage = error.localizedDescription }
    }
}
