import SwiftUI
import UIKit
import CapydokuCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var language
    @Environment(\.capyAccessibilityFocus) private var focus
    @State private var showingFeedback = false
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(language.text("Settings")).font(.system(size: 33, weight: .heavy, design: .rounded))
                    .accessibilityAddTraits(.isHeader).capyFocus("settings_title").accessibilityIdentifier("settings_title")
                    #if DEBUG
                    .onLongPressGesture(minimumDuration: 1) { model.sheet = .debug }
                    .accessibilityAction(named: Text(language.text("Developer tools"))) { model.sheet = .debug }
                    #endif
                HStack {
                    Spacer()
                    CapyButton(id: "settings_done") { model.sheet = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 25, weight: .bold)).frame(width: 48, height: 48)
                    }.buttonStyle(CapyPressStyle()).accessibilityLabel(language.text("Close settings")).accessibilityIdentifier("settings_done")
                }
            }.padding(.horizontal, 12).frame(height: 66).background(CapyPalette.orangeLight.opacity(0.55))
            VStack(spacing: 20) {
                HStack(spacing: 7) {
                    setting("Music", symbol: "music.note", binding: $model.progress.settings.musicEnabled, id: "music_toggle")
                    setting("Sound effects", symbol: "speaker.wave.2.fill", binding: $model.progress.settings.soundEnabled, id: "sound_toggle")
                    setting("Voice", symbol: "person.wave.2.fill", binding: $model.progress.settings.voiceEnabled, id: "voice_toggle")
                    setting("Haptics", symbol: "iphone.radiowaves.left.and.right", binding: $model.progress.settings.hapticsEnabled, id: "haptics_toggle")
                }.padding(.top, 6)
                HStack(spacing: 8) {
                    Text(language.text("Language")).font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    languageButton(.simplifiedChinese, title: "简体中文", id: "language_zh_hans")
                    languageButton(.english, title: "English", id: "language_en")
                }
                VStack(spacing: 15) {
                    CapyButton(id: "feedback") {
                        model.exportDiagnostics(); showingFeedback = model.exportURL != nil
                    } label: { Text(language.text("Feedback")).frame(maxWidth: .infinity) }
                        .buttonStyle(CapyButtonStyle(secondary: true)).accessibilityIdentifier("feedback")
                    CapyButton(id: "restart") {
                        model.sheet = nil; model.restart()
                    } label: { Text(language.text("Restart")).frame(maxWidth: .infinity) }
                        .buttonStyle(CapyButtonStyle()).disabled(model.session == nil).accessibilityIdentifier("restart")
                }
            }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 24)
        }
        .background(CapyPalette.paper).clipShape(RoundedRectangle(cornerRadius: 28))
        .frame(maxWidth: 365).padding(.horizontal, 24)
        .accessibilityAddTraits(.isModal)
        .onChange(of: model.progress.settings) { _ in model.settingsChanged() }
        .sheet(isPresented: $showingFeedback, onDismiss: { focus?.wrappedValue = "feedback" }) { if let url = model.exportURL { ShareSheet(items: [url]) } }
    }
    private func setting(_ label: String, symbol: String, binding: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: binding) {
            Image(systemName: symbol).font(.system(size: 27, weight: .semibold)).frame(height: 33)
        }.toggleStyle(IconSwitchStyle(id: id)).accessibilityLabel(language.text(label)).accessibilityIdentifier(id)
    }
    private func languageButton(_ selectedLanguage: AppLanguage, title: String, id: String) -> some View {
        let selected = language == selectedLanguage
        return CapyButton(id: id) { model.setLanguage(selectedLanguage) } label: {
            Text(language.text(title))
                .font(.system(size: 14, weight: selected ? .bold : .medium, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.85)
                .padding(.horizontal, 11).frame(minHeight: 44)
                .foregroundColor(selected ? .white : CapyPalette.ink)
                .background(selected ? CapyPalette.actionOrange : CapyPalette.orangeLight.opacity(0.45))
                .clipShape(Capsule())
        }
        .buttonStyle(CapyPressStyle())
        .accessibilityLabel(language.text(title))
        .accessibilityValue(language.text(selected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(id)
    }
}

struct IconSwitchStyle: ToggleStyle {
    @Environment(\.appLanguage) private var language
    let id: String
    func makeBody(configuration: Configuration) -> some View {
        CapyButton(id: id) { configuration.isOn.toggle() } label: {
            VStack(spacing: 8) {
                configuration.label
                HStack(spacing: 2) {
                    if !configuration.isOn { Circle().fill(.white).frame(width: 17, height: 17) }
                    Text(language.text(configuration.isOn ? "ON" : "OFF")).font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundColor(.white).frame(maxWidth: .infinity)
                    if configuration.isOn { Circle().fill(.white).frame(width: 17, height: 17) }
                }.padding(3).background(configuration.isOn ? CapyPalette.switchOnTrack : CapyPalette.switchOffTrack).clipShape(Capsule())
            }.padding(.horizontal, 5).padding(.vertical, 9).frame(maxWidth: .infinity)
                .background(CapyPalette.paper)
                .overlay(RoundedRectangle(cornerRadius: 17).stroke(CapyPalette.line, lineWidth: 1))
        }.buttonStyle(CapyPressStyle()).accessibilityValue(configuration.isOn ? "1" : "0")
            .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
    }
}

struct CheckInView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    // Only hosted-view verification passes an override; normal use follows
    // the system accessibility preference.
    var reduceMotionOverride: Bool? = nil
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    @Environment(\.scenePhase) private var scenePhase
    @State private var rewardBounce = false
    @State private var showRewardBurst = false
    @State private var burstProgress: CGFloat = 0
    @State private var giftBounce = false
    @State private var showGiftBurst = false
    @State private var giftBurstProgress: CGFloat = 0
    @State private var giftCelebrationToken = UUID()
    @State private var celebratedGiftDay: Int?
    private var cycleDays: Int { max(1, model.config.checkInCycleDays) }
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
    private var cycleStart: Int {
        if shownCycleDay == 0 { return CheckInState.utcDay(for: model.now) }
        return (model.progress.checkIn.lastClaimedDay ?? CheckInState.utcDay(for: model.now)) - shownCycleDay + 1
    }
    private var giftRewardAvailable: Bool {
        model.progress.checkIn.canClaim(on: model.now) && shownCycleDay + 1 == cycleDays
    }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 360 || geometry.size.height < 640
            // Keep 44pt targets; a narrow viewport scrolls the row rather than
            // squeezing seven controls or pushing the gift off the page.
            let sevenDaysFit = geometry.size.width - 36 >= 7 * 44 + 6 * 4
            VStack(spacing: 0) {
                HStack {
                    IconButton(symbol: "chevron.left", label: language.text("Home"), id: "checkin_home", action: model.home)
                    Spacer()
                }.padding(.top, 8)
                Spacer(minLength: compact ? 8 : 15)
                Group {
                    if let art = UIImage(named: "CapyCheckIn") {
                        Image(uiImage: art).resizable().scaledToFit()
                    } else {
                        VStack(spacing: -40) {
                            CapyMascot(mood: .happy, size: 210)
                            Image(systemName: "pawprint.fill").font(.system(size: 63)).foregroundColor(.white)
                                .frame(width: 175, height: 118).background(CapyPalette.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 19))
                        }
                    }
                }.frame(width: geometry.size.width * 0.68, height: geometry.size.height * (compact ? 0.25 : 0.34))
                    .scaleEffect(rewardBounce ? 1.06 : 1)
                    .overlay { if showRewardBurst { CheckInParticleBurst(progress: burstProgress).allowsHitTesting(false) } }
                    .accessibilityHidden(true)
                Text("\(shownStreak)").font(.system(size: compact ? 58 : 78, weight: .heavy, design: .rounded))
                    .foregroundColor(CapyPalette.actionOrange).padding(.top, compact ? 4 : 8).accessibilityIdentifier("checkin_streak").capyFocus("checkin_streak")
                Text(language.text("Day Streak")).font(.system(size: compact ? 22 : 26, weight: .heavy, design: .rounded)).foregroundColor(CapyPalette.actionOrange)
                Spacer().frame(height: compact ? max(16, geometry.size.height * 0.04) : max(32, geometry.size.height * 0.07))
                Group {
                    if cycleDays == 7 && sevenDaysFit {
                        HStack(alignment: .top, spacing: 4) {
                            ForEach(1...cycleDays, id: \.self) { day in dayView(day) }
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(alignment: .top, spacing: compact ? 8 : 10) {
                                ForEach(1...cycleDays, id: \.self) { day in dayView(day).frame(width: compact ? 44 : 48) }
                            }
                        }.frame(height: 82)
                    }
                }
                Spacer(minLength: compact ? 12 : 30)
            }.padding(.horizontal, 18)
        }
        .onAppear { updateGiftCelebration() }
        .onChange(of: giftRewardAvailable) { _ in updateGiftCelebration() }
        .onChange(of: scenePhase) { _ in updateGiftCelebration() }
        .onChange(of: reduceMotion) { _ in updateGiftCelebration() }
        .onDisappear { stopGiftCelebration() }
    }
    private func dayView(_ day: Int) -> some View {
        let claimed = day <= shownCycleDay
        let canClaim = model.progress.checkIn.canClaim(on: model.now) && day == shownCycleDay + 1
        return VStack(spacing: 12) {
            Text(language.text(weekday(day))).font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundColor(claimed || canClaim ? CapyPalette.actionOrange : CapyPalette.checkInSecondaryText)
            CapyButton(id: canClaim ? "claim_reward" : "checkin_day_\(day)") {
                guard model.progress.checkIn.canClaim(on: model.now), day == shownCycleDay + 1 else { return }
                let previousClaim = model.progress.checkIn.lastClaimedDay
                model.claim()
                if !reduceMotion && model.progress.checkIn.lastClaimedDay != previousClaim {
                    burstProgress = 0; showRewardBurst = true
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.4)) { rewardBounce = true }
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.7)) { burstProgress = 1 }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { withAnimation { rewardBounce = false } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { showRewardBurst = false }
                }
            } label: {
                ZStack {
                    Circle().fill(claimed ? CapyPalette.orange : Color(red: 0.82, green: 0.89, blue: 0.92))
                    if day == cycleDays {
                        Image(systemName: "gift.fill").font(.system(size: 28)).foregroundColor(claimed ? .white : CapyPalette.orange)
                            .scaleEffect(giftBounce ? 1.06 : 1)
                            .overlay {
                                if showGiftBurst {
                                    CheckInParticleBurst(progress: giftBurstProgress)
                                        .frame(width: 80, height: 80)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                    } else if claimed {
                        Image(systemName: "checkmark").font(.system(size: 22, weight: .heavy)).foregroundColor(.white)
                    }
                    if canClaim { Circle().stroke(CapyPalette.orange, lineWidth: 2) }
                }.frame(minWidth: 44, maxWidth: 48, minHeight: 44, maxHeight: 48)
            }.buttonStyle(CapyPressStyle(disabledOpacity: 1)).disabled(!canClaim)
                .accessibilityLabel(language.text(canClaim ? "Claim today's reward" : "Day \(day), \(claimed ? "claimed" : "not claimed")"))
                .accessibilityIdentifier(canClaim ? "claim_reward" : "checkin_day_\(day)")
                .capyLayoutProbe(canClaim ? "claim_reward" : "checkin_day_\(day)")
        }.frame(maxWidth: .infinity)
    }
    private func updateGiftCelebration() {
        guard giftRewardAvailable, scenePhase == .active, !reduceMotion else {
            stopGiftCelebration(); return
        }
        let day = CheckInState.utcDay(for: model.now)
        guard celebratedGiftDay != day else { return }
        celebratedGiftDay = day
        let token = UUID()
        giftCelebrationToken = token
        giftBurstProgress = 0
        showGiftBurst = true
        // Original [298] requires a brief gift bounce and particles when the
        // cycle reward becomes claimable. Reuse the provisional Demo timings
        // from daily claim feedback; eligibility and rewards are unchanged.
        withAnimation(.spring(response: 0.25, dampingFraction: 0.4)) { giftBounce = true }
        DispatchQueue.main.async {
            guard giftCelebrationToken == token else { return }
            withAnimation(.easeOut(duration: 0.7)) { giftBurstProgress = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard giftCelebrationToken == token else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.4)) { giftBounce = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            guard giftCelebrationToken == token else { return }
            showGiftBurst = false
        }
    }
    private func stopGiftCelebration() {
        giftCelebrationToken = UUID()
        giftBounce = false
        showGiftBurst = false
        giftBurstProgress = 0
    }
    private func weekday(_ day: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(cycleStart + day - 1) * 86_400)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"][calendar.component(.weekday, from: date) - 1]
    }
}

