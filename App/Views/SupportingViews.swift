import SwiftUI
import UIKit
import CapydokuCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Make yourself comfortable")) {
                    Toggle("Music", isOn: $model.progress.settings.musicEnabled).accessibilityIdentifier("music_toggle")
                    Toggle("Sound effects", isOn: $model.progress.settings.soundEnabled).accessibilityIdentifier("sound_toggle")
                    Toggle("Voice encouragement", isOn: $model.progress.settings.voiceEnabled).accessibilityIdentifier("voice_toggle")
                    Toggle("Haptics", isOn: $model.progress.settings.hapticsEnabled).accessibilityIdentifier("haptics_toggle")
                }
                Section(header: Text("How to play")) {
                    Text("One capybara in each row, each column and each colored region. Capybaras cannot touch, even diagonally.").font(.subheadline)
                    Text("Tap to add or remove an X. Double-tap to place a capybara. Swipe horizontally or vertically to add multiple Xs.").font(.subheadline)
                    Text("Red Xs are confirmed mistakes and stay locked. Repeating the same mistake never costs another heart.").font(.caption).foregroundColor(.secondary)
                    Button("Replay the guided introduction") { model.replayTutorial() }.accessibilityIdentifier("replay_tutorial")
                }
                Section(header: Text("Internal demo")) {
                    Text("150 original puzzles plus a local generation experiment. Rewards, scoring and difficulty are provisional.").font(.caption)
                    Text("All progress stays on this device. This build contains no real ads, accounts, purchases or analytics SDKs.").font(.caption)
                    #if DEBUG
                    Button("Developer tools") { model.sheet = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.sheet = .debug } }.accessibilityIdentifier("developer_tools")
                    #endif
                    HStack { Text("Version"); Spacer(); Text("0.1.0 (1)").foregroundColor(.secondary) }
                }
            }
            .tint(CapyPalette.orange)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("settings_done") } }
        }.navigationViewStyle(.stack)
        .onChange(of: model.progress.settings) { _ in model.settingsChanged() }
    }
}

struct CheckInView: View {
    @EnvironmentObject private var model: AppModel
    private var shownCycleDay: Int {
        let checkIn = model.progress.checkIn
        guard checkIn.canClaim(on: model.now), let last = checkIn.lastClaimedDay else { return checkIn.cycleDay }
        let day = CheckInState.utcDay(for: model.now)
        return day > last + 1 || checkIn.cycleDay >= model.config.checkInCycleDays ? 0 : checkIn.cycleDay
    }
    private var shownStreak: Int {
        guard let last = model.progress.checkIn.lastClaimedDay else { return 0 }
        return CheckInState.utcDay(for: model.now) > last + 1 ? 0 : model.progress.checkIn.streak
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    IconButton(symbol: "chevron.left", label: "Home", id: "checkin_home", action: model.home)
                    Spacer(); Text("Daily check-in").font(.system(size: 22, weight: .bold, design: .rounded)); Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                CapyMascot(mood: .happy, size: 128)
                VStack(spacing: 8) {
                    Text("Good to see you again.").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("A little help for your next quiet moment.").font(.system(size: 14, design: .rounded)).foregroundColor(CapyPalette.muted)
                }
                HStack {
                    Label("\(shownStreak) day streak", systemImage: "flame.fill")
                    Spacer()
                    Text("\(model.progress.bonusHints) hints · \(model.progress.bonusDirect) finds").accessibilityIdentifier("bonus_inventory")
                }.font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(CapyPalette.green)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                    ForEach(1...7, id: \.self) { day in
                        let claimed = day <= shownCycleDay
                        VStack(spacing: 12) {
                            Text("DAY \(day)").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.6)
                            Image(systemName: claimed ? "checkmark.circle.fill" : day == 7 ? "gift.fill" : "lightbulb.fill").font(.system(size: 24)).foregroundColor(claimed ? CapyPalette.green : CapyPalette.orange)
                            Text(day == 7 ? "hint + find" : "+1 hint").font(.system(size: 11, weight: .semibold, design: .rounded))
                        }.frame(maxWidth: .infinity).padding(.vertical, 18).background(claimed ? CapyPalette.regionColors[1].opacity(0.55) : CapyPalette.paper).clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                }
                CapyCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("A full week, an extra find", systemImage: "sparkles").font(.system(size: 16, weight: .bold, design: .rounded))
                        Text("Claim a hint every day. On day 7, get a Find too. Missing a day restarts the streak.").font(.system(size: 13, design: .rounded)).foregroundColor(CapyPalette.muted)
                    }
                }
                Button(action: model.claim) { Text(model.progress.checkIn.canClaim(on: model.now) ? "Claim today's treat" : "Claimed for today").frame(maxWidth: .infinity) }
                    .buttonStyle(CapyButtonStyle()).disabled(!model.progress.checkIn.canClaim(on: model.now)).accessibilityIdentifier("claim_reward")
                Text("DEMO REWARDS · Refreshes at 00:00 UTC\nDevice clock is used; no server time is connected.")
                    .font(.system(size: 10, design: .rounded)).foregroundColor(CapyPalette.muted).multilineTextAlignment(.center)
            }.padding(.horizontal, 24).padding(.vertical, 10)
        }
    }
}

