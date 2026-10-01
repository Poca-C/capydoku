import SwiftUI
import CapydokuCore

// Optional, read-only measurements of real laid-out controls for hosted UI
// verification. Normal application views never install an observer.
private struct CapyLayoutObserverKey: EnvironmentKey {
    static let defaultValue: ((String, CGRect) -> Void)? = nil
}

extension EnvironmentValues {
    var capyLayoutObserver: ((String, CGRect) -> Void)? {
        get { self[CapyLayoutObserverKey.self] }
        set { self[CapyLayoutObserverKey.self] = newValue }
    }
}

private struct CapyLayoutProbe: ViewModifier {
    @Environment(\.capyLayoutObserver) private var observer
    let identifier: String
    @ViewBuilder func body(content: Content) -> some View {
        if let observer {
            content.background(GeometryReader { geometry in
                Color.clear.onAppear { observer(identifier, geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { observer(identifier, $0) }
            })
        } else { content }
    }
}

extension View {
    func capyLayoutProbe(_ identifier: String) -> some View { modifier(CapyLayoutProbe(identifier: identifier)) }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    // Root owns the preference so independently hosted screens also update.
    private var language: AppLanguage { model.progress.settings.language }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    // Hosted-view verification can select this branch without changing the
    // device's accessibility setting. Production callers leave it nil.
    var reduceMotionOverride: Bool? = nil
    // Read-only hosted verification of automatic requests; normal views omit it.
    var focusRequestObserver: ((String) -> Void)? = nil
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var focusedControl: String?
    @State private var lastActivatedControl: String?
    @State private var previousModal: String?
    @State private var modalOrigins: [String: String] = [:]
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @StateObject private var resultEntrance = ResultEntrancePresentation()
    // A value snapshot keeps only the departing decoration coherent while the
    // model immediately enters the next board/home. It never drives actions.
    @State private var lastResultSession: GameSession?
    private var hasCard: Bool { model.sheet == .settings || model.sheet == .reward }
    private var hasResult: Bool { model.screen == .game && model.session?.status != .playing && model.session != nil }
    private var resultTransitionEnabled: Bool {
        !reduceMotion && !lowPower && scenePhase == .active &&
        model.sheet == nil && !model.loading && !model.rewardBusy &&
        !model.interstitialBusy && !model.challengePending && model.notice == nil && model.errorMessage == nil
    }
    private var animatesResult: Bool { resultTransitionEnabled && model.screen == .game }
    private var showsResultPanel: Bool { hasResult && model.sheet != .reward }
    private var resultSessionForDisplay: GameSession? { hasResult ? model.session : lastResultSession }
    private var resultDecorationReady: Bool {
        guard hasResult, let session = model.session else { return false }
        return resultEntrance.shows(sessionID: session.id, status: session.status, animate: animatesResult)
    }
    private var modal: String? {
        if model.errorMessage != nil || model.notice != nil { return "alert" }
        if model.loading { return "loading" }
        if model.sheet == .reward { return "reward" }
        if model.challengePending { return "challenge" }
        if model.sheet == .settings { return "settings" }
        if model.sheet == .debug { return "debug" }
        if model.screen == .game, model.hint != nil { return "hint" }
        if hasResult, let session = model.session {
            return session.status == .won ? "win" : "loss"
        }
        return nil
    }
    var body: some View {
        ZStack {
            CapyPalette.cream.ignoresSafeArea()
            // Scrims belong to the root window; a hosted content view cannot
            // extend its drawing into the parent's status/home-indicator areas.
            if model.screen == .game && model.hint != nil && !hasResult {
                Color.black.opacity(0.72).ignoresSafeArea().accessibilityHidden(true)
            }
            CapyAccessibilityHost(hidden: hasCard || model.loading || model.challengePending || hasResult || model.sheet == .debug) {
                Group {
                switch model.screen {
                case .home: HomeView()
                case .game: GameView(resultDecorationReady: resultDecorationReady)
                case .checkIn: CheckInView(reduceMotionOverride: reduceMotionOverride)
                }
                }.environmentObject(model).foregroundColor(CapyPalette.ink)
                    .environment(\.scenePhase, scenePhase)
                    .environment(\.appLanguage, language)
                    .environment(\.capyMotionOverride, reduceMotion)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.capyAccessibilityFocus, $focusedControl)
                    .environment(\.capyButtonActivation, activate)
            }
            Group {
                if showsResultPanel {
                    Color.black.opacity(resultDecorationReady ? 0.78 : 0).ignoresSafeArea()
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .animation(resultTransitionEnabled ? .easeOut(duration: 0.18) : nil, value: resultDecorationReady)
            .animation(resultTransitionEnabled ? .easeOut(duration: 0.18) : nil, value: showsResultPanel)
            if let resultSession = resultSessionForDisplay {
                CapyAccessibilityHost(hidden: !showsResultPanel || hasCard || model.loading || model.challengePending) {
                    ResultPanel(won: resultSession.status == .won, isPresented: showsResultPanel,
                                displaySession: resultSession, showsDecoration: showsResultPanel && resultDecorationReady,
                                animationID: resultEntrance.animationID, presentationEnabled: animatesResult,
                                transitionEnabled: resultTransitionEnabled,
                                stage: animatesResult ? resultEntrance.stage : .settled)
                        .environmentObject(model).foregroundColor(CapyPalette.ink)
                        .environment(\.scenePhase, scenePhase)
                        .environment(\.appLanguage, language)
                        .environment(\.capyMotionOverride, reduceMotion)
                        .environment(\.dynamicTypeSize, dynamicTypeSize)
                        .environment(\.capyAccessibilityFocus, $focusedControl)
                        .environment(\.capyButtonActivation, activate)
                }
                // Controls take over in place as soon as the result commits.
                // Only the decorative content scales in (Original [253–254]);
                // transforming this whole host also moves/fades active buttons.
                .transition(.identity)
                .allowsHitTesting(showsResultPanel)
            }
            if hasCard {
                Color.black.opacity(0.68).ignoresSafeArea().contentShape(Rectangle())
                Group {
                    if model.sheet == .settings { SettingsView() }
                    else { RewardView() }
                }
                .transition(.scale(scale: 0.88).combined(with: .opacity))
                .zIndex(2)
            }
            if model.challengePending && !model.interstitialBusy {
                Color.black.opacity(0.70).ignoresSafeArea().contentShape(Rectangle())
                ChallengePanel().transition(.scale(scale: 0.88).combined(with: .opacity)).zIndex(3)
            }
            if model.loading {
                Color.black.opacity(0.45).ignoresSafeArea()
                CapyCard {
                    VStack(spacing: 16) {
                        CapyMascot(size: 88)
                        ProgressView().tint(CapyPalette.orange)
                        Text(language.text("Loading…")).font(.system(size: 22, weight: .bold, design: .rounded)).capyFocus("loading_title")
                    }.frame(maxWidth: .infinity).padding(16)
                }.frame(maxWidth: 310).padding(26).accessibilityAddTraits(.isModal)
            }
        }
        .environment(\.capyAccessibilityFocus, $focusedControl)
        .environment(\.capyButtonActivation, activate)
        .onAppear { updateResultEntrance(); moveFocus(to: modal) }
        .onChange(of: model.session?.id) { _ in updateResultEntrance() }
        .onChange(of: model.session?.status) { _ in updateResultEntrance() }
        .onChange(of: model.screen) { _ in updateResultEntrance() }
        .onChange(of: animatesResult) { _ in updateResultEntrance() }
        .onChange(of: modal) { moveFocus(to: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: scenePhase) { phase in if phase == .active { requestFocus(modalHeading ?? focusedControl ?? defaultFocus) } }
        .foregroundColor(CapyPalette.ink)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hasCard)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.challengePending)
        .sheet(isPresented: Binding(get: { model.sheet == .debug }, set: { if !$0 && model.sheet == .debug { model.sheet = nil } })) {
            DebugView().environment(\.appLanguage, language).environment(\.capyAccessibilityFocus, $focusedControl).environment(\.capyButtonActivation, activate)
        }
        .alert("Capydoku", isPresented: Binding(get: { model.errorMessage != nil || model.notice != nil }, set: { if !$0 { model.errorMessage = nil; model.notice = nil } })) {
            Button(language.text("OK")) { model.uiTap("alert_ok"); model.errorMessage = nil; model.notice = nil }
        } message: { Text(language.text(model.errorMessage ?? model.notice ?? "")) }
        .environment(\.appLanguage, language)
    }
    private var defaultFocus: String { model.screen == .game ? "level_title" : model.screen == .checkIn ? "checkin_streak" : "play" }
    private func updateResultEntrance() {
        if hasResult { lastResultSession = model.session }
        resultEntrance.update(sessionID: model.session?.id, status: model.session?.status, animate: animatesResult)
    }
    private func activate(_ id: String?) {
        if let id { lastActivatedControl = id }
        model.uiTap(id ?? "button")
    }
    private var modalHeading: String? {
        guard let modal else { return nil }
        // Result actions are present immediately. Visual stages must not pull
        // VoiceOver away after the player starts exploring those controls.
        if modal == "win" { return "next_level" }
        if modal == "loss" { return model.reviveAvailable ? "revive" : "result_restart" }
        return ["settings": "settings_title", "reward": "reward_title", "challenge": "challenge_title",
                "loading": "loading_title", "hint": "hint_explanation", "win": "win_result", "loss": "loss_result"][modal]
    }
    private func requestFocus(_ id: String) {
        focusRequestObserver?(id)
        focusedControl = nil
        DispatchQueue.main.async { focusedControl = id }
    }
    private func moveFocus(to current: String?) {
        let old = previousModal
        previousModal = current
        if let current {
            if current != old { modalOrigins[current] = lastActivatedControl ?? defaultFocus }
            if let heading = modalHeading { requestFocus(heading) }
        } else if let old {
            let origin = modalOrigins.removeValue(forKey: old)
            let target: String
            switch old {
            case "hint": target = "hint"
            case "win", "loss", "challenge", "loading": target = defaultFocus
            case "settings", "debug": target = model.screen == .checkIn ? defaultFocus : "settings"
            default: target = origin == "revive" || origin == "next_level" ? defaultFocus : origin ?? defaultFocus
            }
            requestFocus(target)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.capyMotionOverride) private var motionOverride
    @Environment(\.scenePhase) private var scenePhase
    // Hosted verification can exercise the real static branch without changing
    // the device's power setting. Normal callers leave this nil.
    var lowPowerOverride: Bool? = nil
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var appeared = false
    private var shouldAnimate: Bool {
        appeared && !(motionOverride ?? systemReduceMotion) && !(lowPowerOverride ?? lowPower) && scenePhase == .active &&
        model.screen == .home && model.sheet == nil && !model.loading && !model.rewardBusy && !model.interstitialBusy &&
        !model.challengePending && model.errorMessage == nil && model.notice == nil
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PawBackground()
                VStack(spacing: 0) {
                    HStack {
                        IconButton(symbol: "calendar", label: "Daily check-in", id: "check_in") { model.screen = .checkIn }
                        Spacer()
                        IconButton(symbol: "gearshape.fill", label: "Settings", id: "settings") { model.sheet = .settings }
                    }
                    Spacer(minLength: 30)
                    VStack(spacing: -4) {
                        HomeFloatingMascot(animates: shouldAnimate)
                            // SwiftUI's existing repeatForever animation survives
                            // a no-animation state reset. Retire only this leaf
                            // when its policy changes, removing that render loop.
                            .id(shouldAnimate).transition(.identity)
                            .capyLayoutProbe("home_mascot")
                        (Text("Capy").foregroundColor(CapyPalette.orange) + Text("doku").foregroundColor(CapyPalette.ink))
                            .font(.system(size: min(geometry.size.width * 0.132, 57), weight: .heavy, design: .rounded))
                            .tracking(-2).accessibilityLabel(language.text("Capydoku"))
                    }
                    Spacer(minLength: 48)
                    VStack(spacing: 24) {
                        Button {} label: {
                            HStack(spacing: 12) {
                                Image(systemName: "lock.fill").font(.system(size: 24, weight: .bold))
                                Text(language.text("Daily Challenge")).font(.system(size: 22, weight: .heavy, design: .rounded))
                            }.frame(maxWidth: .infinity).frame(height: 60)
                                .foregroundColor(.white).background(CapyPalette.disabled).clipShape(Capsule())
                        }.disabled(true).accessibilityIdentifier("daily_challenge").accessibilityHint(language.text("Not available in this build"))
                        CapyButton(id: "play", action: model.startOrContinue) {
                            Text(language.text("Level \(model.session?.puzzle.id ?? model.progress.currentLevel)"))
                                .font(.system(size: 31, weight: .heavy, design: .rounded))
                                .frame(maxWidth: .infinity).frame(height: 24)
                        }.buttonStyle(CapyButtonStyle()).accessibilityIdentifier("play")
                    }.padding(.horizontal, 25)
                    Spacer().frame(height: max(50, geometry.size.height * 0.13))
                }.padding(.horizontal, 20).padding(.top, 8)
            }
        }
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

/// One replaceable decorative leaf owns one loop; the surrounding Home layout
/// and its buttons keep their identities when motion is stopped or resumed.
private struct HomeFloatingMascot: View {
    let animates: Bool
    @State private var breathing = false
    var body: some View {
        CapyMascot(mood: .happy, size: 98)
            .offset(y: breathing ? -4 : 2)
            .allowsHitTesting(false)
            .onAppear {
                guard animates else { return }
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { breathing = true }
            }
    }
}

struct IconButton: View {
    @Environment(\.appLanguage) private var language
    let symbol: String; let label: String; let id: String
    var action: () -> Void
    var body: some View {
        CapyButton(id: id, action: action) {
            Image(systemName: symbol).font(.system(size: 22, weight: .bold))
                .frame(width: 44, height: 44).background(CapyPalette.paper).clipShape(Circle())
                .shadow(color: CapyPalette.orange.opacity(0.15), radius: 1, y: 2)
        }.buttonStyle(CapyPressStyle()).accessibilityLabel(language.text(label)).accessibilityIdentifier(id)
    }
}

struct GameView: View {
    let resultDecorationReady: Bool
    init(resultDecorationReady: Bool = false) { self.resultDecorationReady = resultDecorationReady }
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var language
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.capyMotionOverride) private var motionOverride
    @Environment(\.capyAccessibilityFocus) private var focus
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }
    @StateObject private var feedback = GameFeedbackPresentation()
    @StateObject private var rewards = GameRewardPresentation()
    @StateObject private var hud = GameHUDPresentation()
    @State private var progressFrame = CGRect.zero
    @State private var gameWindowFrame = CGRect.zero
    @State private var ruleWindowFrame = CGRect.zero
    @State private var comboBandWindowFrame = CGRect.zero
    @State private var comboBadgeWindowFrame = CGRect.zero
    @State private var comboBadgeFrameRevision: UUID?
    @State private var directWindowFrame = CGRect.zero
    @State private var livesWindowFrame = CGRect.zero
    @State private var lifeFocusReturn: String?
    @State private var hintContentHeight: CGFloat = 66
    private var canPresentFeedback: Bool {
        model.screen == .game && scenePhase == .active && model.hint == nil && model.sheet == nil && !model.loading && !model.rewardBusy && !model.interstitialBusy &&
        !model.challengePending && model.errorMessage == nil && model.notice == nil
    }
    private var flightTextFrames: [CGRect] {
        var frames = [ruleWindowFrame]
        if feedback.comboText != nil {
            // A new badge uses the row only until its own current bounds arrive;
            // an empty feedback band never hides a flying star.
            let currentBadge = comboBadgeFrameRevision == feedback.comboRevision && !comboBadgeWindowFrame.isEmpty
            frames.append(currentBadge ? comboBadgeWindowFrame : comboBandWindowFrame)
        }
        return frames.map {
            $0.offsetBy(dx: -gameWindowFrame.minX, dy: -gameWindowFrame.minY).insetBy(dx: -5, dy: -5)
        }
    }
    private var flightTextMeasurementsReady: Bool {
        !ruleWindowFrame.isEmpty && !gameWindowFrame.isEmpty &&
            (feedback.comboText == nil || !comboBandWindowFrame.isEmpty)
    }
    var body: some View {
        GeometryReader { geometry in
            if let s = model.session {
                // Preserve the normal reference layout for short explanations.
                // Longer/larger text may grow only into spare board space; the
                // remainder scrolls inside its own viewport, never over Close.
                let compact = geometry.size.width < 360 || geometry.size.height < 640
                let ruleHeight: CGFloat = compact ? 56 : 66
                let footerHeight: CGFloat = compact ? (model.hint != nil ? 60 : model.tutorial != nil ? 100 : 70) : 130
                let bannerHeight: CGFloat = model.tutorial == nil ? 44 : 12
                // Compact space comes from decoration, gaps and the unused free
                // tool row. The board itself never acquires a scroll container.
                let feedbackHeight: CGFloat = compact ? 24 : 30
                let fixedHeight: CGFloat = (compact ? 44 + 44 + 32 + 4 + 8 + footerHeight + bannerHeight + 8 : 354) + feedbackHeight
                let maximumHintHeight = max(66, geometry.size.height - fixedHeight - 190)
                let hintHeight = model.hint == nil ? ruleHeight : min(max(66, hintContentHeight), maximumHintHeight)
                let boardSide = max(190, min(geometry.size.width - 28, geometry.size.height - fixedHeight - hintHeight, 500))
                let lifeFocused = feedback.showLastLife && s.status == .playing && canPresentFeedback
                let covered = s.status != .playing || model.sheet != nil || model.loading || model.challengePending || lifeFocused
                ZStack {
                    VStack(spacing: 0) {
                        HStack {
                            IconButton(symbol: "arrow.left", label: "Home", id: "home") {
                                if model.hint != nil { model.closeHint() } else { model.home() }
                            }.capyLayoutProbe("home").accessibilityHidden(covered || model.hint != nil).disabled(model.hint != nil)
                                .opacity(s.status == .playing ? 1 : 0)
                                .animation(nil, value: s.status)
                            Spacer()
                            IconButton(symbol: model.hint == nil ? "gearshape.fill" : "xmark", label: model.hint == nil ? "Settings" : "Close hint", id: model.hint == nil ? "settings" : "hint_close") {
                                if model.hint != nil { model.closeHint() } else { model.sheet = .settings }
                            }.capyLayoutProbe(model.hint == nil ? "settings" : "hint_close")
                        }.frame(height: 44).padding(.horizontal, 8)
                        HStack(spacing: 52) {
                            (Text(language.text("Level\n")).font(.system(size: compact ? 14 : 17, weight: .medium, design: .rounded)) + Text("\(s.puzzle.id)").font(.system(size: compact ? 22 : 25, weight: .heavy, design: .rounded)))
                                .multilineTextAlignment(.center).accessibilityLabel(language.text("Level \(s.puzzle.id)")).accessibilityIdentifier("level_title").capyFocus("level_title")
                                .capyLayoutProbe("level_title")
                            VStack(spacing: 0) {
                                Text(language.text("Score")).font(.system(size: compact ? 14 : 17, weight: .medium, design: .rounded))
                                ScorePulseView(score: s.score, sessionID: s.id, pulseID: rewards.scorePulseID,
                                               fontSize: compact ? 22 : 25, reduceMotion: reduceMotion,
                                               presentationEnabled: canPresentFeedback && !lifeFocused)
                                    .fixedSize()
                            }
                        }.frame(height: compact ? 44 : 56).opacity(model.hint == nil ? 1 : 0.35).accessibilityHidden(covered || model.hint != nil)
                        HStack(spacing: compact ? 12 : 18) {
                            progress(s, compact: compact)
                            HStack(spacing: 4) {
                                ForEach(0..<s.config.initialLives, id: \.self) { index in
                                    LifeHeartView(available: index < s.lives, size: compact ? 19 : 22,
                                                  lossID: hud.lifeLosses.first(where: { $0.index == index })?.id,
                                                  reduceMotion: reduceMotion)
                                }
                            }.padding(.horizontal, 10).padding(.vertical, 5).background(CapyPalette.paper).clipShape(Capsule())
                                .accessibilityElement(children: .ignore).accessibilityLabel(language.text("Lives")).accessibilityValue("\(s.lives)").accessibilityIdentifier("lives")
                                .capyLayoutProbe("lives")
                                .background(FeedbackWindowFrameReader { livesWindowFrame = $0 })
                        }.frame(height: compact ? 32 : 40).opacity(model.hint == nil ? 1 : 0.35).accessibilityHidden(covered || model.hint != nil)
                        Group {
                            if let hint = model.hint, let useID = model.progress.activeHintUse?.id {
                                ScrollView(.vertical, showsIndicators: true) {
                                    HintPanel(hint: hint)
                                        .background(GeometryReader { layout in
                                            Color.clear.preference(key: HintContentHeightKey.self, value: layout.size.height)
                                        })
                                }
                                    .frame(height: hintHeight)
                                    .background(CapyPalette.paper)
                                    .clipShape(RoundedRectangle(cornerRadius: 17))
                                    .id(useID)
                                    .onPreferenceChange(HintContentHeightKey.self) { height in
                                        if height > 0 { hintContentHeight = ceil(height) }
                                    }
                                    .onAppear { model.hintDidAppear(useID: useID) }
                                    .onChange(of: scenePhase) { phase in
                                        if phase == .active { model.hintDidAppear(useID: useID) }
                                    }
                                    .onChange(of: model.errorMessage) { message in
                                        if message == nil { model.hintDidAppear(useID: useID) }
                                    }
                                    .onChange(of: model.notice) { message in
                                        if message == nil { model.hintDidAppear(useID: useID) }
                                    }
                                    .onChange(of: model.sheet) { sheet in
                                        if sheet == nil { model.hintDidAppear(useID: useID) }
                                    }
                                    .onChange(of: model.loading) { loading in
                                        if !loading { model.hintDidAppear(useID: useID) }
                                    }
                            }
                            else { RuleStrip(compact: compact, highlightedRules: hud.highlightedRules) }
                        }.frame(height: hintHeight).padding(.top, compact ? 4 : 8)
                            .background(FeedbackWindowFrameReader { ruleWindowFrame = $0 })
                        comboBadge(compact: compact).frame(height: feedbackHeight)
                            .background(FeedbackWindowFrameReader { comboBandWindowFrame = $0 })
                        PuzzleBoardView(puzzle: s.puzzle, found: s.found, marks: s.marks, errors: s.errors,
                                        sessionID: s.id, entranceID: model.boardEntranceID, lives: s.lives, score: s.score,
                                        latestSubmissionSucceeded: s.combo > 0,
                                        effectsEnabled: canPresentFeedback,
                                        preview: Set(model.hint?.cells ?? []), tutorialTargets: Set(model.tutorial?.targetCells ?? []),
                                        tutorialAction: model.tutorial?.action,
                                        hideAccessibility: covered,
                                        locked: s.status != .playing || !canPresentFeedback || lifeFocused || model.tutorial?.action == "read",
                                        onToggle: model.toggle, onSubmit: model.submit, onMark: model.mark,
                                        onBeginSwipe: model.beginSwipeFeedback,
                                        onEndSwipe: { model.endSwipeFeedback(cancelled: $0) },
                                        onInputActivityChange: { token, active in
                                            model.setBoardInputActivity(token, active: active, sessionID: s.id)
                                        }, onFoundFeedback: { index, sourceWindowCell in
                                            let feedbackEpoch = model.sceneFeedbackEpoch
                                            let origin = gameWindowFrame.origin
                                            let target = CGPoint(x: progressFrame.midX - origin.x, y: progressFrame.midY - origin.y)
                                            let sourceCell = sourceWindowCell.offsetBy(dx: -origin.x, dy: -origin.y)
                                            let source = CGPoint(x: sourceCell.midX, y: sourceCell.midY)
                                            // UIViewRepresentable updates may occur during a SwiftUI
                                            // render. Schedule presentation after that transaction.
                                            DispatchQueue.main.async {
                                                guard model.session?.id == s.id, canPresentFeedback,
                                                      !progressFrame.isEmpty, !gameWindowFrame.isEmpty,
                                                      model.canPresentPositiveFeedback(from: s, epoch: feedbackEpoch) else { return }
                                                rewards.found(index: index, sessionID: s.id, origin: source, destination: target,
                                                              sourceCell: sourceCell, reduceMotion: reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled)
                                                if let event = model.directRevealFeedback, event.sessionID == s.id,
                                                   event.cell == index, !directWindowFrame.isEmpty {
                                                    let tool = CGPoint(x: directWindowFrame.midX - gameWindowFrame.minX,
                                                                       y: directWindowFrame.midY - gameWindowFrame.minY)
                                                    rewards.directReveal(event, origin: tool, destination: source,
                                                                         reduceMotion: reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled)
                                                }
                                            }
                                        }, onConflictFeedback: { kinds in
                                            DispatchQueue.main.async {
                                                guard model.session?.id == s.id else { return }
                                                hud.conflict(kinds, sessionID: s.id, visible: canPresentFeedback)
                                            }
                                        }, onScoreFeedback: { amount, anchor in
                                            let feedbackEpoch = model.sceneFeedbackEpoch
                                            let offset = CGVector(dx: -gameWindowFrame.minX, dy: -gameWindowFrame.minY)
                                            let cell = anchor.cellFrame.offsetBy(dx: offset.dx, dy: offset.dy)
                                            let area = anchor.boardFrame.offsetBy(dx: offset.dx, dy: offset.dy)
                                            let foundFrames = anchor.foundFrames.map { $0.offsetBy(dx: offset.dx, dy: offset.dy) }
                                            let placement = CellScorePlacement.anchored(amount: amount, cellFrame: cell, boardFrame: area, avoiding: foundFrames)
                                            DispatchQueue.main.async {
                                                guard model.session?.id == s.id, canPresentFeedback,
                                                      !gameWindowFrame.isEmpty,
                                                      model.canPresentPositiveFeedback(from: s, epoch: feedbackEpoch) else { return }
                                                rewards.retireScores(overlapping: foundFrames, sessionID: s.id)
                                                guard let placement else { return }
                                                rewards.scoreAward(amount, sessionID: s.id, placement: placement,
                                                                   reduceMotion: reduceMotion)
                                            }
                                        })
                            .frame(width: boardSide, height: boardSide)
                            .capyLayoutProbe("puzzle_board")
                        Spacer(minLength: compact ? 4 : 10)
                        Group { if model.hint != nil {
                            CapyButton(id: "hint_apply", action: model.applyHint) { Text(language.text("Apply")).frame(maxWidth: .infinity) }
                                .buttonStyle(CapyButtonStyle()).frame(maxWidth: 280).accessibilityIdentifier("hint_apply").capyLayoutProbe("hint_apply").frame(height: footerHeight)
                        } else if let tutorial = model.tutorial {
                            if compact {
                                // Only the instruction area scrolls. The board
                                // remains a sibling with its own gesture arena.
                                ScrollView(.vertical, showsIndicators: true) {
                                    TutorialPanel(step: tutorial)
                                }.frame(height: footerHeight)
                            } else { TutorialPanel(step: tutorial).padding(.top, 8) }
                        } else { tools(compact: compact).frame(height: footerHeight) }
                        }.capyLayoutProbe("game_footer")
                            // Keep the exact board/footer allocation, but never
                            // show old tools underneath the new result action.
                            .opacity(s.status == .playing ? 1 : 0)
                            .animation(nil, value: s.status)
                        // Reserved in every state, so loading or hiding a banner never moves the board.
                        Color.clear.frame(height: bannerHeight).accessibilityIdentifier("banner_reservation")
                    }.disabled(s.status != .playing || lifeFocused).accessibilityElement(children: covered ? .ignore : .contain).accessibilityHidden(covered).padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 4)
                    ZStack {
                        ForEach(rewards.flights) { ProgressFlightStar(flight: $0) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .mask {
                        ProgressFlightTextMask(protectedFrames: flightTextFrames).fill(style: FillStyle(eoFill: true))
                    }
                    // Until real text bounds are measured, omit only the
                    // decoration. Accepted state and its arrival still advance.
                    .opacity(flightTextMeasurementsReady ? 1 : 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
                    ForEach(rewards.localScores) { CellScoreLabel(item: $0) }
                    if let reveal = rewards.toolReveal { DirectToolRevealView(reveal: reveal).id(reveal.id) }
                    if lifeFocused {
                        LastLifeSpotlightView(livesFrame: livesWindowFrame.offsetBy(dx: -gameWindowFrame.minX, dy: -gameWindowFrame.minY)) {
                            feedback.dismissLastLife()
                        }.transition(.opacity).zIndex(4)
                    }
                }
                .background(FeedbackWindowFrameReader { gameWindowFrame = $0 })
                .onChange(of: s.combo) { combo in
                    feedback.setPresentationEnabled(canPresentFeedback)
                    feedback.combo(model.comboFeedbackPresentation(for: combo))
                }
                .onChange(of: s.lives) {
                    // A newer mistake owns the visual explanation. Stop older
                    // celebration, while the accepted score stays in the model.
                    rewards.clear()
                    feedback.setPresentationEnabled(canPresentFeedback)
                    feedback.life($0)
                    hud.lifeChanged($0, sessionID: s.id, visible: canPresentFeedback)
                }
                .onChange(of: s.status) { status in
                    if status != .playing { feedback.dismissLastLife() }
                }
                .onChange(of: feedback.showLastLife) { showing in
                    if showing {
                        lifeFocusReturn = focus?.wrappedValue
                        focus?.wrappedValue = "last_life_continue"
                    } else if focus?.wrappedValue == "last_life_continue" {
                        focus?.wrappedValue = lifeFocusReturn ?? "level_title"
                    }
                }
                .onChange(of: s.score) {
                    rewards.scoreChanged($0, sessionID: s.id, visible: canPresentFeedback && (model.session?.combo ?? 0) > 0)
                }
                .onChange(of: s.id) { _ in
                    feedback.clear(); rewards.bind(sessionID: s.id, score: s.score)
                    hud.bind(sessionID: s.id, lives: s.lives)
                }
                .onChange(of: canPresentFeedback) {
                    feedback.setPresentationEnabled($0)
                    rewards.setPresentationEnabled($0); hud.setPresentationEnabled($0)
                }
                .onAppear {
                    feedback.setPresentationEnabled(canPresentFeedback); rewards.bind(sessionID: s.id, score: s.score)
                    hud.bind(sessionID: s.id, lives: s.lives)
                    rewards.setPresentationEnabled(canPresentFeedback); hud.setPresentationEnabled(canPresentFeedback)
                }
                .onDisappear {
                    feedback.setPresentationEnabled(false)
                    rewards.setPresentationEnabled(false); hud.setPresentationEnabled(false)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: feedback.showLastLife)
                .accessibilityAddTraits(model.hint != nil ? .isModal : [])
            }
        }
    }

    private var freeToolButton: some View {
        CapyButton(id: "level_start_free", action: model.levelStartFree) {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill")
                    .foregroundColor(model.levelStartFreeAvailable ? CapyPalette.video : CapyPalette.checkInSecondaryText)
                Text(language.text("Free tool")).font(.system(size: 13, weight: .bold, design: .rounded))
            }.padding(.horizontal, 16).frame(minHeight: 44)
        }.buttonStyle(CapyPressStyle(disabledOpacity: 1))
            .disabled(!model.levelStartFreeAvailable)
            .foregroundColor(model.levelStartFreeAvailable ? CapyPalette.ink : CapyPalette.checkInSecondaryText)
            .accessibilityIdentifier("level_start_free").capyLayoutProbe("level_start_free")
    }

    private func toolRow(compact: Bool) -> some View {
        HStack(spacing: compact ? (model.levelStartFreeVisible ? 8 : 52) : 68) {
            if model.directVisible {
                ToolButton(title: "Find a capy", isDirect: true, count: model.progress.availableDirect, id: "direct", action: model.direct)
                    .disabled(!model.directEnabled)
                    .background(FeedbackWindowFrameReader { directWindowFrame = $0 })
            } else { Color.clear.frame(width: 62, height: 62).accessibilityHidden(true) }
            if compact && model.levelStartFreeVisible { freeToolButton }
            ToolButton(title: "Hint", isDirect: false, count: model.progress.availableHints, id: "hint", action: model.showHint)
                .disabled(!model.hintEnabled)
        }.frame(height: compact ? 70 : 86)
    }

    private func tools(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if !compact {
                Group {
                    if model.levelStartFreeVisible { freeToolButton }
                    else { Color.clear.accessibilityHidden(true) }
                }.frame(height: 44)
            }
            toolRow(compact: compact)
        }.disabled(model.session?.status != .playing || model.sheet != nil || model.rewardBusy)
    }

    private func progress(_ s: GameSession, compact: Bool) -> some View {
        HStack(spacing: 3) {
            // Original image24 retains one animal slot through the 8x8 example;
            // the 10x10 example switches to the compact found/total display.
            if s.puzzle.size <= 8 {
                ForEach(0..<s.puzzle.size, id: \.self) { index in
                    CapyMascot(mood: .happy, size: compact ? 18 : 23).opacity(index < s.found.count ? 1 : 0.17)
                }
            } else {
                CapyMascot(mood: .happy, size: 27)
                (Text("\(s.found.count)").foregroundColor(CapyPalette.green) + Text("/\(s.puzzle.size)"))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
            }
        }.padding(.horizontal, 9).padding(.vertical, 4).background(CapyPalette.paper).clipShape(Capsule())
            .background(FeedbackWindowFrameReader { progressFrame = $0 })
            .overlay(Capsule().stroke(CapyPalette.orange.opacity(rewards.progressPulse ? 0.9 : 0), lineWidth: 2))
            .modifier(ProgressArrivalPulseModifier(sessionID: s.id, arrivalID: rewards.progressArrivalID,
                                                  enabled: canPresentFeedback && !feedback.showLastLife,
                                                  reduceMotion: reduceMotion))
            .accessibilityElement(children: .ignore).accessibilityLabel(language.text(s.lives == 1 ? "One heart left. \(s.found.count) of \(s.puzzle.size) found" : "\(s.found.count) of \(s.puzzle.size) found")).accessibilityIdentifier("found_count")
            .capyLayoutProbe("found_count")

    }

    private func comboBadge(compact: Bool) -> some View {
        ZStack {
            Color.clear
            HStack {
                Spacer()
                ApplauseFeedbackView(eventID: rewards.applauseID,
                                     enabled: canPresentFeedback && !feedback.showLastLife && !resultDecorationReady,
                                     reduceMotion: reduceMotion,
                                     lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
                    // At most ten accepted finds belong to one board. Retire
                    // the native view and its consumed IDs with that session.
                    .id(model.session?.id)
                    .frame(width: compact ? 28 : 34, height: compact ? 24 : 30)
                    .capyLayoutProbe("applause_feedback")
            }
            if let combo = feedback.comboText {
                ComboCelebrationView(text: language.text(combo), tier: ComboVisualTier(text: combo), compact: compact,
                                     reduceMotion: reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled)
                    .background(FeedbackWindowFrameReader { [revision = feedback.comboRevision] frame in
                        comboBadgeWindowFrame = frame; comboBadgeFrameRevision = revision
                    })
                    .accessibilityIdentifier("combo_feedback").capyLayoutProbe("combo_feedback")
                    .id(feedback.comboRevision)
                    // Each accepted find gets the child's own entrance spring.
                    // A second scale transition collapses the entire badge on
                    // replacement, briefly making repeated Combos unreadable.
                    .transition(.identity)
            }
        }.allowsHitTesting(false)
            // Preserve the last find's board-phase Combo. Once result artwork
            // starts, remove only this text so it cannot sit behind the title.
            // The clear band still reserves the same board/HUD layout space.
            .opacity(resultDecorationReady ? 0 : 1)
            .accessibilityHidden(resultDecorationReady)
            .transaction {
                if resultDecorationReady { $0.animation = nil; $0.disablesAnimations = true }
            }
    }

}

struct ToolButton: View {
    @Environment(\.appLanguage) private var language
    let title: String
    let isDirect: Bool
    let count: Int
    let id: String
    let action: () -> Void
    var body: some View {
        CapyButton(id: id, action: action) {
            ZStack {
                Circle().fill(CapyPalette.paper).shadow(color: CapyPalette.orange.opacity(0.17), radius: 2, y: 3)
                if isDirect {
                    ZStack {
                        CapyMascot(mood: .happy, size: 39).offset(x: -3, y: -3)
                        Image(systemName: "magnifyingglass").font(.system(size: 43, weight: .bold)).foregroundColor(CapyPalette.ink.opacity(0.85)).offset(x: 3, y: 4)
                    }
                } else {
                    Image(systemName: "lightbulb.fill").font(.system(size: 38, weight: .regular))
                        .foregroundColor(Color(red: 1, green: 0.70, blue: 0.12))
                }
            }.frame(width: 62, height: 62)
                .overlay(alignment: .topTrailing) {
                    Group {
                        if count > 0 {
                            Text("\(count)").font(.system(size: 15, weight: .heavy, design: .rounded))
                                .frame(minWidth: 24, minHeight: 24).background(CapyPalette.life).clipShape(Capsule())
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                                .frame(width: 31, height: 22).background(CapyPalette.video).clipShape(Capsule())
                        }
                    }.foregroundColor(.white).offset(x: 6, y: -5)
                }
        }.buttonStyle(ToolPressStyle(direct: isDirect)).accessibilityLabel(language.text(title))
            .accessibilityValue(language.text(count > 0 ? "\(count) available" : "Video reward"))
            .accessibilityIdentifier(id)
            .capyLayoutProbe(id)
    }
}

struct RuleStrip: View {
    @Environment(\.appLanguage) private var language
    var compact = false
    var highlightedRules: Set<VisibleConflictKind> = []
    var body: some View {
        HStack(spacing: 4) {
            rule(0, "1 Capy per\ncolor")
            rule(1, "1 Capy per\ncolumn and row")
            rule(2, "Capys cannot\ntouch")
        }.padding(compact ? 4 : 6).background(CapyPalette.paper).clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine).accessibilityIdentifier("rule_strip")
            .capyLayoutProbe("rule_strip")
    }
    private func rule(_ kind: Int, _ title: String) -> some View {
        Group {
            if compact {
                VStack(spacing: 2) {
                    RuleDiagram(kind: kind).frame(width: 18, height: 18)
                    ruleText(title).multilineTextAlignment(.center)
                }
            } else {
                HStack(spacing: 4) {
                    RuleDiagram(kind: kind).frame(width: 30, height: 30)
                    ruleText(title)
                }
            }
        }.frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .padding(.horizontal, compact ? 2 : 3).padding(.vertical, compact ? 2 : 8)
            .background(isHighlighted(kind) ? CapyPalette.life.opacity(0.18) : CapyPalette.cream)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isHighlighted(kind) ? CapyPalette.life : .clear, lineWidth: 2))
    }
    private func isHighlighted(_ kind: Int) -> Bool {
        switch kind {
        case 0: return highlightedRules.contains(.region)
        case 1: return highlightedRules.contains(.row) || highlightedRules.contains(.column)
        default: return highlightedRules.contains(.adjacent)
        }
    }
    private func ruleText(_ title: String) -> some View {
        Text(language.text(title)).font(.system(size: 10, weight: .semibold, design: .rounded)).minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct RuleDiagram: View {
    let kind: Int
    var body: some View {
        Canvas { context, size in
            let side = size.width / 3
            for row in 0..<3 {
                for column in 0..<3 {
                    let r = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side - 1, height: side - 1)
                    let excluded = kind == 2 || (kind == 1 ? row == 1 || column == 1 : row < 2 || column == 0)
                    context.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(excluded ? Color(red: 0.68, green: 0.42, blue: 0.26) : CapyPalette.orangeLight))
                    if row == 1 && column == 1 {
                        context.draw(Image("CapyFace"), in: r)
                    } else if excluded {
                        var mark = Path(); mark.move(to: CGPoint(x: r.minX + 2, y: r.minY + 2)); mark.addLine(to: CGPoint(x: r.maxX - 2, y: r.maxY - 2)); mark.move(to: CGPoint(x: r.maxX - 2, y: r.minY + 2)); mark.addLine(to: CGPoint(x: r.minX + 2, y: r.maxY - 2))
                        context.stroke(mark, with: .color(.white), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    }
                }
            }
        }.accessibilityHidden(true)
    }
}