/// Brief, non-interactive particles; disabled with Reduce Motion and removed after 0.75 s.
struct CheckInParticleBurst: View, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        Canvas { context, size in
            context.opacity = Double(1 - progress)
            let colors = [CapyPalette.orange, Color.yellow, CapyPalette.green, CapyPalette.regionColors[0]]
            for particle in 0..<16 {
                let angle = CGFloat(particle) * .pi * 2 / 16
                let radius = (20 + progress * min(size.width, size.height) * 0.62) * (particle.isMultiple(of: 2) ? 1 : 0.78)
                let point = CGPoint(x: size.width / 2 + cos(angle) * radius,
                                    y: size.height / 2 + sin(angle) * radius + progress * progress * 28)
                context.draw(Text(particle.isMultiple(of: 3) ? "✦" : "●")
                    .font(.system(size: particle.isMultiple(of: 3) ? 17 : 7, weight: .bold))
                    .foregroundColor(colors[particle % colors.count]), at: point)
            }
        }.accessibilityHidden(true)
    }
}

struct RewardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var language
    var body: some View {
        CapyCard(padding: 26) {
            VStack(spacing: 22) {
                HStack {
                    Spacer()
                    CapyButton(id: "reward_close") { model.sheet = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 22, weight: .bold)).frame(width: 44, height: 44)
                    }.buttonStyle(CapyPressStyle()).disabled(model.rewardBusy || model.rewardRetryPending || model.interstitialBusy).accessibilityLabel(language.text("Close reward")).accessibilityIdentifier("reward_close")
                }
                Image(systemName: "play.rectangle.fill").font(.system(size: 64)).foregroundColor(CapyPalette.video)
                Text(language.text(model.interstitialBusy ? "Simulated interstitial" : "Demo Video")).font(.system(size: 27, weight: .heavy, design: .rounded)).multilineTextAlignment(.center).accessibilityIdentifier("reward_title").capyFocus("reward_title")
                Text(language.text(model.interstitialBusy ? "Internal demo · no real ad" : "Simulated reward · no real ad")).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(CapyPalette.muted)
                if model.rewardRetryPending && !model.interstitialBusy {
                    Text(language.text("Your reward is waiting to be saved.")).font(.callout).multilineTextAlignment(.center)
                    CapyButton("Retry save", id: "run_reward", action: model.runReward).buttonStyle(CapyButtonStyle()).accessibilityIdentifier("run_reward")
                } else {
                    ProgressView().tint(CapyPalette.orange).padding(12)
                    Text(language.text("Loading…")).font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
        }.frame(maxWidth: 340).padding(.horizontal, 24).accessibilityAddTraits(.isModal)
    }
}

