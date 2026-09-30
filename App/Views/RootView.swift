import SwiftUI
import CapydokuCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    // Root owns the preference so independently hosted screens also update.
    private var language: AppLanguage { model.progress.settings.language }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    // Hosted-view verification can select this branch without changing the
    // device's accessibility setting. Production callers leave it nil.
    var reduceMotionOverride: Bool? = nil
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var focusedControl: String?
    @State private var lastActivatedControl: String?
    @State private var previousModal: String?
    @State private var modalOrigins: [String: String] = [:]
    private var hasCard: Bool { model.sheet == .settings || model.sheet == .reward }
    private var hasResult: Bool { model.screen == .game && model.session?.status != .playing && model.session != nil }
    private var modal: String? {
        if model.errorMessage != nil || model.notice != nil { return "alert" }
        if model.loading { return "loading" }
        if model.sheet == .reward { return "reward" }
        if model.challengePending { return "challenge" }
        if model.sheet == .settings { return "settings" }
        if model.sheet == .debug { return "debug" }
        if model.screen == .game, model.hint != nil { return "hint" }
        if model.screen == .game, let session = model.session, session.status != .playing {
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
                case .game: GameView()
                case .checkIn: CheckInView(reduceMotionOverride: reduceMotionOverride)
                }
                }.environmentObject(model).foregroundColor(CapyPalette.ink)
                    .environment(\.appLanguage, language)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.capyAccessibilityFocus, $focusedControl)
                    .environment(\.capyButtonActivation, activate)
            }
            if hasResult && model.sheet != .reward {
                Color.black.opacity(0.78).ignoresSafeArea().accessibilityHidden(true)
                CapyAccessibilityHost(hidden: hasCard || model.loading || model.challengePending) {
                    ResultPanel(won: model.session?.status == .won).environmentObject(model).foregroundColor(CapyPalette.ink)
                        .environment(\.appLanguage, language)
                        .environment(\.dynamicTypeSize, dynamicTypeSize)
                        .environment(\.capyAccessibilityFocus, $focusedControl)
                        .environment(\.capyButtonActivation, activate)
                }
                // Original [253]: result overlays use the same centered entrance
                // and exit as the other cards. Timing remains a Demo value.
                .transition(reduceMotion ? .opacity : .scale(scale: 0.88).combined(with: .opacity))
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
        .onAppear { moveFocus(to: modal) }
        .onChange(of: modal) { moveFocus(to: $0) }
        .onChange(of: scenePhase) { phase in if phase == .active { requestFocus(modalHeading ?? focusedControl ?? defaultFocus) } }
        .foregroundColor(CapyPalette.ink)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hasCard)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hasResult)
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
    private func activate(_ id: String?) {
        if let id { lastActivatedControl = id }
        model.uiTap(id ?? "button")
    }
    private var modalHeading: String? {
        guard let modal else { return nil }
        return ["settings": "settings_title", "reward": "reward_title", "challenge": "challenge_title",
                "loading": "loading_title", "hint": "hint_explanation", "win": "win_result", "loss": "loss_result"][modal]
    }
    private func requestFocus(_ id: String) {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
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
                        CapyMascot(mood: .happy, size: 98)
                            .offset(y: breathing ? -4 : 2)
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
        .onAppear {
            if !reduceMotion { withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { breathing = true } }
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
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var language
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var feedback = GameFeedbackPresentation()
    @State private var hintContentHeight: CGFloat = 66
    private var canPresentFeedback: Bool {
        scenePhase == .active && model.hint == nil && model.sheet == nil && !model.loading &&
        !model.challengePending && model.errorMessage == nil && model.notice == nil
    }
    var body: some View {
        GeometryReader { geometry in
            if let s = model.session {
                // Preserve the normal reference layout for short explanations.
                // Longer/larger text may grow only into spare board space; the
                // remainder scrolls inside its own viewport, never over Close.
                let maximumHintHeight = max(66, geometry.size.height - 420 - 190 + 66)
                let hintHeight = model.hint == nil ? 66 : min(max(66, hintContentHeight), maximumHintHeight)
                let boardSide = max(190, min(geometry.size.width - 28, geometry.size.height - 420 - (hintHeight - 66), 500))
                let covered = s.status != .playing || model.sheet != nil || model.loading || model.challengePending
                ZStack {
                    VStack(spacing: 0) {
                        HStack {
                            IconButton(symbol: "arrow.left", label: "Home", id: "home") {
                                if model.hint != nil { model.closeHint() } else { model.home() }
                            }.accessibilityHidden(covered || model.hint != nil).disabled(model.hint != nil)
                            Spacer()
                            IconButton(symbol: model.hint == nil ? "gearshape.fill" : "xmark", label: model.hint == nil ? "Settings" : "Close hint", id: model.hint == nil ? "settings" : "hint_close") {
                                if model.hint != nil { model.closeHint() } else { model.sheet = .settings }
                            }
                        }.frame(height: 44).padding(.horizontal, 8)
                        HStack(spacing: 52) {
                            (Text(language.text("Level\n")).font(.system(size: 17, weight: .medium, design: .rounded)) + Text("\(s.puzzle.id)").font(.system(size: 25, weight: .heavy, design: .rounded)))
                                .multilineTextAlignment(.center).accessibilityLabel(language.text("Level \(s.puzzle.id)")).accessibilityIdentifier("level_title").capyFocus("level_title")
                            VStack(spacing: 0) {
                                Text(language.text("Score")).font(.system(size: 17, weight: .medium, design: .rounded))
                                Text("\(s.score)").font(.system(size: 25, weight: .heavy, design: .rounded)).accessibilityIdentifier("score")
                            }
                        }.frame(height: 56).opacity(model.hint == nil ? 1 : 0.35).accessibilityHidden(covered || model.hint != nil)
                        HStack(spacing: 18) {
                            progress(s)
                            HStack(spacing: 4) {
                                ForEach(0..<s.config.initialLives, id: \.self) { index in
                                    Image(systemName: "heart.fill").font(.system(size: 22, weight: .bold))
                                        .foregroundColor(index < s.lives ? CapyPalette.life : CapyPalette.orangeLight)
                                }
                            }.padding(.horizontal, 10).padding(.vertical, 5).background(CapyPalette.paper).clipShape(Capsule())
                                .accessibilityElement(children: .ignore).accessibilityLabel(language.text("Lives")).accessibilityValue("\(s.lives)").accessibilityIdentifier("lives")
                        }.frame(height: 40).opacity(model.hint == nil ? 1 : 0.35).accessibilityHidden(covered || model.hint != nil)
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
                            else { RuleStrip() }
                        }.frame(height: hintHeight).padding(.top, 8)
                        Spacer(minLength: 10)
                        PuzzleBoardView(puzzle: s.puzzle, found: s.found, marks: s.marks, errors: s.errors,
                                        sessionID: s.id, lives: s.lives,
                                        effectsEnabled: canPresentFeedback,
                                        preview: Set(model.hint?.cells ?? []), tutorialTargets: Set(model.tutorial?.targetCells ?? []),
                                        hideAccessibility: covered,
                                        locked: s.status != .playing || !canPresentFeedback || model.tutorial?.action == "read",
                                        onToggle: model.toggle, onSubmit: model.submit, onMark: model.mark,
                                        onBeginSwipe: model.beginSwipeFeedback,
                                        onEndSwipe: { model.endSwipeFeedback(cancelled: $0) },
                                        onInputActivityChange: { token, active in
                                            model.setBoardInputActivity(token, active: active, sessionID: s.id)
                                        })
                            .frame(width: boardSide, height: boardSide)
                        Spacer(minLength: 10)
                        if model.hint != nil {
                            CapyButton(id: "hint_apply", action: model.applyHint) { Text(language.text("Apply")).frame(maxWidth: .infinity) }
                                .buttonStyle(CapyButtonStyle()).frame(maxWidth: 280).accessibilityIdentifier("hint_apply").frame(height: 130)
                        } else if let tutorial = model.tutorial {
                            TutorialPanel(step: tutorial).padding(.top, 8)
                        } else {
                            VStack(spacing: 0) {
                                Group {
                                    if model.levelStartFreeVisible {
                                        CapyButton(id: "level_start_free", action: model.levelStartFree) {
                                            HStack(spacing: 6) {
                                                Image(systemName: "play.rectangle.fill")
                                                    .foregroundColor(model.levelStartFreeAvailable ? CapyPalette.video : CapyPalette.checkInSecondaryText)
                                                Text(language.text("Free tool")).font(.system(size: 13, weight: .bold, design: .rounded))
                                            }.padding(.horizontal, 16).frame(minHeight: 44)
                                        }.buttonStyle(CapyPressStyle(disabledOpacity: 1))
                                            .disabled(!model.levelStartFreeAvailable)
                                            .foregroundColor(model.levelStartFreeAvailable ? CapyPalette.ink : CapyPalette.checkInSecondaryText)
                                            .accessibilityIdentifier("level_start_free")
                                    } else { Color.clear.accessibilityHidden(true) }
                                }.frame(height: 44)
                                HStack(spacing: 68) {
                                    if model.directVisible {
                                        ToolButton(title: "Find a capy", isDirect: true, count: model.progress.availableDirect, id: "direct", action: model.direct)
                                            .disabled(!model.directEnabled)
                                    } else { Color.clear.frame(width: 62, height: 62).accessibilityHidden(true) }
                                    ToolButton(title: "Hint", isDirect: false, count: model.progress.availableHints, id: "hint", action: model.showHint)
                                        .disabled(!model.hintEnabled)
                                }.frame(height: 86)
                            }.disabled(s.status != .playing || model.sheet != nil || model.rewardBusy)
                        }
                        // Reserved in every state, so loading or hiding a banner never moves the board.
                        Color.clear.frame(height: model.tutorial == nil ? 44 : 12).accessibilityIdentifier("banner_reservation")
                    }.disabled(s.status != .playing).accessibilityElement(children: covered ? .ignore : .contain).accessibilityHidden(covered).padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 4)
                    if feedback.showLastLife && s.status == .playing && model.hint == nil && model.sheet == nil {
                        VStack {
                            Text(language.text("Only one chance left!"))
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .padding(.horizontal, 20).padding(.vertical, 14)
                                .background(CapyPalette.paper).clipShape(RoundedRectangle(cornerRadius: 16))
                                .shadow(color: .black.opacity(0.2), radius: 8)
                                .padding(.top, 142)
                            Spacer()
                        }.allowsHitTesting(false).transition(.opacity)
                    }
                }
                .onChange(of: s.combo) { combo in
                    feedback.setPresentationEnabled(canPresentFeedback)
                    feedback.combo(model.comboFeedbackPresentation(for: combo))
                }
                .onChange(of: s.lives) {
                    feedback.setPresentationEnabled(canPresentFeedback)
                    feedback.life($0)
                }
                .onChange(of: s.id) { _ in feedback.clear() }
                .onChange(of: canPresentFeedback) { feedback.setPresentationEnabled($0) }
                .onAppear { feedback.setPresentationEnabled(canPresentFeedback) }
                .onDisappear { feedback.setPresentationEnabled(false) }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: feedback.showLastLife)
                .accessibilityAddTraits(model.hint != nil ? .isModal : [])
            }
        }
    }

    private func progress(_ s: GameSession) -> some View {
        HStack(spacing: 3) {
            // Original image24 retains one animal slot through the 8x8 example;
            // the 10x10 example switches to the compact found/total display.
            if s.puzzle.size <= 8 {
                ForEach(0..<s.puzzle.size, id: \.self) { index in
                    CapyMascot(mood: .happy, size: 23).opacity(index < s.found.count ? 1 : 0.17)
                }
            } else {
                CapyMascot(mood: .happy, size: 27)
                (Text("\(s.found.count)").foregroundColor(CapyPalette.green) + Text("/\(s.puzzle.size)"))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
            }
        }.padding(.horizontal, 9).padding(.vertical, 4).background(CapyPalette.paper).clipShape(Capsule())
            .accessibilityElement(children: .ignore).accessibilityLabel(language.text(s.lives == 1 ? "One heart left. \(s.found.count) of \(s.puzzle.size) found" : "\(s.found.count) of \(s.puzzle.size) found")).accessibilityIdentifier("found_count")
            .overlay(alignment: .top) {
                if let combo = feedback.comboText {
                    Text(language.text(combo)).font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundColor(CapyPalette.orange)
                        .offset(y: -18).accessibilityIdentifier("combo_feedback")
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: feedback.comboText)
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
        }.buttonStyle(CapyPressStyle()).accessibilityLabel(language.text(title))
            .accessibilityValue(language.text(count > 0 ? "\(count) available" : "Video reward"))
            .accessibilityIdentifier(id)
    }
}