struct RewardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    CapyMascot(mood: .neutral, size: 140)
                    Text(model.rewardKind == .revive ? "A fresh little chance" : "A little helping paw").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("SIMULATED REWARD · NO REAL AD").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1).foregroundColor(CapyPalette.orange)
                    Text(model.rewardKind == .revive ? "Restore your lives and keep this board." : model.rewardKind == .hint ? "Preview one hint. Apply only when you're ready." : "Find one of the remaining capybaras.").font(.system(size: 16, design: .rounded)).multilineTextAlignment(.center)
                    CapyCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Simulation outcome").font(.headline)
                            Picker("Outcome", selection: $model.rewardScenario) {
                                ForEach(RewardScenario.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.menu).disabled(model.rewardBusy || model.rewardRetryPending).accessibilityIdentifier("reward_scenario")
                            Text("Success grants once. Cancel, failure and timeout grant nothing. Duplicate tests idempotency; interruption saves a receipt for recovery. No callback times out after 5 seconds.").font(.caption).foregroundColor(CapyPalette.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.rewardRetryPending {
                        Text("Your reward is waiting to be saved. Free up storage if needed, then retry. You do not need to run another simulation.")
                            .font(.callout).foregroundColor(CapyPalette.ink)
                    }
                    Button(action: model.runReward) {
                        HStack { if model.rewardBusy { ProgressView().tint(.white) }; Text(model.rewardBusy ? "Simulating…" : model.rewardRetryPending ? "Retry save" : "Run simulation") }.frame(maxWidth: .infinity)
                    }.buttonStyle(CapyButtonStyle()).disabled(model.rewardBusy).accessibilityIdentifier("run_reward")
                }.padding(26)
            }.background(CapyPalette.cream.ignoresSafeArea())
                .navigationTitle("Demo reward").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(model.rewardBusy || model.rewardRetryPending).accessibilityIdentifier("reward_close") } }
        }.navigationViewStyle(.stack).interactiveDismissDisabled(model.rewardBusy || model.rewardRetryPending)
    }
}

struct DebugView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingExport = false
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Internal build · local only")) {
                    Text("Jumping changes the active puzzle. Unfinished progress is replaced. 151+ creates a validated local board.").font(.caption)
                    HStack {
                        TextField("Level number", text: $model.jumpLevel).keyboardType(.numberPad).accessibilityIdentifier("jump_level")
                        Button("Go") {
                            guard let level = Int(model.jumpLevel), level > 0 else { return }
                            dismiss(); model.start(level: level)
                        }.accessibilityIdentifier("jump_go")
                    }
                    Button("Replay tutorial", action: model.replayTutorial)
                }
                if let s = model.session {
                    Section(header: Text("Current board snapshot")) {
                        field("Level / size", "\(s.puzzle.id) / \(s.puzzle.size)×\(s.puzzle.size)")
                        field("Seed", String(s.puzzle.seed))
                        field("Generator", s.puzzle.generatorVersion)
                        field("Fingerprint", s.puzzle.fingerprint)
                        field("Config", s.config.version)
                        field("Attempt", String(s.attempt))
                        field("Elapsed", "\(Int(s.elapsedSeconds)) seconds")
                        field("Rewards logged", String(model.progress.rewardLedger.count))
                    }
                }
                Section(header: Text("Provisional tuning · applies to the next new game")) {
                    Stepper("Starting lives: \(model.config.initialLives)", value: $model.config.initialLives, in: 1...5)
                    Stepper("Free hints per new level: \(model.config.hintsPerLevel)", value: $model.config.hintsPerLevel, in: 0...5)
                    Stepper("Free finds per new level: \(model.config.directPerLevel)", value: $model.config.directPerLevel, in: 0...5)
                    Text("100 points per find; +20 for each consecutive find. Check-in: 1 hint daily, 1 extra find on day 7. Changes here reset at app launch.").font(.caption)
                    field("Generation budget", "\(model.config.generatorBudgetMilliseconds) ms / \(model.config.generatorCandidateLimit) attempts")
                    Text("Difficulty is a temporary content label, not formal reference-product calibration.").font(.caption)
                }
                Section(header: Text("Recovery & diagnostics")) {
                    Button("Recover save") { model.loadProgress(); model.applySettings(); dismiss() }.accessibilityIdentifier("recover_save")
                    Button("Export issue report") { model.exportDiagnostics(); showingExport = model.exportURL != nil }.accessibilityIdentifier("export_diagnostics")
                    Text("The export contains the full local board, seed, settings, inventory and reward ledger. It contains the solution for debugging. No account or device identifier is collected.").font(.caption)
                }
            }.tint(CapyPalette.orange).navigationTitle("Developer tools")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("debug_done") } }
        }.navigationViewStyle(.stack)
            .sheet(isPresented: $showingExport) { if let url = model.exportURL { ShareSheet(items: [url]) } }
    }
    private func field(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(name).font(.caption).foregroundColor(.secondary); Text(value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
