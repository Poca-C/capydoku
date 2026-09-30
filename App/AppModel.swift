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
    @Published private(set) var rewardRetryPending = false
    @Published var config = DemoConfig.default
    @Published var jumpLevel = "1"
    @Published var exportURL: URL?
    @Published var now = Date()
    let saveDirectory: URL
    private let store: SaveStore
    private var levels: [Int: Puzzle] = [:]
    private var active = true
    private var timer: Timer?
    private var loadingID = UUID()
    private var generationCandidateLimitOverride: Int?
    private var activeOfferID: String?
    private var rewardDeadline: DispatchWorkItem?
    private var pendingRewardSignal: RewardSignal?
    private let rewardProvider: RewardProvider?
    private let rewardTimeout: TimeInterval
    private let feedbackEnabled: Bool
    private var lastRestartTime: TimeInterval = 0
    private var lastDirectTime: TimeInterval = 0
    private let feedback = FeedbackPlayer()

    init(saveDirectory: URL? = nil, rewardProvider: RewardProvider? = nil,
         rewardTimeout: TimeInterval = 5, runsTimer: Bool = true, feedbackEnabled: Bool = true) {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        #else
        let args: [String] = []
        #endif
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let testHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.saveDirectory = saveDirectory ?? root.appendingPathComponent(args.contains("-ui-testing") ? "CapydokuUITesting" : testHost ? "CapydokuAppTestingHost" : "Capydoku", isDirectory: true)
        self.rewardProvider = rewardProvider
        self.rewardTimeout = rewardTimeout.isFinite ? max(0.01, rewardTimeout) : 5
        self.feedbackEnabled = feedbackEnabled && !testHost
        if args.contains("-reset-demo") { try? FileManager.default.removeItem(at: self.saveDirectory) }
        store = SaveStore(directory: self.saveDirectory)
        loadProgress()
        if let url = Bundle.main.url(forResource: "levels", withExtension: "json") {
            do {
                let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
                levels = Dictionary(uniqueKeysWithValues: puzzles.map { ($0.id, $0) })
            } catch { errorMessage = "The packaged levels could not be loaded. \(error.localizedDescription)" }
        } else { errorMessage = "The level pack is missing from this build." }
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

    deinit { timer?.invalidate(); rewardDeadline?.cancel() }

    var session: GameSession? { progress.session }
    var tutorial: TutorialStep? {
        guard let s = session, s.puzzle.id == 1, !progress.tutorialCompleted, s.status == .playing else { return nil }
        let steps = PuzzleHints.tutorial(puzzle: s.puzzle)
        return steps.indices.contains(progress.tutorialStep) ? steps[progress.tutorialStep] : nil
    }
    var tutorialCount: Int { session.map { PuzzleHints.tutorial(puzzle: $0.puzzle).count } ?? 0 }

    func loadProgress() {
        rewardDeadline?.cancel(); rewardDeadline = nil
        let loaded = store.load()
        hint = nil; activeOfferID = nil; rewardBusy = false
        rewardRetryPending = false; pendingRewardSignal = nil
        if sheet == .reward { sheet = nil }
        notice = nil; errorMessage = nil
        progress = loaded.progress
        if progress.session == nil { screen = .home }
        if let message = loaded.warning { notice = message }
    }

    func save() {
        progress.captureSessionBalance()
        do { try store.save(progress) }
        catch { errorMessage = "Progress could not be saved: \(error.localizedDescription)" }
    }

    func startOrContinue() {
        if session != nil { screen = .game }
        else { start(level: progress.currentLevel) }
    }

    func start(level: Int) {
        guard !loading else { return }
        hint = nil
        if let puzzle = levels[level] {
            progress.begin(puzzle: puzzle, config: config)
            screen = .game; save(); return
        }
        guard level >= 151 && level <= 100_000 else {
            errorMessage = "This level is not included in the demo pack."; return
        }
        loading = true
        let request = UUID(); loadingID = request
        let configuration = config
        let candidateLimit = generationCandidateLimitOverride ?? configuration.generatorCandidateLimit
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PuzzleGenerator.generate(level: level, maxAttempts: candidateLimit, timeBudgetMilliseconds: configuration.generatorBudgetMilliseconds) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadingID == request else { return }
                self.loading = false
                switch result {
                case .success(let puzzle):
                    self.progress.begin(puzzle: puzzle, config: configuration)
                    self.screen = .game; self.save()
                case .failure(let error):
                    self.errorMessage = "Generation stopped safely. Your current board is intact. Please retry. \(error.localizedDescription)"
                }
            }
        }
    }

    func home() { hint = nil; screen = .home; save() }
    func next() { guard let s = session, s.status == .won else { return }; start(level: s.puzzle.id + 1) }
    func restart() {
        let time = ProcessInfo.processInfo.systemUptime
        guard !loading, !rewardBusy, time - lastRestartTime > 0.4 else { return }
        lastRestartTime = time
        hint = nil; progress.restart(); save()
    }

    private func tutorialAllows(_ action: String, cells: [Int]) -> Bool {
        guard let t = tutorial else { return true }
        return t.action == action && !cells.isEmpty && Set(cells).isSubset(of: Set(t.targetCells))
    }
    func advanceTutorial() {
        progress.tutorialStep += 1
        if progress.tutorialStep >= tutorialCount { progress.tutorialCompleted = true }
        save()
    }
    func skipTutorial() { progress.tutorialCompleted = true; save() }
    func replayTutorial() {
        progress.tutorialCompleted = false; progress.tutorialStep = 0; sheet = nil
        start(level: 1)
    }
    func toggle(_ cell: Int) {
        guard canTouchBoard, tutorialAllows("tap", cells: [cell]) else { return }
        if progress.session?.toggleMark(at: cell) == true {
            feedback.play(.mark)
            if tutorial != nil { advanceTutorial() }
            save()
        }
    }
    func mark(_ cells: [Int]) {
        guard canTouchBoard, tutorialAllows("swipe", cells: cells) else { return }
        _ = progress.session?.markMany(cells)
        feedback.play(.mark)
        if let t = tutorial, Set(t.targetCells).isSubset(of: session?.marks ?? []) { advanceTutorial() }
        save()
    }
    func submit(_ cell: Int) {
        guard canTouchBoard, tutorialAllows("doubleTap", cells: [cell]) else { return }
        let result = progress.session?.submit(cell: cell)
        switch result {
        case .correct:
            feedback.play(.correct)
            if tutorial != nil { advanceTutorial() }
            afterAction()
        case .incorrect: feedback.play(.wrong); save()
        default: break
        }
    }
    private func afterAction() {
        if progress.finishWin() { feedback.play(.win) }
        else if let combo = session?.combo, combo > 1 { feedback.play(.combo(combo)) }
        save()
    }
    func direct() {
        let time = ProcessInfo.processInfo.systemUptime
        guard canTouchBoard, tutorial == nil, time - lastDirectTime > 0.35 else { return }
        lastDirectTime = time
        if progress.availableDirect == 0 { offer(.direct); return }
        if progress.directFind() != nil { feedback.play(.correct); afterAction() }
    }
    func showHint() {
        guard canTouchBoard, tutorial == nil, let s = session, s.status == .playing else { return }
        guard let preview = PuzzleHints.next(puzzle: s.puzzle, found: s.found, marks: s.marks) else {
            notice = "Every useful exclusion is already marked. Try locating the remaining capybaras."; return
        }
        if progress.availableHints == 0 { offer(.hint); return }
        if progress.consumeHint() { hint = preview; save() }
    }
    func applyHint() {
        guard active, screen == .game, sheet == nil, !loading, !rewardBusy,
              session?.status == .playing, let hint else { return }
        _ = progress.session?.markMany(hint.cells)
        self.hint = nil; feedback.play(.mark); save()
    }
    func offer(_ kind: RewardKind) {
        guard !loading, !rewardBusy, sheet == nil, hint == nil, progress.canReceiveReward(kind) else { return }
        rewardKind = kind; sheet = .reward
    }
    func runReward() {
        guard active, sheet == .reward, !loading, !rewardBusy else { return }
        if let offerID = activeOfferID, let signal = pendingRewardSignal {
            errorMessage = nil
            rewardBusy = true
            receive(signal, offerID: offerID)
            return
        }
        let offerID = UUID().uuidString
        do {
            guard try store.prepareReward(offerID: offerID, kind: rewardKind, progress: &progress) else {
                notice = "This reward is not available right now."; sheet = nil; return
            }
            activeOfferID = offerID
            rewardBusy = true
            let deadline = DispatchWorkItem { [weak self] in self?.receive(.timedOut, offerID: offerID) }
            rewardDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + rewardTimeout, execute: deadline)
            (rewardProvider ?? MockRewardProvider(scenario: rewardScenario)).present(offerID: offerID) { [weak self] signal in
                // Ad adapters may invoke callbacks on any queue, or after cancellation.
                DispatchQueue.main.async { self?.receive(signal, offerID: offerID) }
            }
        } catch { errorMessage = "Reward could not start: \(error.localizedDescription)" }
    }
    private func receive(_ signal: RewardSignal, offerID: String) {
        // A late duplicate must not dismiss a newer sheet or unlock a newer transaction.
        guard let record = progress.rewardLedger[offerID], record.state == .offered || record.state == .rewarded else { return }
        guard activeOfferID == offerID else { return }
        guard rewardBusy else { return } // A failed write retains the first result for explicit retry.
        rewardDeadline?.cancel(); rewardDeadline = nil
        rewardBusy = false
        pendingRewardSignal = signal
        do {
            switch signal {
            case .earned:
                let result = try store.grantReward(offerID: offerID, progress: &progress)
                sheet = nil
                switch result {
                case .hintReady: showHint()
                case .directRevealed: feedback.play(.correct); afterAction()
                case .revived: notice = "Your capybaras and marks are safe. Keep going!"
                case .duplicate: break
                case .compensated: notice = "Reward saved to your inventory."
                case .ignored: break
                }
            case .cancelled, .failed, .timedOut:
                try store.cancelReward(offerID: offerID, progress: &progress)
                sheet = nil
                switch signal {
                case .cancelled: notice = "Simulation cancelled. No reward was issued."
                case .timedOut: notice = "The reward simulation timed out. No reward was issued. You can try again."
                default: notice = "Simulated ad failure. No reward was issued."
                }
            case .interrupted:
                try store.markRewardReceived(offerID: offerID, progress: &progress)
                sheet = nil
                notice = "Reward receipt saved. Use Recover save in Developer tools, or relaunch, to test interruption recovery."
            }
            activeOfferID = nil; pendingRewardSignal = nil; rewardRetryPending = false
        } catch {
            rewardRetryPending = true
            errorMessage = "The reward could not be saved. Free up storage if needed, then tap Retry save. Your receipt is kept for this retry. \(error.localizedDescription)"
        }
    }
    private var canTouchBoard: Bool { active && screen == .game && !loading && !rewardBusy && sheet == nil && hint == nil && session?.status == .playing }
    func claim() {
        now = Date()
        let outcome: CheckInOutcome
        do {
            outcome = try store.transaction(progress: &progress) { $0.claimCheckIn(on: now, config: config) }
        } catch {
            errorMessage = "Your reward was not saved. Please retry. \(error.localizedDescription)"; return
        }
        switch outcome {
        case .claimed(_, _, let hints, let direct):
            notice = "+\(hints) Hint" + (direct > 0 ? " and +\(direct) Find saved!" : " saved to your inventory!")
            feedback.play(.correct)
        case .alreadyClaimed: notice = "You've already checked in today."
        case .clockRollback: notice = "Check-in is paused until the saved UTC date has passed."
        }
    }
    func applySettings() {
        let s = progress.settings
        feedback.apply(settings: .init(sound: feedbackEnabled && s.soundEnabled, haptic: feedbackEnabled && s.hapticsEnabled, voice: feedbackEnabled && s.voiceEnabled, music: feedbackEnabled && s.musicEnabled))
    }
    func settingsChanged() { applySettings(); save() }
    func setActive(_ value: Bool) {
        active = value; now = Date(); feedback.setPaused(!value || sheet == .reward)
        if !value { save() }
    }
    func exportDiagnostics() {
        struct Report: Encodable {
            let generatedAt: Date; let build: String; let demoConfig: DemoConfig
            let progress: PlayerProgress; let levelPackCount: Int
        }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            let report = Report(generatedAt: Date(), build: "\(version) (\(build))", demoConfig: config, progress: progress, levelPackCount: levels.count)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Capydoku-diagnostics.json")
            try encoder.encode(report).write(to: url, options: .atomic)
            exportURL = url
        } catch { errorMessage = error.localizedDescription }
    }
}
