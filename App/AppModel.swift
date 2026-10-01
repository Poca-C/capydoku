import SwiftUI
import CapydokuCore

enum AppScreen { case home, game, checkIn }
enum AppSheet: String, Identifiable { case settings, debug, reward; var id: String { rawValue } }

struct DirectRevealFeedback: Equatable {
    let id = UUID()
    let sessionID: UUID
    let cell: Int
}

@MainActor
final class AppModel: ObservableObject {
    @Published var progress = PlayerProgress()
    // Presentation receipts are deliberately absent from PlayerProgress. A cold
    // restore or a return from Home must never look like a freshly generated board.
    @Published private(set) var boardEntranceID: UUID?
    @Published private(set) var directRevealFeedback: DirectRevealFeedback?
    @Published var screen: AppScreen = .home { didSet {
        if screen != .game { boardInputOwners.removeAll(); clearSceneFeedback() }
        syncFeedbackState(); restoreSavedHint(); schedulePendingLevelStart()
    } }
    @Published var sheet: AppSheet? { didSet { if sheet != nil { clearSceneFeedback() }; syncFeedbackState(); if sheet == nil { restoreSavedHint() }; schedulePendingLevelStart() } }
    @Published private(set) var hint: PuzzleHint? { didSet { if hint != nil { clearSceneFeedback() }; syncFeedbackState(); schedulePendingLevelStart() } }
    @Published var loading = false { didSet { if loading { clearSceneFeedback() }; syncFeedbackState(); if !loading { restoreSavedHint() }; schedulePendingLevelStart() } }
    @Published var notice: String? { didSet { if notice != nil { clearSceneFeedback() }; syncFeedbackState(); schedulePendingLevelStart() } }
    @Published var errorMessage: String? { didSet { if errorMessage != nil { clearSceneFeedback() }; syncFeedbackState(); schedulePendingLevelStart() } }
    @Published var rewardKind: RewardKind = .hint
    @Published var rewardScenario: RewardScenario = .success
    @Published var rewardBusy = false { didSet { if rewardBusy { clearSceneFeedback() }; schedulePendingLevelStart() } }
    @Published var interstitialBusy = false { didSet { if interstitialBusy { clearSceneFeedback() }; schedulePendingLevelStart() } }
    @Published var challengePending = false { didSet { if challengePending { clearSceneFeedback() }; syncFeedbackState(); schedulePendingLevelStart() } }
    @Published private(set) var referenceConfiguration: ReferenceGameplayConfiguration?
    @Published private(set) var lastGenerationReport: GenerationPipelineReport?
    private var winTransitionID: UUID?
    private var shownInterstitialWins = Set<UUID>()
    private var eligibleWinCount = 0
    private var lastInterstitialAt: Date?
    private var challengeSeen = false
    private var transitionToHome = false
    private var pendingInterstitialEvents: [AnalyticsRecorder.PreparedEvent] = []
    private var activeInterstitialOffer: AnalyticsRecorder.PreparedEvent?
    private struct WinContinuation: Codable {
        let winID: UUID
        let toHome: Bool
    }
    private var pendingWinContinuation: WinContinuation?
    private var winAdStateNeedsWrite = false
    private(set) var interstitialRecordingError: String?
    private struct WinAdState: Codable {
        var shown: Set<UUID>
        var eligibleCount: Int
        var lastShownAt: Date?
        var pendingEvents: [AnalyticsRecorder.PreparedEvent]?
        var pendingContinuation: WinContinuation?
    }
    @Published private(set) var rewardRetryPending = false
    @Published var config = DemoConfig.default
    @Published var jumpLevel = "1"
    @Published var exportURL: URL?
    @Published var now = Date()
    let saveDirectory: URL
    let analytics: AnalyticsRecorder
    private let store: SaveStore
    private let experimentalHistory: ExperimentalPuzzleHistoryStore
    private let generationAudits: GenerationAuditStore
    private let gameplayConfigurations: GameplayConfigurationStore
    private let saveQueue = DispatchQueue(label: "com.capydoku.progress-writes", qos: .utility)
    private let synchronousSaves: Bool
    private var saveRevision = 0
    private var levels: [Int: Puzzle] = [:]
    private var active = true
    // These transient owners are never saved and do not lock the board itself.
    // Each UIKit board owns its token until all recognizers finish, including
    // the system's single-tap wait for a possible second tap.
    private var boardInputOwners: [UUID: UUID] = [:]
    private var timer: Timer?
    private var loadingID = UUID()
    private var generationCandidateLimitOverride: Int?
    private var generationRetryCounts: [Int: Int] = [:]
    private var activeOfferID: String?
    private var rewardDeadline: DispatchWorkItem?
    private var pendingRewardSignal: RewardSignal?
    private var pendingRewardCompletion: Data?
    /// Observed SDK facts awaiting their first durable write. Keep the first
    /// prepared bytes on failure; a retry must not regenerate occurrence time.
    private var pendingRewardObservations: [String: [String: Data]] = [:]
    private(set) var rewardRecordingError: String?
    private var deferredRewardHintSessionID: UUID?
    private let rewardProvider: RewardProvider?
    private var activeRewardProvider: RewardProvider?
    private var rewardIsReady = false
    // Coalesces presentation requests; only .started confirms actual visibility.
    private var rewardPresentationRequested = false
    private var rewardDisplayActive = false
    private var rewardWasReplenished = false
    private var startupFlowCompleted = false
    private var preloadedSessionID: UUID?
    // An asynchronously prepared board is not a playable level_start. A cold
    // launch requests the saved attempt again through startOrContinue; the
    // analytics queue's existing attempt key also prevents repeats after delivery.
    private var pendingLevelStartID: UUID?
    private var levelStartDeliveryScheduled = false
    private let interstitialProvider: InterstitialProvider?
    private var activeInterstitialProvider: InterstitialProvider?
    private var interstitialIsReady = false
    private var interstitialPresentationRequested = false
    private var interstitialDisplayActive = false { didSet { syncFeedbackState() } }
    private var interstitialDeadline: DispatchWorkItem?
    private let rewardTimeout: TimeInterval
    private let feedbackEnabled: Bool
    private var lastRestartTime: TimeInterval = 0
    private var lastDirectTime: TimeInterval = 0
    private var lastSubmission: (sessionID: UUID, cell: Int, time: TimeInterval)?
    // Created on actual presentation, not when a preview is merely prepared.
    // A failed save retries the same first occurrence instead of retiming it.
    private var pendingHintAppearance: (useID: UUID, event: AnalyticsRecorder.PreparedEvent?)?
    /// Legacy mixed balances have no provable source. Keep gameplay available,
    /// but do not invent the required analytics enum for those consumptions.
    private(set) var unattributedToolUseCount = 0
    private let feedback: FeedbackPlayer
    var usesLocalTestAudio: Bool { feedback.usesLocalTestAudio }