struct TutorialPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var language
    let step: TutorialStep
    var body: some View {
        CapyCard(padding: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(model.progress.tutorialStep + 1)/\(model.tutorialCount) · \(language.text(step.title))")
                        .font(.system(size: 14, weight: .bold, design: .rounded)).accessibilityIdentifier("tutorial_title")
                    Spacer()
                    CapyButton(language.text("Skip"), id: "skip_tutorial", action: model.skipTutorial).buttonStyle(CapyPressStyle()).font(.system(size: 13, weight: .bold, design: .rounded)).frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("skip_tutorial").capyLayoutProbe("skip_tutorial")
                }
                Text(language.text(step.instruction)).font(.system(size: 12, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                if step.action == "read" {
                    CapyButton(language.text("Got it"), id: "tutorial_next", action: model.advanceTutorial).buttonStyle(CapyButtonStyle(compact: true)).accessibilityIdentifier("tutorial_next").capyLayoutProbe("tutorial_next")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HintPanel: View {
    @Environment(\.appLanguage) private var language
    @ScaledMetric(relativeTo: .footnote) private var textSize: CGFloat = 13
    let hint: PuzzleHint
    var body: some View {
        Text(language.text(hint.explanation)).font(.system(size: textSize, weight: .semibold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17).padding(.vertical, 11)
            .background(CapyPalette.paper).clipShape(RoundedRectangle(cornerRadius: 17))
            .accessibilityLabel(language.text("Hint. \(hint.rule). \(hint.explanation)"))
            .accessibilityIdentifier("hint_explanation").capyFocus("hint_explanation")
    }
}

private struct HintContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 66
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ResultPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.capyMotionOverride) private var motionOverride
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }
    let won: Bool
    var isPresented = true
    var displaySession: GameSession? = nil
    var showsDecoration = true
    var animationID: UUID? = nil
    var presentationEnabled = true
    var transitionEnabled = true
    var stage: ResultEntrancePresentation.Stage = .settled
    private var session: GameSession? { displaySession ?? model.session }
    private var titleVisible: Bool { showsDecoration && (reduceMotion || stage >= .title) }
    private var detailVisible: Bool { showsDecoration && (reduceMotion || stage >= .detail) }
    private var variant: ResultCelebrationVariant {
        (session?.id.uuid.0 ?? 0).isMultiple(of: 2) ? .joyfulBounce : .proudCrown
    }
    private var praise: String { variant == .joyfulBounce ? "Nice Work" : "Intelligent" }
    private var failure: ReferenceFailureConfiguration? { session?.config.referenceGameplay?.failure }
    private var victoryDetail: String {
        guard let session else { return "All Capybaras found!" }
        if session.attempt == 1 { return "A solid victory on your very first attempt!" }
        if !session.hasRevived && session.lives == session.config.initialLives { return "No mistakes!" }
        return "All Capybaras found!"
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(spacing: 20) {
                    Text(language.text(won ? praise : (failure?.title ?? "So Close!")))
                        .font(.system(size: 39, weight: .heavy, design: .rounded)).foregroundColor(.white)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .shadow(color: CapyPalette.orange, radius: 0, x: 1, y: 2)
                        .accessibilityIdentifier(won ? "win_result" : "loss_result")
                        .capyLayoutProbe(won ? "win_result" : "loss_result")
                        .accessibilityAddTraits(.isHeader).capyFocus(won ? "win_result" : "loss_result")
                        .accessibilityValue(language.text("Level \(session?.puzzle.id ?? 1). Score \(session?.score ?? 0). \(session?.found.count ?? 0) of \(session?.puzzle.size ?? 0) found."))
                        .opacity(titleVisible ? 1 : 0).accessibilityHidden(!titleVisible)
                        .offset(y: titleVisible || reduceMotion ? 0 : 9)
                        .scaleEffect(titleVisible || reduceMotion ? 1 : 0.94)
                    ResultCharacterView(won: won, variant: variant, size: min(geometry.size.width * 0.65, geometry.size.height * 0.34, 250),
                                        animationID: showsDecoration ? animationID : nil,
                                        presentationEnabled: presentationEnabled && showsDecoration)
                        .frame(height: min(geometry.size.height * 0.34, 270)).opacity(showsDecoration ? 1 : 0).accessibilityHidden(!showsDecoration)
                        .background {
                            ResultAtmosphereView(won: won, eventID: showsDecoration ? animationID : nil,
                                                 enabled: presentationEnabled && showsDecoration, reduceMotion: reduceMotion)
                                .frame(width: min(geometry.size.width - 24, 370), height: min(geometry.size.height * 0.43, 340))
                                .opacity(showsDecoration ? 1 : 0).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    Text(language.text(won ? victoryDetail : "The next Capybara is close. Your progress is worth keeping!"))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(won ? Color(red: 1, green: 0.86, blue: 0.39) : CapyPalette.orangeLight)
                        .opacity(detailVisible ? 1 : 0).accessibilityHidden(!detailVisible)
                        .offset(y: detailVisible || reduceMotion ? 0 : 8)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                    .scaleEffect(showsDecoration || !transitionEnabled || reduceMotion ? 1 : 0.88)
                    .opacity(showsDecoration ? 1 : 0)
                    .animation(transitionEnabled && !reduceMotion ? .easeOut(duration: 0.18) : nil, value: showsDecoration)
                    .transaction {
                        if !transitionEnabled || reduceMotion { $0.animation = nil; $0.disablesAnimations = true }
                    }
                    Group {
                    CapyButton(id: won ? "next_level" : "revive") {
                        if won { model.next() } else { model.revive() }
                    } label: {
                        Text(language.text(won ? "Level \((session?.puzzle.id ?? 1) + 1)" : (failure?.reviveButtonTitle ?? "Play On"))).frame(maxWidth: .infinity)
                    }.buttonStyle(CapyButtonStyle()).disabled(!won && !model.reviveAvailable).accessibilityIdentifier(won ? "next_level" : "revive")
                        .capyLayoutProbe("result_primary_action")
                        .overlay(alignment: .topTrailing) {
                            if !won && model.reviveAvailable {
                                Group {
                                    if model.reviveNeedsVideo { Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)) }
                                    else { Text(language.text("Free")).font(.system(size: 15, weight: .heavy, design: .rounded)) }
                                }.foregroundColor(.white).padding(.horizontal, 15).padding(.vertical, 8)
                                    .background(model.reviveNeedsVideo ? CapyPalette.video : CapyPalette.rewardTextGreen)
                                    .clipShape(Capsule()).offset(y: -12).allowsHitTesting(false)
                            }
                        }
                    if !won {
                        CapyButton(id: "result_restart", action: model.restart) { Text(language.text(failure?.restartButtonTitle ?? "Restart")).frame(maxWidth: .infinity) }
                            .buttonStyle(CapyButtonStyle(secondary: true, darkBackdrop: true)).accessibilityIdentifier("result_restart")
                    }
                    }.opacity(isPresented ? 1 : 0).allowsHitTesting(isPresented).accessibilityHidden(!isPresented)
                        .animation(nil, value: isPresented)
                }.padding(.horizontal, 40).padding(.vertical, 24)
                    .frame(maxWidth: 440).frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 52))
                    .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78), value: stage)
                }.padding(.top, 52)
                if won || failure?.canDismiss != false {
                    VStack {
                        HStack {
                            IconButton(symbol: "arrow.left", label: "Home", id: "result_home", action: model.home)
                            Spacer()
                        }
                        Spacer()
                    }.padding(.horizontal, 22).padding(.top, 4)
                        .opacity(isPresented ? 1 : 0).allowsHitTesting(isPresented).accessibilityHidden(!isPresented)
                        .animation(nil, value: isPresented)
                }
            }
        }.accessibilityAddTraits(.isModal)
    }
}

/// The original L10 → L11 flow places this after the interstitial has closed.
struct ChallengePanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var language
    var body: some View {
        CapyCard(padding: 24) {
            VStack(spacing: 22) {
                Text(language.text("A New Challenge!")).font(.system(size: 29, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                    .capyFocus("challenge_title").accessibilityIdentifier("challenge_title")
                CapyMascot(mood: .happy, size: 160)
                CapyButton(id: "challenge_continue", action: model.continueChallenge) { Text(language.text("Continue")).frame(maxWidth: .infinity) }
                    .buttonStyle(CapyButtonStyle()).accessibilityIdentifier("challenge_continue")
            }
        }.frame(maxWidth: 350).padding(.horizontal, 24)
            .accessibilityAddTraits(.isModal)
    }
}