struct DebugView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @Environment(\.capyButtonActivation) private var activate
    @Environment(\.capyAccessibilityFocus) private var focus
    @State private var showingExport = false
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(language.text("Internal build · local only"))) {
                    Text(language.text("Jumping changes the active puzzle. Unfinished progress is replaced. 151+ creates a validated local board.")).font(.caption)
                    HStack {
                        TextField(language.text("Level number"), text: $model.jumpLevel).keyboardType(.numberPad).accessibilityIdentifier("jump_level")
                        Button(language.text("Go")) {
                            guard let level = Int(model.jumpLevel), level > 0 else { return }
                            activate("jump_go")
                            dismiss(); model.start(level: level)
                        }.frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("jump_go")
                    }
                    CapyButton("Replay tutorial", id: "replay_tutorial", action: model.replayTutorial)
                }
                Section(header: Text(language.text("Reward simulation"))) {
                    Picker(language.text("Outcome"), selection: $model.rewardScenario) {
                        ForEach(RewardScenario.allCases) { Text(language.text($0.rawValue)).tag($0) }
                    }.pickerStyle(.menu).accessibilityIdentifier("reward_scenario")
                    Text(language.text("Selected outcome applies to the next demo video. Real ad integration is supplied separately.")).font(.caption)
                }
                if let s = model.session {
                    Section(header: Text(language.text("Current board snapshot"))) {
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
                Section(header: Text(language.text("Provisional tuning · applies to the next new game"))) {
                    Stepper(language.text("Starting lives: \(model.config.initialLives)"), value: $model.config.initialLives, in: 1...5)
                    Stepper(language.text("Free hints per new level: \(model.config.hintsPerLevel)"), value: $model.config.hintsPerLevel, in: 0...5)
                    Stepper(language.text("Free finds per new level: \(model.config.directPerLevel)"), value: $model.config.directPerLevel, in: 0...5)
                    Text(language.text("100 points per find; +20 for each consecutive find. Check-in: 1 hint daily, 1 extra find on day 7. Changes here reset at app launch.")).font(.caption)
                    field("Generation budget", "\(model.config.generatorBudgetMilliseconds) ms / \(model.config.generatorCandidateLimit) attempts")
                    Text(language.text("Difficulty is a temporary content label, not formal reference-product calibration.")).font(.caption)
                }
                Section(header: Text(language.text("Recovery & diagnostics"))) {
                    CapyButton("Recover save", id: "recover_save") { model.loadProgress(); model.applySettings(); dismiss() }.accessibilityIdentifier("recover_save")
                    CapyButton("Export issue report", id: "export_diagnostics") { model.exportDiagnostics(); showingExport = model.exportURL != nil }.accessibilityIdentifier("export_diagnostics")
                    Text(language.text("The export contains the full local board, seed, settings, inventory and reward ledger. It contains the solution for debugging. No account or device identifier is collected.")).font(.caption)
                }
            }.tint(CapyPalette.orange).navigationTitle(language.text("Developer tools"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { CapyButton("Done", id: "debug_done") { dismiss() }.frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("debug_done") } }
        }.navigationViewStyle(.stack)
            .sheet(isPresented: $showingExport, onDismiss: { focus?.wrappedValue = "export_diagnostics" }) { if let url = model.exportURL { ShareSheet(items: [url]) } }
    }
    private func field(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(language.text(name)).font(.caption).foregroundColor(.secondary); Text(language.text(value)).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