    init(saveDirectory: URL? = nil, rewardProvider: RewardProvider? = nil,
         rewardTimeout: TimeInterval = 5, runsTimer: Bool = true, feedbackEnabled: Bool = true, bundledPuzzles: [Puzzle]? = nil, interstitialProvider: InterstitialProvider? = nil, startupBypassForTesting: Bool = true, analyticsIdentityStore: AnalyticsIdentityStore? = nil, gameplayConfigurationStore: GameplayConfigurationStore? = nil, feedbackPlayer: FeedbackPlayer? = nil) {
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
        self.saveDirectory = saveDirectory ?? root.appendingPathComponent(args.contains("-ui-testing") ? "CapydokuUITesting" : testHost ? "CapydokuAppTestingHost" : AppBuildConfiguration.current.storageDirectoryName, isDirectory: true)
        self.rewardProvider = rewardProvider
        self.interstitialProvider = interstitialProvider
        self.synchronousSaves = !runsTimer
        self.rewardTimeout = rewardTimeout.isFinite ? max(0.01, rewardTimeout) : 5
        self.feedback = feedbackPlayer ?? FeedbackPlayer()
        self.feedbackEnabled = feedbackEnabled && (!testHost || feedbackPlayer != nil)
        if args.contains("-reset-demo") { try? FileManager.default.removeItem(at: self.saveDirectory) }
        self.analytics = AnalyticsRecorder(directory: self.saveDirectory, identityStore: analyticsIdentityStore)
        let bundledConfiguration = Bundle.main.url(forResource: "reference-gameplay", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        self.gameplayConfigurations = gameplayConfigurationStore ?? GameplayConfigurationStore(
            directory: self.saveDirectory, target: .current, bundledData: bundledConfiguration,
            provider: HTTPGameplayConfigurationProvider.configured())
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
        experimentalHistory = ExperimentalPuzzleHistoryStore(directory: self.saveDirectory)
        generationAudits = GenerationAuditStore(directory: self.saveDirectory)
        let packError = errorMessage
        loadProgress()
        #if DEBUG
        // Historical UI regressions use English explicitly; ordinary installs
        // and bilingual persistence tests always use the saved preference.
        if args.contains("-ui-testing"),
           let raw = ProcessInfo.processInfo.environment["CAPYDOKU_UI_LANGUAGE"],
           let language = AppLanguage(rawValue: raw) {
            progress.settings.language = language
        }
        #endif
        if let packError { errorMessage = packError }
        if let state = try? DurableStateFile<WinAdState>(url: self.saveDirectory.appendingPathComponent("win-ad-state.json")).load() {
            shownInterstitialWins = state.shown; eligibleWinCount = max(0, state.eligibleCount); lastInterstitialAt = state.lastShownAt
            pendingInterstitialEvents = state.pendingEvents ?? []
            if let continuation = state.pendingContinuation,
               continuation.winID == session?.id, session?.status == .won, !continuation.toHome {
                pendingWinContinuation = continuation
                winTransitionID = continuation.winID; transitionToHome = false
            } else if state.pendingContinuation != nil {
                // Cold startup already fulfills Home; a saved later board also
                // proves this old transition was consumed. Clear without replay.
                winAdStateNeedsWrite = true
            }
        }
        let challengeFile = DurableStateFile<Bool>(url: self.saveDirectory.appendingPathComponent("challenge-state.json"))
        challengeSeen = (try? challengeFile.load()) ?? false
        if !challengeSeen, let old = try? Data(contentsOf: self.saveDirectory.appendingPathComponent("challenge-10-seen")), old == Data("original-8.2".utf8) {
            challengeSeen = true
            try? challengeFile.save(true)
        }
        referenceConfiguration = gameplayConfigurations.configuration
        gameplayConfigurations.onChange = { [weak self] candidate in
            // This is only the candidate for start(level:). Existing sessions and
            // in-flight ad receipts continue to use their saved configuration.
            self?.referenceConfiguration = candidate
        }
        applySettings()
        if runsTimer { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickGameplayClock()
            }
        } }
        if args.contains("-skip-tutorial") { progress.tutorialCompleted = true }
        if let i = args.firstIndex(of: "-generation-candidate-limit"), args.indices.contains(i + 1), let limit = Int(args[i + 1]) {
            generationCandidateLimitOverride = limit // Failure injection must not corrupt the saved session config.
        }
        if let i = args.firstIndex(of: "-level"), args.indices.contains(i + 1), let level = Int(args[i + 1]) {
            start(level: level)
        }
        refreshGameplayConfiguration()
    }

    deinit { timer?.invalidate(); rewardDeadline?.cancel(); interstitialDeadline?.cancel() }

    /// The production one-second timer and deterministic lifecycle tests share
    /// this entry point. Reading a tutorial still counts, as before; overlays,
    /// generation, startup and background time do not count as playable time.
    func tickGameplayClock() {
        now = Date()
        guard canTouchBoard else { return }
        progress.session?.advanceTime(by: 1)
        if (progress.session?.elapsedSeconds ?? 0).truncatingRemainder(dividingBy: 10) < 1 { save() }
    }

    var session: GameSession? { progress.session }
    var gameplayConfigurationDiagnostics: GameplayConfigurationDiagnostics { gameplayConfigurations.diagnostics }
    func refreshGameplayConfiguration(force: Bool = false) { gameplayConfigurations.refresh(force: force) }
    var directVisible: Bool { session?.config.referenceGameplay?.directFind.visible ?? true }
    var directEnabled: Bool {
        guard let row = session?.config.referenceGameplay else { return true }
        return row.directFind.enabled && row.directFind.buttonState == .enabled && (progress.availableDirect > 0 || (row.adsEnabled && row.directFind.rewardedAdEnabled))
    }
    var hintEnabled: Bool {
        guard let row = session?.config.referenceGameplay else { return true }
        return row.hint.enabled && row.hint.buttonState == .enabled && (progress.availableHints > 0 || (row.adsEnabled && row.hint.rewardedAdEnabled))
    }
    var levelStartFreeVisible: Bool {
        guard let row = session?.config.referenceGameplay else { return false }
        return row.adsEnabled && row.levelStartFreeAd.visible
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
        defer { syncFeedbackState() }
        guard reviveAvailable, sheet == nil, !rewardBusy else { return }
        if progress.freeRevivesRemaining > 0 {
            flushPendingSaves()
            do { _ = try store.transaction(progress: &progress) { $0.useFreeRevive() } }
            catch { errorMessage = "Your revival could not be saved. Please try again." }
        } else { offer(.revive) }
    }
    func levelStartFree() { guard !boardInputInProgress, levelStartFreeAvailable, canTouchBoard else { return }; offer(.levelStartFree) }
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
        let steps = PuzzleHints.tutorial(puzzle: s.puzzle, version: progress.tutorialPlanVersion)
        return steps.indices.contains(progress.tutorialStep) ? steps[progress.tutorialStep] : nil
    }
    var tutorialCount: Int { session.map { PuzzleHints.tutorial(puzzle: $0.puzzle, version: progress.tutorialPlanVersion).count } ?? 0 }

    func loadProgress() {
        clearSceneFeedback()
        pendingLevelStartID = nil
        flushPendingSaves(); saveRevision += 1
        rewardDeadline?.cancel(); rewardDeadline = nil
        let loaded = store.load()
        rewardDisplayActive = false
        hint = nil; pendingHintAppearance = nil; activeOfferID = nil; rewardBusy = false
        activeRewardProvider = nil; rewardIsReady = false; rewardPresentationRequested = false; rewardWasReplenished = false
        rewardRetryPending = false; pendingRewardSignal = nil; pendingRewardCompletion = nil
        deferredRewardHintSessionID = nil
        if sheet == .reward { sheet = nil }
        notice = nil; errorMessage = nil
        progress = loaded.progress
        // Recovery can compensate a receipt in memory even when its recovery
        // write failed. Confirm that state on disk before reporting any result.
        if analytics.enabled && (!progress.pendingBuffEvents.isEmpty || !progress.pendingLevelResultEvents.isEmpty ||
            !pendingRewardObservations.isEmpty || progress.rewardLedger.values.contains(where: { $0.completionEvent != nil || $0.analyticsOfferPending || !$0.pendingAdEvents.isEmpty })) { save(force: true) }
        syncFeedbackState()
        applySettings()
        if progress.session == nil { screen = .home }
        if let message = loaded.warning { notice = message }
        restoreSavedHint()
    }

    /// Normal gestures enqueue immutable snapshots. Receipt transactions and background
    /// transitions flush the same queue before committing, so an older snapshot can never
    /// overwrite a later reward or a restored save.
    func save(force: Bool = false) {
        guard persistRewardObservations() else { return }
        progress.captureSessionBalance()
        syncFeedbackState()
        let snapshot = progress
        let continuationAtSave = pendingWinContinuation?.winID
        saveRevision += 1; let revision = saveRevision
        let store = store
        if force || synchronousSaves {
            do {
                try saveQueue.sync { try store.save(snapshot) }
                acknowledgeSavedWinContinuation(snapshot, winID: continuationAtSave)
                deliverSavedGameplayEvents(snapshot)
            }
            catch { errorMessage = "Progress could not be saved: \(error.localizedDescription)" }
        } else {
            saveQueue.async { [weak self] in
                do {
                    try store.save(snapshot)
                    DispatchQueue.main.async {
                        self?.acknowledgeSavedWinContinuation(snapshot, winID: continuationAtSave)
                        self?.deliverSavedGameplayEvents(snapshot)
                    }
                }
                catch {
                    let message = "Progress could not be saved: \(error.localizedDescription)"
                    DispatchQueue.main.async { if self?.saveRevision == revision { self?.errorMessage = message } }
                }
            }
        }
    }
    func flushPendingSaves() { saveQueue.sync {} }

    private func deliverSavedGameplayEvents(_ saved: PlayerProgress) {
        guard deliverSavedRewardResults(saved.rewardLedger) else { return }
        // A tool may find the last animal. Its actual use precedes that win,
        // including after a queue failure or a cold start.
        if deliverSavedBuffUses(saved.pendingBuffEvents) {
            deliverSavedLevelResults(saved.pendingLevelResultEvents)
        }
    }

    private func deliverSavedBuffUses(_ saved: [String: Data]) -> Bool {
        guard analytics.enabled else { return saved.isEmpty }
        var acknowledged = false
        var complete = true
        let records = saved.compactMap { id, data -> (String, Data, AnalyticsRecorder.PreparedEvent)? in
            guard let event = try? JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: data),
                  event.event.eventID == id, event.event.eventName == "buff_use" else { return nil }
            return (id, data, event)
        }.sorted { $0.2.event.eventTime == $1.2.event.eventTime ? $0.2.key < $1.2.key : $0.2.event.eventTime < $1.2.event.eventTime }
        if records.count != saved.count { complete = false }
        for (id, data, prepared) in records {
            guard let current = progress.pendingBuffEvents[id] else { continue }
            guard current == data, analytics.commit(prepared) else { complete = false; break }
            progress.pendingBuffEvents.removeValue(forKey: id)
            acknowledged = true
        }
        // If this acknowledgement fails, the original prepared event remains in
        // the save and the analytics queue deduplicates its next delivery.
        if acknowledged { save() }
        return complete
    }

    private func deliverSavedLevelResults(_ saved: [String: Data]) {
        guard analytics.enabled else { return }
        var acknowledged = false
        let records = saved.compactMap { id, data -> (String, Data, AnalyticsRecorder.PreparedEvent)? in
            guard let event = try? JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: data) else { return nil }
            return (id, data, event)
        }.sorted { $0.2.event.eventTime == $1.2.event.eventTime ? $0.0 < $1.0 : $0.2.event.eventTime < $1.2.event.eventTime }
        for (id, data, prepared) in records {
            guard progress.pendingLevelResultEvents[id] == data,
                  prepared.event.eventID == id, prepared.event.eventName == "level_end",
                  analytics.commit(prepared) else { continue }
            progress.pendingLevelResultEvents.removeValue(forKey: id)
            acknowledged = true
        }
        // The queue is already durable. A crash before this acknowledgement is
        // saved merely re-delivers the original event through the same dedup key.
        if acknowledged { save() }
    }

    private func deliverSavedRewardResults(_ saved: [String: RewardRecord]) -> Bool {
        guard analytics.enabled else { return true }
        var acknowledged = false
        var complete = true
        let records = saved.filter { $0.value.analyticsOfferPending || !$0.value.pendingAdEvents.isEmpty || $0.value.completionEvent != nil }
        for (id, record) in records.sorted(by: { $0.value.createdAt < $1.value.createdAt }) {
            guard let current = progress.rewardLedger[id] else { continue }
            if let offerData = record.analyticsOffer {
                guard current.analyticsOffer == offerData,
                      let offer = try? JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: offerData),
                      offer.event.eventName == "ad_offer_shown", offer.event.parameters["offer_id"] == .text(id),
                      analytics.commit(offer) else { complete = false; continue }
                if current.analyticsOfferPending {
                    progress.rewardLedger[id]?.analyticsOfferPending = false
                    acknowledged = true
                }
            }
            let observations = record.pendingAdEvents.compactMap { eventID, data -> (String, Data, AnalyticsRecorder.PreparedEvent)? in
                guard let event = try? JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: data),
                      event.event.eventID == eventID, event.event.eventName == "ad_result",
                      event.event.parameters["offer_id"] == .text(id),
                      event.event.parameters["reward_granted"] == .flag(false),
                      ["started", "skipped", "failed"].contains(where: { event.event.parameters["status"] == .text($0) }) else { return nil }
                return (eventID, data, event)
            }.sorted {
                // Provider callbacks define lifecycle order even when wall clock
                // moves backwards between presentation and its final outcome.
                let a = $0.2.event.parameters["status"] == .text("started")
                let b = $1.2.event.parameters["status"] == .text("started")
                return a != b ? a : $0.2.event.eventTime < $1.2.event.eventTime
            }
            var lifecycleComplete = observations.count == record.pendingAdEvents.count
            for (eventID, data, prepared) in observations {
                guard let currentData = progress.rewardLedger[id]?.pendingAdEvents[eventID] else { continue }
                guard currentData == data, analytics.commit(prepared) else { lifecycleComplete = false; break }
                progress.rewardLedger[id]?.pendingAdEvents.removeValue(forKey: eventID)
                acknowledged = true
            }
            guard lifecycleComplete else { complete = false; continue }
            guard [.executed, .compensated, .cancelled].contains(record.state),
                  let data = record.completionEvent,
                  progress.rewardLedger[id]?.completionEvent == data,
                  progress.rewardLedger[id]?.state == record.state,
                  var completed = try? JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: data),
                  completed.event.eventName == "ad_result",
                  completed.event.parameters["offer_id"] == .text(id),
                  completed.event.parameters["status"] == .text("completed") else { continue }
            // Receipt proves completion; actual execution/compensation decides
            // reward_granted. A killed revive is never compensated or reported granted.
            completed.event.parameters["reward_granted"] = .flag(record.state == .executed || record.state == .compensated)
            guard analytics.commit(completed) else { complete = false; continue }
            progress.rewardLedger[id]?.completionEvent = nil
            acknowledged = true
        }
        if acknowledged { save() }
        return complete
    }

    /// This is a storage retry, never an advertisement replay. A failed started
    /// write must not dismiss or interfere with the currently playing video.
    @discardableResult private func persistRewardObservations() -> Bool {
        guard !pendingRewardObservations.isEmpty else { return true }
        // A failed terminal transaction must retry through receive(), which
        // commits its ledger outcome with these observations. A timer or
        // background save cannot acknowledge only half of that transaction.
        guard !rewardRetryPending || pendingRewardSignal == nil else { return false }
        flushPendingSaves(); saveRevision += 1
        do {
            try store.transaction(progress: &progress) { candidate in
                for (offerID, events) in pendingRewardObservations where candidate.rewardLedger[offerID] != nil {
                    candidate.rewardLedger[offerID]?.pendingAdEvents.merge(events) { original, _ in original }
                }
            }
            acknowledgeRewardObservations(progress.rewardLedger)
            return true
        } catch {
            rewardRecordingError = "Observed advertisement events await a storage retry: \(error.localizedDescription)"
            return false
        }
    }

    private func acknowledgeRewardObservations(_ saved: [String: RewardRecord]) {
        for (offerID, events) in pendingRewardObservations {
            for (id, data) in events where saved[offerID]?.pendingAdEvents[id] == data {
                pendingRewardObservations[offerID]?.removeValue(forKey: id)
            }
            if pendingRewardObservations[offerID]?.isEmpty == true { pendingRewardObservations.removeValue(forKey: offerID) }
        }
        if pendingRewardObservations.isEmpty { rewardRecordingError = nil }
    }

    private func stageRewardObservation(_ record: RewardRecord, status: String, errorCode: String = "") {
        // The display flag and first-terminal-signal gate prevent duplicates in
        // memory; the frozen event key also protects a lost acknowledgement.
        guard let data = prepareRewardResult(record, status: status, errorCode: errorCode),
              let event = try? JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: data) else { return }
        let alreadyPending = pendingRewardObservations[record.id, default: [:]].values.contains {
            (try? JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: $0).key) == event.key
        }
        guard !alreadyPending else { return }
        pendingRewardObservations[record.id, default: [:]][event.event.eventID] = data
    }

    func startOrContinue() {
        if session != nil {
            if progress.session?.resumeAfterQuit() == true { save() }
            screen = .game
            if pendingWinContinuation?.winID == session?.id, winTransitionID != nil {
                completeWinTransition(); return
            }
            trackLevelStart(); preloadRewardPlacementsIfNeeded()
            restoreSavedHint()
        }
        else { start(level: progress.currentLevel) }
    }

    func start(level: Int) {
        guard !loading else { return }
        clearSceneFeedback()
        pendingLevelStartID = nil
        hint = nil; pendingHintAppearance = nil
        if let puzzle = levels[level] {
            progress.begin(puzzle: puzzle, config: configuration(for: level))
            screen = .game; save(); publishBoardEntrance(); trackLevelStart(); preloadRewardPlacementsIfNeeded(); return
        }
        guard level >= 151 && level <= 100_000 else {
            errorMessage = "This level is not included in the demo pack."; return
        }
        loading = true
        lastGenerationReport = nil
        flushPendingSaves()
        let request = UUID(); loadingID = request
        let configuration = configuration(for: level)
        let candidateLimit = generationCandidateLimitOverride ?? configuration.generatorCandidateLimit
        let retry = generationRetryCounts[level, default: 0]
        generationRetryCounts[level] = retry + 1
        let retrySeed: UInt64? = retry == 0 ? nil : (UInt64(level) &* 0x9E3779B97F4A7C15 &+ 0xCA9D0C0) ^ (UInt64(retry) &* 0xD1B54A32D192ED03)
        let packaged = Array(levels.values)
        let history = experimentalHistory
        let audits = generationAudits
        let checkpoint = progress.experimentalHistoryCheckpoint
        let requiredLevels = Set((progress.attemptCounts.keys.compactMap(Int.init)
            + Array(progress.completedLevels) + [session?.puzzle.id].compactMap { $0 }).filter { $0 >= 151 })
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> (GenerationPipelineResult, ExperimentalHistoryCheckpoint?) in
                let previous = try history.load(checkpoint: checkpoint, requiredLevels: requiredLevels)
                // Same-level variants are still historical boards and must not
                // disappear from the similarity corpus on a repeat/debug start.
                let corpus = packaged.map { SimilarityCorpusEntry(game: "CapyDoku", puzzle: $0) } + previous.corpus
                let generated = try PuzzleGenerator.generateAudited(level: level, seed: retrySeed, corpus: corpus, similarityConfiguration: .strict, maxAttempts: candidateLimit, timeBudgetMilliseconds: configuration.generatorBudgetMilliseconds)
                // Original [190–194]: retain the complete batch result, including
                // rejected batches, before a selected board can become playable.
                try audits.record(generated)
                let committed = try generated.puzzle.map { try history.record($0, checkpoint: checkpoint, requiredLevels: requiredLevels) }
                return (generated, committed)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadingID == request else { return }
                self.loading = false
                switch result {
                case .success(let (generation, historyCheckpoint)):
                    self.lastGenerationReport = generation.report
                    guard let puzzle = generation.puzzle else {
                        if generation.report.termination == "answer_space_exhausted" {
                            self.errorMessage = "No unused board remains within the configured size range. Your current board is intact."
                            return
                        }
                        self.errorMessage = "Generation stopped safely. Your current board is intact. Please retry. \(generation.report.termination)"; return
                    }
                    // The history and new board reference must be durable before
                    // replacing the playable state. A write failure keeps the old
                    // in-memory board, inventory and attempt counts unchanged.
                    var candidate = self.progress
                    do {
                        try self.saveQueue.sync {
                            try self.store.transaction(progress: &candidate) {
                                $0.begin(puzzle: puzzle, config: configuration)
                                $0.experimentalHistoryCheckpoint = historyCheckpoint
                            }
                        }
                        self.progress = candidate
                        self.hint = nil; self.pendingHintAppearance = nil
                        self.screen = .game; self.publishBoardEntrance(); self.trackLevelStart(); self.preloadRewardPlacementsIfNeeded()
                    } catch {
                        self.errorMessage = "Generation stopped safely. Your current board is intact. Please retry. \(error.localizedDescription)"
                    }
                case .failure(let error):
                    self.errorMessage = error is ExperimentalPuzzleHistoryStore.HistoryError ? error.localizedDescription
                        : "Generation stopped safely. Your current board is intact. Please retry. \(error.localizedDescription)"
                }
            }
        }
    }

    func home() {
        guard screen == .game else { hint = nil; screen = .home; return }
        if hint != nil && !closeHint() { return }
        if session?.status == .won { transitionAfterWin(toHome: true); return }
        trackLevelEnd(.quit); trackTutorialEnd("quit"); hint = nil; screen = .home; save()
    }
    func next() { transitionAfterWin(toHome: false) }
    private func transitionAfterWin(toHome: Bool) {
        guard active, startupFlowCompleted, sheet == nil, hint == nil, notice == nil, errorMessage == nil,
              let s = session, s.status == .won, !interstitialBusy, !challengePending, winTransitionID == nil else { return }
        // The durable ad reservation must refer to a durable winning board,
        // including when the last gesture's normal save is still queued.
        save(force: true)
        guard errorMessage == nil else { return }
        transitionToHome = toHome; winTransitionID = s.id
        if let row = s.config.referenceGameplay, row.adsEnabled, row.interstitial.enabled,
           s.puzzle.id >= row.interstitial.startLevel, !shownInterstitialWins.contains(s.id),
           toHome ? row.interstitial.onReturnHome : row.interstitial.onNextLevel {
            let previous = winAdState
            shownInterstitialWins.insert(s.id); eligibleWinCount += 1
            let cooled = Date().timeIntervalSince(lastInterstitialAt ?? .distantPast) >= Double(row.interstitial.cooldownSeconds)
            if eligibleWinCount % max(1, row.interstitial.frequency) == 0 && cooled {
                let provider = interstitialProvider ?? MockInterstitialProvider(scenario: rewardScenario)
                let metadata = provider.analyticsMetadata
                let offerID = UUID().uuidString
                activeInterstitialOffer = analytics.prepare("ad_offer_shown", key: offerID, level: s.puzzle.id, config: s.config.version,
                    parameters: ["offer_id": offerID, "placement_id": metadata.placementID, "reward_type": "", "buff_type": "", "reward_amount": "0",
                                 "ad_type": "interstitial", "network": metadata.network, "ad_unit_id": metadata.adUnitID])
                if let offer = activeInterstitialOffer { pendingInterstitialEvents.append(offer) }
                lastInterstitialAt = Date()
                // Reserve the winning result and freeze its offer together before
                // requesting the provider. A failed load still consumes this win.
                guard persistWinAdState(previous: previous) else { winTransitionID = nil; activeInterstitialOffer = nil; return }
                flushInterstitialEvents()
                interstitialBusy = true; sheet = .reward
                let deadline = DispatchWorkItem { [weak self] in self?.receiveInterstitial(.timedOut, winID: s.id, errorCode: "loading_timeout") }
                interstitialDeadline = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(row.interstitial.adTimeoutSeconds), execute: deadline)
                activeInterstitialProvider = provider
                interstitialIsReady = false; interstitialPresentationRequested = false; interstitialDisplayActive = false
                provider.load { [weak self] readiness in
                    DispatchQueue.main.async { self?.receiveInterstitialReadiness(readiness, winID: s.id) }
                }
                if provider.isReady { receiveInterstitialReadiness(.ready, winID: s.id) }
                return
            }
            guard persistWinAdState(previous: previous) else { winTransitionID = nil; return }
        }
        completeWinTransition()
    }
    private func receiveInterstitialReadiness(_ readiness: RewardReadiness, winID: UUID) {
        guard interstitialBusy, winTransitionID == winID, !interstitialPresentationRequested else { return }
        switch readiness {
        case .unavailable: receiveInterstitial(.failed, winID: winID, errorCode: "load_unavailable")
        case .ready:
            // Original §8.2 limits loading, not the duration of an ad already ready to show.
            interstitialDeadline?.cancel(); interstitialDeadline = nil
            interstitialIsReady = true
            displayReadyInterstitial()
        }
    }
    private func displayReadyInterstitial() {
        guard active, startupFlowCompleted, interstitialBusy, interstitialIsReady,
              !interstitialPresentationRequested, let winID = winTransitionID,
              let provider = activeInterstitialProvider else { return }
        interstitialPresentationRequested = true
        provider.present { [weak self] signal in
            DispatchQueue.main.async { self?.receiveInterstitial(signal, winID: winID) }
        }
    }
    private func receiveInterstitial(_ signal: InterstitialSignal, winID: UUID, errorCode: String = "") {
        guard interstitialBusy, winTransitionID == winID else { return }
        if signal == .started {
            guard interstitialPresentationRequested, !interstitialDisplayActive else { return }
            interstitialDisplayActive = true
            recordInterstitialResult(status: "started")
            return
        }
        if signal == .closed || signal == .skipped {
            guard interstitialPresentationRequested else { return }
        }
        pendingWinContinuation = WinContinuation(winID: winID, toHome: transitionToHome)
        winAdStateNeedsWrite = true
        switch signal {
        case .closed:
            // Internal mapping v1: normally closed display, not proof that a
            // whole video was watched. The frozen production mapping is pending.
            recordInterstitialResult(status: "completed")
        case .skipped:
            recordInterstitialResult(status: "skipped")
        case .failed: recordInterstitialResult(status: "failed", errorCode: errorCode.isEmpty ? "presentation_failed" : errorCode)
        case .timedOut: recordInterstitialResult(status: "failed", errorCode: errorCode.isEmpty ? "provider_timeout" : errorCode)
        case .started: return
        }
        flushInterstitialEvents()
        interstitialDeadline?.cancel(); interstitialDeadline = nil
        activeInterstitialProvider = nil; activeInterstitialOffer = nil
        interstitialIsReady = false; interstitialPresentationRequested = false; interstitialDisplayActive = false
        interstitialBusy = false; sheet = nil; completeWinTransition()
    }
    private func recordInterstitialResult(status: String, errorCode: String = "") {
        guard let offer = activeInterstitialOffer,
              case .text(let offerID) = offer.event.parameters["offer_id"],
              case .text(let placement) = offer.event.parameters["placement_id"],
              case .text(let network) = offer.event.parameters["network"],
              case .text(let unit) = offer.event.parameters["ad_unit_id"],
              let event = analytics.prepareRelated("ad_result", key: offerID + ":" + status, to: offer.event,
                 parameters: ["offer_id": offerID, "placement_id": placement, "status": status, "reward_granted": "false",
                              "error_code": errorCode, "ad_type": "interstitial", "network": network, "ad_unit_id": unit]) else { return }
        pendingInterstitialEvents.append(event)
        flushInterstitialEvents()
    }
    private var winAdState: WinAdState {
        WinAdState(shown: shownInterstitialWins, eligibleCount: eligibleWinCount, lastShownAt: lastInterstitialAt,
                   pendingEvents: pendingInterstitialEvents, pendingContinuation: pendingWinContinuation)
    }
    /// Retry the same frozen events. Never invent a terminal outcome after a
    /// crash, and never replay an ad merely because analytics delivery failed.
    private func flushInterstitialEvents() {
        guard !pendingInterstitialEvents.isEmpty || pendingWinContinuation != nil || winAdStateNeedsWrite else { return }
        let file = DurableStateFile<WinAdState>(url: saveDirectory.appendingPathComponent("win-ad-state.json"))
        do { try file.save(winAdState); winAdStateNeedsWrite = false; interstitialRecordingError = nil }
        catch { interstitialRecordingError = "Interstitial events await a storage retry: \(error.localizedDescription)"; return }
        guard analytics.enabled else { return }
        var acknowledged = Set<String>()
        for event in pendingInterstitialEvents {
            guard analytics.commit(event) else { break }
            acknowledged.insert(event.key)
        }
        guard !acknowledged.isEmpty else { return }
        let previous = pendingInterstitialEvents
        pendingInterstitialEvents.removeAll { acknowledged.contains($0.key) }
        do { try file.save(winAdState) }
        catch {
            pendingInterstitialEvents = previous
            interstitialRecordingError = "Interstitial acknowledgement awaits a storage retry: \(error.localizedDescription)"
        }
    }
    private func acknowledgeSavedWinContinuation(_ saved: PlayerProgress, winID: UUID?) {
        guard let continuation = pendingWinContinuation, saved.session != nil,
              continuation.winID == winID, saved.session?.id != continuation.winID else { return }
        if winTransitionID == continuation.winID { winTransitionID = nil }
        pendingWinContinuation = nil; winAdStateNeedsWrite = true
        flushInterstitialEvents()
    }
    private func persistWinAdState(previous: WinAdState) -> Bool {
        do {
            try DurableStateFile<WinAdState>(url: saveDirectory.appendingPathComponent("win-ad-state.json")).save(winAdState)
            winAdStateNeedsWrite = false
            return true
        } catch {
            shownInterstitialWins = previous.shown; eligibleWinCount = previous.eligibleCount; lastInterstitialAt = previous.lastShownAt
            pendingInterstitialEvents = previous.pendingEvents ?? []
            pendingWinContinuation = previous.pendingContinuation
            errorMessage = "The level transition could not be saved. Please try again."; return false
        }
    }
    private func completeWinTransition() {
        // A final SDK callback may arrive in the background. Preserve the
        // original destination and do not create an unplayable level_start.
        guard active else { return }
        guard let s = session, s.id == winTransitionID else { winTransitionID = nil; return }
        if transitionToHome {
            winTransitionID = nil; hint = nil; screen = .home
            pendingWinContinuation = nil; winAdStateNeedsWrite = true; flushInterstitialEvents()
            save(); return
        }
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
        guard !loading, !rewardBusy, let current = session, time - lastRestartTime > 0.4 else { return }
        guard current.config.referenceGameplay?.failure.restartCreatesNewBoard != true else {
            errorMessage = "This imported configuration requires an alternate packaged board. That reference behavior is not available in this build. Your current progress is intact."
            return
        }
        lastRestartTime = time
        pendingLevelStartID = nil
        hint = nil
        track("level_restart", key: current.id.uuidString, parameters: ["restart_reason": current.status == .lost ? "after_fail" : "manual", "previous_fail_reason": current.status == .lost ? "life_zero" : "", "next_attempt_no": "\(current.attempt + 1)"])
        progress.restart()
        // Settings is also reachable from Home. Restart opens the reset board
        // before recording the new playable attempt (original [291], [364]).
        screen = .game
        save(); publishBoardEntrance(); trackLevelStart()
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
        syncFeedbackState(); defer { syncFeedbackState() }
        guard canTouchBoard, tutorialAllows("tap", cells: [cell]) else { return }
        let wasMarked = session?.marks.contains(cell) == true
        if progress.session?.toggleMark(at: cell) == true {
            feedback.play(wasMarked ? .erase : .mark)
            if tutorial != nil { advanceTutorial() }
            save()
        }
    }
    func mark(_ cells: [Int]) {
        syncFeedbackState(); defer { syncFeedbackState() }
        guard canTouchBoard, tutorialAllows("swipe", cells: cells) else { return }
        let count = progress.session?.markMany(cells) ?? 0
        guard count > 0 else { return }
        feedback.playMarks(count: count)
        if let t = tutorial, Set(t.targetCells).isSubset(of: session?.marks ?? []) { advanceTutorial() }
        save()
    }
    func submit(_ cell: Int) {
        syncFeedbackState(); defer { syncFeedbackState() }
        guard canTouchBoard, tutorialAllows("doubleTap", cells: [cell]), let sessionID = session?.id else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        // Ignore a duplicated delivery of this gesture, not all future attempts at this cell.
        if let last = lastSubmission, last.sessionID == sessionID, last.cell == cell, timestamp - last.time < 0.28 { return }
        lastSubmission = (sessionID, cell, timestamp)
        let result = progress.session?.submit(cell: cell)
        switch result {
        case .correct:
            playRevealFeedback()
            if tutorial != nil { advanceTutorial() }
            afterAction()
        case .incorrect: feedback.play(.wrong); if session?.status == .lost { trackLevelEnd(.lose) }; save()
        default: break
        }
    }
    private func playRevealFeedback(acceptedIn context: FeedbackEnvironment? = nil) {
        feedback.play(.correct, acceptedIn: context)
        if let count = session?.combo { feedback.play(.combo(count), acceptedIn: context) }
    }
    private func afterAction() {
        if progress.finishWin() { feedback.play(.win); trackLevelEnd(.win) }
        save()
    }
    func direct() {
        syncFeedbackState(); defer { syncFeedbackState() }
        let time = ProcessInfo.processInfo.systemUptime
        guard !boardInputInProgress, canTouchBoard, tutorial == nil, directVisible, directEnabled, time - lastDirectTime > 0.35 else { return }
        if progress.availableDirect == 0 { lastDirectTime = time; offer(.direct); return }
        let source = progress.nextDirectSource
        flushPendingSaves(); saveRevision += 1
        do {
            let revealed = try store.transaction(progress: &progress) { candidate -> Int? in
                let before = candidate.availableDirect
                guard let cell = candidate.directFind() else { return nil }
                stageBuff("direct_find", key: UUID().uuidString, applied: true, before: before,
                          after: candidate.availableDirect, source: source, in: &candidate)
                if candidate.finishWin() { stageLevelEnd(.win, in: &candidate) }
                return cell
            }
            guard let revealed else { return }
            lastDirectTime = time
            publishDirectReveal(cell: revealed)
            if source == nil { unattributedToolUseCount += 1 }
            playRevealFeedback()
            if session?.status == .won { feedback.play(.win) }
            deliverSavedGameplayEvents(progress)
        } catch {
            errorMessage = "The tool could not be saved. No use was spent. Please try again."
        }
    }
    func showHint() {
        guard !boardInputInProgress, canTouchBoard, tutorial == nil, hintEnabled, let s = session, s.status == .playing else { return }
        guard let preview = PuzzleHints.next(puzzle: s.puzzle, found: s.found, marks: s.marks) else {
            notice = "Every useful exclusion is already marked. Try locating the remaining capybaras."; return
        }
        if progress.availableHints == 0 { offer(.hint); return }
        flushPendingSaves(); saveRevision += 1
        do {
            let consumed = try store.transaction(progress: &progress) { candidate -> Bool in
                let before = candidate.availableHints, source = candidate.nextHintSource
                guard candidate.consumeHint() else { return false }
                candidate.activeHintUse = HintUseState(sessionID: s.id, hint: preview, source: source,
                    inventoryBefore: before, inventoryAfter: candidate.availableHints)
                return true
            }
            guard consumed else { return }
            pendingHintAppearance = nil
            hint = preview
        } catch {
            errorMessage = "The hint could not be saved. No use was spent. Please try again."
        }
    }

    private func restoreSavedHint() {
        guard active, screen == .game, sheet == nil, !loading, !rewardBusy, !interstitialBusy,
              let use = progress.activeHintUse, use.sessionID == session?.id,
              session?.status == .playing else { return }
        hint = use.hint
    }

    /// The view calls this only when its HintPanel appears. Preparing a saved
    /// preview (or recovering it on Home) does not prove that it was displayed.
    func hintDidAppear(useID: UUID) {
        guard active, screen == .game, sheet == nil, !loading, !rewardBusy, !interstitialBusy, !challengePending,
              errorMessage == nil, notice == nil,
              let use = progress.activeHintUse, use.id == useID,
              use.sessionID == session?.id, hint == use.hint, !use.previewPresented else { return }
        if pendingHintAppearance?.useID != useID {
            pendingHintAppearance = (useID, prepareBuff("hint", key: useID.uuidString + ":0-preview",
                applied: false, before: use.inventoryBefore, after: use.inventoryAfter,
                source: use.source, in: progress))
        }
        flushPendingSaves(); saveRevision += 1
        do {
            try store.transaction(progress: &progress) { candidate in
                candidate.activeHintUse?.previewPresented = true
                if let prepared = pendingHintAppearance?.event,
                   let data = try? JSONEncoder().encode(prepared) {
                    candidate.pendingBuffEvents[prepared.event.eventID] = data
                }
            }
            if use.source == nil { unattributedToolUseCount += 1 }
            pendingHintAppearance = nil
            deliverSavedGameplayEvents(progress)
        } catch {
            errorMessage = "The displayed hint could not be saved. Please try again."
        }
    }

    @discardableResult func closeHint() -> Bool {
        guard active, screen == .game, sheet == nil, !loading, !rewardBusy, !interstitialBusy, !challengePending,
              errorMessage == nil, notice == nil,
              let use = progress.activeHintUse, use.sessionID == session?.id,
              hint == use.hint else { return hint == nil }
        // An actual close/Apply interaction also proves the panel was visible.
        hintDidAppear(useID: use.id)
        guard progress.activeHintUse?.previewPresented == true else { return false }
        flushPendingSaves(); saveRevision += 1
        do {
            try store.transaction(progress: &progress) { $0.activeHintUse = nil }
            hint = nil; pendingHintAppearance = nil
            deliverSavedGameplayEvents(progress)
            return true
        } catch {
            errorMessage = "The hint could not be closed safely. Please try again."
            return false
        }
    }

    func applyHint() {
        guard active, screen == .game, sheet == nil, !loading, !rewardBusy, !interstitialBusy, !challengePending,
              errorMessage == nil, notice == nil,
              session?.status == .playing, let use = progress.activeHintUse,
              use.sessionID == session?.id, hint == use.hint else { return }
        hintDidAppear(useID: use.id)
        guard progress.activeHintUse?.previewPresented == true else { return }
        flushPendingSaves(); saveRevision += 1
        do {
            let count = try store.transaction(progress: &progress) { candidate -> Int in
                let count = candidate.session?.markMany(use.hint.cells) ?? 0
                guard count > 0 else { return 0 }
                stageBuff("hint", key: use.id.uuidString + ":1-apply", applied: true,
                          before: candidate.availableHints, after: candidate.availableHints,
                          source: use.source, in: &candidate)
                candidate.activeHintUse = nil
                return count
            }
            guard count > 0 else { return }
            hint = nil; pendingHintAppearance = nil
            deliverSavedGameplayEvents(progress)
        } catch {
            errorMessage = "The hint marks could not be saved. Your board is unchanged. Please try again."
        }
    }
    func offer(_ kind: RewardKind) {
        guard !boardInputInProgress, startupFlowCompleted, !loading, !rewardBusy, !interstitialBusy, sheet == nil, hint == nil, progress.canReceiveReward(kind) else { return }
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
        guard !boardInputInProgress, startupFlowCompleted, active, sheet == .reward, !loading, !rewardBusy, !interstitialBusy else { return }
        if let offerID = activeOfferID, let signal = pendingRewardSignal {
            errorMessage = nil
            rewardBusy = true
            receive(signal, offerID: offerID)
            return
        }
        let offerID = UUID().uuidString
        do {
            flushPendingSaves()
            let provider = rewardProvider ?? MockRewardProvider(scenario: rewardScenario)
            let metadata = provider.analyticsMetadata
            let placement = rewardKind == .direct ? "direct_find" : rewardKind == .levelStartFree ? "level_start_free" : rewardKind.rawValue
            let rewardType = rewardKind == .levelStartFree ? (session?.config.referenceGameplay?.levelStartFreeAd.reward.rawValue ?? "") : placement
            let offered = session.flatMap { analytics.prepare("ad_offer_shown", key: offerID, level: $0.puzzle.id, config: $0.config.version,
                parameters: ["offer_id": offerID, "placement_id": placement, "reward_type": rewardType, "buff_type": rewardKind == .revive ? "" : rewardType, "reward_amount": "\(rewardKind == .levelStartFree ? ($0.config.referenceGameplay?.levelStartFreeAd.rewardCount ?? 0) : 1)", "ad_type": "rewarded", "network": metadata.network, "ad_unit_id": metadata.adUnitID]) }
            let offerData = offered.flatMap { try? JSONEncoder().encode($0) }
            guard try store.prepareReward(offerID: offerID, kind: rewardKind, progress: &progress, analyticsOffer: offerData) else {
                notice = "This reward is not available right now."; sheet = nil; return
            }
            activeOfferID = offerID
            activeRewardProvider = provider
            pendingRewardCompletion = nil
            rewardIsReady = false; rewardPresentationRequested = false; rewardWasReplenished = false
            deliverSavedGameplayEvents(progress)
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
        guard activeOfferID == offerID, rewardBusy, !rewardPresentationRequested, pendingRewardSignal == nil,
              progress.rewardLedger[offerID]?.state == .offered else { return }
        switch readiness {
        case .unavailable: receive(.failed, offerID: offerID, errorCode: "unavailable")
        case .ready:
            // ad_timeout_sec applies while loading. A playing ad must await its
            // final SDK outcome, including a valid reward after a long video.
            rewardDeadline?.cancel(); rewardDeadline = nil
            rewardIsReady = true
            displayReadyReward(offerID: offerID)
        }
    }
    private func displayReadyReward(offerID: String) {
        guard startupFlowCompleted, active, sheet == .reward, activeOfferID == offerID,
              rewardBusy, rewardIsReady, !rewardPresentationRequested, pendingRewardSignal == nil,
              let provider = activeRewardProvider else { return }
        rewardPresentationRequested = true
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
    private func receive(_ signal: RewardSignal, offerID: String, errorCode: String = "") {
        // A late duplicate must not dismiss a newer sheet or unlock a newer transaction.
        guard let record = progress.rewardLedger[offerID], record.state == .offered || record.state == .rewarded else { return }
        guard activeOfferID == offerID else { return }
        guard rewardBusy else { return } // A failed write retains the first result for explicit retry.
        if signal == .started {
            guard rewardPresentationRequested, pendingRewardSignal == nil, record.state == .offered,
                  !rewardDisplayActive else { return }
            rewardDisplayActive = true
            syncFeedbackState()
            stageRewardObservation(record, status: "started")
            if persistRewardObservations() { deliverSavedGameplayEvents(progress) }
            return
        }
        // The adapter delivers a final display outcome. Receipt persistence may still
        // need retry, but the video itself no longer owns the audio session.
        rewardDisplayActive = false
        defer { syncFeedbackState() }
        rewardDeadline?.cancel(); rewardDeadline = nil
        rewardBusy = false
        pendingRewardSignal = signal
        if (signal == .earned || signal == .interrupted), pendingRewardCompletion == nil {
            pendingRewardCompletion = record.completionEvent ?? prepareRewardCompletion(record)
        }
        if signal == .cancelled || signal == .failed || signal == .timedOut {
            stageRewardObservation(record, status: signal == .cancelled ? "skipped" : "failed",
                errorCode: signal == .cancelled ? "" : signal == .timedOut ? "loading_timeout" : errorCode.isEmpty ? "presentation_failed" : errorCode)
        }
        flushPendingSaves()
        do {
            switch signal {
            case .started: return // Nonterminal presentation signals are handled above.
            case .earned:
                let result = try store.grantReward(offerID: offerID, progress: &progress, completionEvent: pendingRewardCompletion,
                    pendingEvents: pendingRewardObservations[offerID, default: [:]]) { candidate, outcome in
                    self.finalizeRewardResult(outcome, in: &candidate, offerID: offerID)
                }
                acknowledgeRewardObservations(progress.rewardLedger)
                deliverSavedGameplayEvents(progress)
                sheet = nil
                switch result {
                case .hintReady:
                    deferredRewardHintSessionID = session?.id
                    resumeConfirmedRewardHint()
                case .directRevealed(let cell):
                    publishDirectReveal(cell: cell)
                    if screen == .game {
                        playRevealFeedback(acceptedIn: FeedbackEnvironment(page: .game, level: session?.puzzle.id))
                        if session?.status == .won { feedback.play(.win) }
                    }
                case .inventoryGranted: break
                case .revived: break
                case .duplicate: break
                case .compensated: notice = "Reward saved to your inventory."
                case .ignored: break
                }
            case .cancelled, .failed, .timedOut:
                try store.cancelReward(offerID: offerID, progress: &progress, pendingEvents: pendingRewardObservations[offerID, default: [:]])
                acknowledgeRewardObservations(progress.rewardLedger)
                deliverSavedGameplayEvents(progress)
                sheet = nil
                switch signal {
                case .cancelled: notice = "Simulation cancelled. No reward was issued."
                case .timedOut: notice = "The reward simulation timed out. No reward was issued. You can try again."
                default: notice = "Video unavailable. Please try again."
                }
            case .interrupted:
                try store.markRewardReceived(offerID: offerID, progress: &progress, completionEvent: pendingRewardCompletion,
                    pendingEvents: pendingRewardObservations[offerID, default: [:]])
                acknowledgeRewardObservations(progress.rewardLedger)
                deliverSavedGameplayEvents(progress)
                sheet = nil
                notice = "Reward receipt saved. Use Recover save in Developer tools, or relaunch, to test interruption recovery."
            }
            activeOfferID = nil; pendingRewardSignal = nil; pendingRewardCompletion = nil; rewardRetryPending = false
            activeRewardProvider = nil; rewardIsReady = false
        } catch {
            // grantReward may have saved the receipt before its effect write
            // failed. Acknowledge only matching observed bytes in that receipt.
            acknowledgeRewardObservations(progress.rewardLedger)
            rewardRetryPending = true
            errorMessage = "The reward could not be saved. Free up storage if needed, then tap Retry save. Your receipt is kept for this retry. \(error.localizedDescription)"
        }
    }
    private var canTouchBoard: Bool {
        active && startupFlowCompleted && screen == .game && !loading && !rewardBusy && !interstitialBusy &&
        !challengePending && sheet == nil && hint == nil && progress.activeHintUse == nil &&
        notice == nil && errorMessage == nil && session?.status == .playing
    }

    private func clearSceneFeedback() {
        boardEntranceID = nil
        directRevealFeedback = nil
    }
    private var canShowSceneFeedback: Bool {
        active && screen == .game && sheet == nil && !loading && !rewardBusy && !interstitialBusy &&
        !challengePending && hint == nil && notice == nil && errorMessage == nil
    }
    private func publishBoardEntrance() {
        directRevealFeedback = nil
        boardEntranceID = canShowSceneFeedback ? session?.id : nil
    }
    private func publishDirectReveal(cell: Int) {
        guard canShowSceneFeedback, let session, session.found.contains(cell) else { return }
        directRevealFeedback = DirectRevealFeedback(sessionID: session.id, cell: cell)
    }

    var boardInputInProgress: Bool {
        guard let id = session?.id else { return false }
        return boardInputOwners.values.contains(id)
    }
    func setBoardInputActivity(_ token: UUID, active isActive: Bool, sessionID: UUID) {
        if !isActive {
            if boardInputOwners[token] == sessionID { boardInputOwners.removeValue(forKey: token) }
            return
        }
        guard active, screen == .game, session?.id == sessionID else { return }
        boardInputOwners = boardInputOwners.filter { $0.value == sessionID }
        boardInputOwners[token] = sessionID
    }
    private func resumeConfirmedRewardHint() {
        guard let expected = deferredRewardHintSessionID else { return }
        guard session?.id == expected, session?.pendingRewardHint == true else {
            deferredRewardHintSessionID = nil; return
        }
        guard canTouchBoard else { return }
        showHint()
        if hint != nil || session?.pendingRewardHint != true { deferredRewardHintSessionID = nil }
    }
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
    func uiTap(_ id: String = "button") { syncFeedbackState(); feedback.playButton(id: id) }
    func beginSwipeFeedback() { syncFeedbackState(); if canTouchBoard { feedback.beginSwipe() } }
    func endSwipeFeedback(cancelled: Bool) { feedback.endSwipe(cancelled: cancelled) }
    var currentAudioEnvironment: FeedbackEnvironment { feedback.environment }
    func comboFeedbackPresentation(for count: Int) -> ComboFeedbackPresentation? {
        guard count > 0 else { return nil }
        if feedback.hasVerifiedComboConfiguration { return feedback.comboPresentation(count: count) }
        // The empty unverified production manifest supplies no thresholds. Keep
        // this visible Demo fallback separate from any claimed reference mapping.
        guard let thresholds = session?.config.comboThresholds,
              let index = thresholds.indices.last(where: { count >= thresholds[$0] }) else { return nil }
        return ComboFeedbackPresentation(text: ["Nice", "Great", "Excellent"][min(index, 2)], delay: 0)
    }
    private func syncFeedbackState() {
        var page: FeedbackAudioPage
        switch screen { case .home: page = .home; case .game: page = .game; case .checkIn: page = .checkIn }
        var overlay: FeedbackAudioOverlay = .none
        if errorMessage != nil { overlay = .error }
        else if notice != nil { overlay = .notice }
        else if loading { overlay = .loading }
        else if sheet == .reward { overlay = rewardDisplayActive || interstitialDisplayActive ? .none : .loading }
        else if challengePending { overlay = .challenge }
        else if sheet == .settings { page = .settings; overlay = .settings }
        else if sheet == .debug { overlay = .debug }
        else if screen == .game {
            if hint != nil { overlay = .hint }
            else if session?.status == .won { overlay = .won }
            else if session?.status == .lost { overlay = .lost }
            else if tutorial != nil { overlay = .tutorial }
        }
        var blocks = Set<FeedbackAudioBlock>()
        if !active { blocks.insert(.background) }
        if sheet == .reward && (rewardDisplayActive || interstitialDisplayActive) { blocks.insert(.advertisement) }
        if !startupFlowCompleted || (screen == .game && (!canTouchBoard || notice != nil || errorMessage != nil)) { blocks.insert(.inputLocked) }
        if !startupFlowCompleted { page = .startup; overlay = .none }
        feedback.setEnvironment(FeedbackEnvironment(page: page, level: screen == .game ? session?.puzzle.id : nil, overlay: overlay, blocks: blocks))
    }
    func applySettings() {
        let s = progress.settings
        feedback.apply(settings: .init(sound: feedbackEnabled && s.soundEnabled, haptic: feedbackEnabled && s.hapticsEnabled, voice: feedbackEnabled && s.voiceEnabled, music: feedbackEnabled && s.musicEnabled))
    }
    func settingsChanged() { applySettings(); save() }
    func setLanguage(_ language: AppLanguage) {
        guard progress.settings.language != language else { return }
        flushPendingSaves()
        saveRevision += 1
        do {
            try store.transaction(progress: &progress) { $0.settings.language = language }
        } catch {
            errorMessage = "Your language preference could not be saved. Please try again."
        }
    }
    func setActive(_ value: Bool) {
        if !value { boardInputOwners.removeAll(); clearSceneFeedback() }
        active = value; now = Date(); syncFeedbackState()
        if value { analytics.beginSession(source: "resume") } else { analytics.endSession(reason: "background") }
        flushInterstitialEvents()
        if !value { save(force: true) }
        else {
            // Foreground retry must confirm the whole snapshot, including any
            // ordinary gameplay result still waiting on the background writer.
            save(force: true)
            if let offerID = activeOfferID { displayReadyReward(offerID: offerID) }
            displayReadyInterstitial()
            if screen == .game && winTransitionID != nil && !interstitialBusy && !challengePending { completeWinTransition() }
            resumeConfirmedRewardHint()
            restoreSavedHint()
            refreshGameplayConfiguration()
            deliverPendingLevelStart()
        }
    }
    func consentAccepted() {
        analytics.acceptConsent()
        flushInterstitialEvents()
        if !pendingRewardObservations.isEmpty || !progress.pendingBuffEvents.isEmpty || !progress.pendingLevelResultEvents.isEmpty || progress.rewardLedger.values.contains(where: { $0.completionEvent != nil || $0.analyticsOfferPending || !$0.pendingAdEvents.isEmpty }) { save(force: true) }
    }
    /// Prepare local feedback during loading, before Home becomes interactive.
    func prepareStartupFeedback() async { await feedback.prepareShortEffects() }
    /// Called only after the startup view reaches Home, including optional permission completion.
    /// This permits local adapter use; it does not claim a real SDK/CMP has been initialized.
    func startupReady() {
        startupFlowCompleted = true
        syncFeedbackState()
        preloadRewardPlacementsIfNeeded()
        deliverPendingLevelStart()
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
        pendingLevelStartID = s.id
        deliverPendingLevelStart()
    }
    private func schedulePendingLevelStart() {
        guard pendingLevelStartID != nil, !levelStartDeliveryScheduled else { return }
        levelStartDeliveryScheduled = true
        // A single business action can dismiss a sheet and then show an alert
        // or a hint. Observe its settled state, not that intermediate gap.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.levelStartDeliveryScheduled = false
            self.deliverPendingLevelStart()
        }
    }
    private func deliverPendingLevelStart() {
        guard let pending = pendingLevelStartID else { return }
        guard let s = session, s.id == pending else { pendingLevelStartID = nil; return }
        guard canTouchBoard else { return }
        pendingLevelStartID = nil
        track("level_start", key: s.id.uuidString, parameters: ["attempt_no": "\(s.attempt)", "grid_size": "\(s.puzzle.size)x\(s.puzzle.size)", "is_tutorial": "\(tutorial != nil)", "direct_find_visible": "\(directVisible)", "direct_find_inventory": "\(progress.availableDirect)", "hint_inventory": "\(progress.availableHints)", "level_start_free_available": "\(levelStartFreeAvailable)"])
        if tutorial != nil { track("tutorial_start", key: s.id.uuidString, parameters: ["tutorial_id": "level-1-dynamic"]) }
    }
    private func trackLevelEnd(_ result: LevelEndResult) {
        stageLevelEnd(result, in: &progress)
    }
    func finalizeRewardResult(_ result: RewardOutcome, in candidate: inout PlayerProgress, offerID: String? = nil) {
        guard case .directRevealed(let cell) = result, let session = candidate.session else { return }
        let key = offerID.map { $0 + ":direct" } ?? session.id.uuidString + ":reward-direct:\(cell)"
        let offer = offerID.flatMap { candidate.rewardLedger[$0]?.analyticsOffer }
            .flatMap { try? JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: $0) }
        stageBuff("direct_find", key: key, applied: true, before: 0, after: 0,
                  source: .rewardedAd, in: &candidate, relatedTo: offer?.event)
        if candidate.finishWin() { stageLevelEnd(.win, in: &candidate) }
    }
    private func stageLevelEnd(_ result: LevelEndResult, in candidate: inout PlayerProgress) {
        guard let key = candidate.session?.claimResult(result), let s = candidate.session else { return }
        guard let prepared = analytics.prepare("level_end", key: key, level: s.puzzle.id, config: s.config.version,
            parameters: ["result": result.rawValue, "duration_sec": "\(Int(s.elapsedSeconds))", "attempt_no": "\(s.attempt)", "fail_reason": result == .lose ? "life_zero" : result == .quit ? "quit" : "", "life_remaining": "\(s.lives)"]),
              let data = try? JSONEncoder().encode(prepared) else { return }
        // Written atomically with the resulting board state by the caller's save.
        // Disabled analytics never generates a retroactive pre-consent event.
        candidate.pendingLevelResultEvents[prepared.event.eventID] = data
    }
    private func trackTutorialEnd(_ result: String) {
        guard tutorial != nil, let s = session else { return }
        track("tutorial_end", key: s.id.uuidString + ":" + result, parameters: ["tutorial_id": "level-1-dynamic", "result": result, "duration_sec": "\(Int(s.elapsedSeconds))"])
    }
    private func prepareBuff(_ type: String, key: String, applied: Bool, before: Int, after: Int,
                             source: ToolInventorySource?, in candidate: PlayerProgress,
                             relatedTo offer: AnalyticsRecorder.Event? = nil) -> AnalyticsRecorder.PreparedEvent? {
        guard let source, let session = candidate.session else { return nil }
        let parameters = ["buff_type": type, "source": source.rawValue, "applied": "\(applied)",
                          "inventory_before": "\(before)", "inventory_after": "\(after)"]
        if let offer {
            return analytics.prepareRelated("buff_use", key: key, to: offer, parameters: parameters)
        }
        return analytics.prepare("buff_use", key: key, level: session.puzzle.id,
                                 config: session.config.version, parameters: parameters)
    }
    private func stageBuff(_ type: String, key: String, applied: Bool, before: Int, after: Int,
                           source: ToolInventorySource?, in candidate: inout PlayerProgress,
                           relatedTo offer: AnalyticsRecorder.Event? = nil) {
        guard let prepared = prepareBuff(type, key: key, applied: applied, before: before,
                                         after: after, source: source, in: candidate, relatedTo: offer),
              let data = try? JSONEncoder().encode(prepared) else { return }
        candidate.pendingBuffEvents[prepared.event.eventID] = data
    }
    private func prepareRewardCompletion(_ record: RewardRecord) -> Data? {
        prepareRewardResult(record, status: "completed")
    }
    private func prepareRewardResult(_ record: RewardRecord, status: String, errorCode: String = "") -> Data? {
        // No retrospective fabrication for old/pre-consent receipts without context.
        guard let data = record.analyticsOffer,
              let offer = try? JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: data),
              case .text(let placement) = offer.event.parameters["placement_id"],
              case .text(let network) = offer.event.parameters["network"],
              case .text(let unit) = offer.event.parameters["ad_unit_id"] else { return nil }
        guard let event = analytics.prepareRelated("ad_result", key: record.id + ":" + status, to: offer.event,
            parameters: ["offer_id": record.id, "placement_id": placement, "status": status, "reward_granted": "false", "ad_type": "rewarded", "network": network, "ad_unit_id": unit, "error_code": errorCode]) else { return nil }
        return try? JSONEncoder().encode(event)
    }
    func exportDiagnostics() {
        struct Report: Encodable {
            let generatedAt: Date; let build: String; let demoConfig: DemoConfig
            let buildConfiguration = AppBuildConfiguration.current
            let progress: PlayerProgress; let levelPackCount: Int
            let referenceGameplay: ReferenceGameplayConfiguration?; let generationReport: GenerationPipelineReport?
            let currentBoardGenerationReport: GenerationPipelineReport?
            let generationAuditIssues: [String]
            let generationReportScope = "Most recent generation attempt; may differ from the current playable board. The separate currentBoardGenerationReport is matched to the complete saved puzzle. Reports describe generation, not player activation or formal reference acceptance."
            let unattributedToolUsesSinceLaunch: Int
            let interstitialRecordingError: String?
            let rewardRecordingError: String?
            let gameplayConfiguration: GameplayConfigurationDiagnostics
        }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            var issues: [String] = []
            var latestReport = lastGenerationReport
            if latestReport == nil {
                do { latestReport = try generationAudits.latest()?.report }
                catch { issues.append("Latest generation audit could not be verified: \(error.localizedDescription)") }
            }
            var currentReport: GenerationPipelineReport?
            if let puzzle = session?.puzzle, puzzle.id >= 151 {
                do {
                    currentReport = try generationAudits.report(for: puzzle)?.report
                    if currentReport == nil { issues.append("No generation audit is available for this board; older Demo versions did not retain runtime reports. No historical report has been reconstructed or invented.") }
                } catch { issues.append("Current board generation audit could not be verified: \(error.localizedDescription)") }
            }
            let report = Report(generatedAt: Date(), build: "\(version) (\(build))", demoConfig: config, progress: progress, levelPackCount: levels.count, referenceGameplay: referenceConfiguration, generationReport: latestReport, currentBoardGenerationReport: currentReport, generationAuditIssues: issues, unattributedToolUsesSinceLaunch: unattributedToolUseCount, interstitialRecordingError: interstitialRecordingError, rewardRecordingError: rewardRecordingError, gameplayConfiguration: gameplayConfigurationDiagnostics)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Capydoku-diagnostics.json")
            try encoder.encode(report).write(to: url, options: .atomic)
            exportURL = url
        } catch { errorMessage = "The issue report could not be exported. Please try again. \(error.localizedDescription)" }
    }
}