struct RuleStrip: View {
    @Environment(\.appLanguage) private var language
    var body: some View {
        HStack(spacing: 4) {
            rule(0, "1 Capy per\ncolor")
            rule(1, "1 Capy per\ncolumn and row")
            rule(2, "Capys cannot\ntouch")
        }.padding(6).background(CapyPalette.paper).clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine).accessibilityIdentifier("rule_strip")
    }
    private func rule(_ kind: Int, _ title: String) -> some View {
        HStack(spacing: 4) {
            RuleDiagram(kind: kind).frame(width: 30, height: 30)
            Text(language.text(title)).font(.system(size: 10, weight: .semibold, design: .rounded)).minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 3).padding(.vertical, 8)
            .background(CapyPalette.cream).clipShape(RoundedRectangle(cornerRadius: 6))
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
                    CapyButton(language.text("Skip"), id: "skip_tutorial", action: model.skipTutorial).buttonStyle(CapyPressStyle()).font(.system(size: 13, weight: .bold, design: .rounded)).frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("skip_tutorial")
                }
                Text(language.text(step.instruction)).font(.system(size: 12, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                if step.action == "read" {
                    CapyButton(language.text("Got it"), id: "tutorial_next", action: model.advanceTutorial).buttonStyle(CapyButtonStyle(compact: true)).accessibilityIdentifier("tutorial_next")
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
    let won: Bool
    @State private var praise = ["Nice Work", "Intelligent"].randomElement() ?? "Nice Work"
    private var failure: ReferenceFailureConfiguration? { model.session?.config.referenceGameplay?.failure }
    private var victoryDetail: String {
        guard let session = model.session else { return "All Capybaras found!" }
        if session.attempt == 1 { return "A solid victory on your very first attempt!" }
        if !session.hasRevived && session.lives == session.config.initialLives { return "No mistakes!" }
        return "All Capybaras found!"
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    Text(language.text(won ? praise : (failure?.title ?? "So Close!")))
                        .font(.system(size: 39, weight: .heavy, design: .rounded)).foregroundColor(.white)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .shadow(color: CapyPalette.orange, radius: 0, x: 1, y: 2)
                        .accessibilityIdentifier(won ? "win_result" : "loss_result")
                        .accessibilityAddTraits(.isHeader).capyFocus(won ? "win_result" : "loss_result")
                        .accessibilityValue(language.text("Level \(model.session?.puzzle.id ?? 1). Score \(model.session?.score ?? 0). \(model.session?.found.count ?? 0) of \(model.session?.puzzle.size ?? 0) found."))
                    ZStack {
                        if won { Image(systemName: "sun.max.fill").resizable().scaledToFit().foregroundColor(CapyPalette.orange.opacity(0.28)).padding(8) }
                        CapyMascot(mood: won ? .happy : .sad, size: min(geometry.size.width * 0.65, 250))
                    }.frame(height: min(geometry.size.height * 0.34, 270))
                    Text(language.text(won ? victoryDetail : "The next Capybara is close. Your progress is worth keeping!"))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(won ? Color(red: 1, green: 0.86, blue: 0.39) : CapyPalette.orangeLight)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    CapyButton(id: won ? "next_level" : "revive") {
                        if won { model.next() } else { model.revive() }
                    } label: {
                        Text(language.text(won ? "Level \((model.session?.puzzle.id ?? 1) + 1)" : (failure?.reviveButtonTitle ?? "Play On"))).frame(maxWidth: .infinity)
                    }.buttonStyle(CapyButtonStyle()).disabled(!won && !model.reviveAvailable).accessibilityIdentifier(won ? "next_level" : "revive")
                        .overlay(alignment: .topTrailing) {
                            if !won && model.reviveAvailable {
                                Group {
                                    if model.reviveNeedsVideo { Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)) }
                                    else { Text(language.text("Free")).font(.system(size: 15, weight: .heavy, design: .rounded)) }
                                }.foregroundColor(.white).padding(.horizontal, 15).padding(.vertical, 8)
                                    .background(CapyPalette.video).clipShape(Capsule()).offset(y: -12).allowsHitTesting(false)
                            }
                        }
                    if !won {
                        CapyButton(id: "result_restart", action: model.restart) { Text(language.text(failure?.restartButtonTitle ?? "Restart")).frame(maxWidth: .infinity) }
                            .buttonStyle(CapyButtonStyle(secondary: true, darkBackdrop: true)).accessibilityIdentifier("result_restart")
                    }
                }.padding(.horizontal, 40).padding(.vertical, 24)
                    .frame(maxWidth: 440).frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 52))
                }.padding(.top, 52)
                if won || failure?.canDismiss != false {
                    VStack {
                        HStack {
                            IconButton(symbol: "arrow.left", label: "Home", id: "result_home", action: model.home)
                            Spacer()
                        }
                        Spacer()
                    }.padding(.horizontal, 22).padding(.top, 4)
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
