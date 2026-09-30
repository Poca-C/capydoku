import SwiftUI
import CapydokuCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hasCard: Bool { model.sheet == .settings || model.sheet == .reward }
    var body: some View {
        ZStack {
            CapyPalette.cream.ignoresSafeArea()
            Group {
                switch model.screen {
                case .home: HomeView()
                case .game: GameView()
                case .checkIn: CheckInView()
                }
            }
            .disabled(hasCard || model.loading || model.challengePending)
            .accessibilityHidden(hasCard || model.loading || model.challengePending)
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
                        Text("Loading…").font(.system(size: 22, weight: .bold, design: .rounded))
                    }.frame(maxWidth: .infinity).padding(16)
                }.frame(maxWidth: 310).padding(26)
            }
        }
        .foregroundColor(CapyPalette.ink)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hasCard)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.challengePending)
        .sheet(isPresented: Binding(get: { model.sheet == .debug }, set: { if !$0 && model.sheet == .debug { model.sheet = nil } })) { DebugView() }
        .alert("Capydoku", isPresented: Binding(get: { model.errorMessage != nil || model.notice != nil }, set: { if !$0 { model.errorMessage = nil; model.notice = nil } })) {
            Button("OK") { model.errorMessage = nil; model.notice = nil }
        } message: { Text(model.errorMessage ?? model.notice ?? "") }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
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
                            .tracking(-2).accessibilityLabel("Capydoku")
                    }
                    Spacer(minLength: 48)
                    VStack(spacing: 24) {
                        Button {} label: {
                            HStack(spacing: 12) {
                                Image(systemName: "lock.fill").font(.system(size: 24, weight: .bold))
                                Text("Daily Challenge").font(.system(size: 22, weight: .heavy, design: .rounded))
                            }.frame(maxWidth: .infinity).frame(height: 60)
                                .foregroundColor(.white).background(CapyPalette.disabled).clipShape(Capsule())
                        }.disabled(true).accessibilityIdentifier("daily_challenge").accessibilityHint("Not available in this build")
                        Button(action: model.startOrContinue) {
                            Text("Level \(model.session?.puzzle.id ?? model.progress.currentLevel)")
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
    let symbol: String; let label: String; let id: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 22, weight: .bold))
                .frame(width: 44, height: 44).background(CapyPalette.paper).clipShape(Circle())
                .shadow(color: CapyPalette.orange.opacity(0.15), radius: 1, y: 2)
        }.buttonStyle(CapyPressStyle()).accessibilityLabel(label).accessibilityIdentifier(id)
    }
}

struct GameView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLastLife = false
    @State private var comboFeedback: String?
    @State private var comboSequence = 0
    var body: some View {
        GeometryReader { geometry in
            if let s = model.session {
                let boardSide = max(190, min(geometry.size.width - 28, geometry.size.height - 420, 500))
                ZStack {
                    if model.hint != nil { Color.black.opacity(0.72).ignoresSafeArea() }
                    VStack(spacing: 0) {
                        HStack {
                            IconButton(symbol: "arrow.left", label: "Home", id: "home") {
                                if model.hint != nil { model.hint = nil } else { model.home() }
                            }
                            Spacer()
                            IconButton(symbol: model.hint == nil ? "gearshape.fill" : "xmark", label: model.hint == nil ? "Settings" : "Close hint", id: model.hint == nil ? "settings" : "hint_close") {
                                if model.hint != nil { model.hint = nil } else { model.sheet = .settings }
                            }
                        }.frame(height: 44).padding(.horizontal, 8)
                        HStack(spacing: 52) {
                            (Text("Level\n").font(.system(size: 17, weight: .medium, design: .rounded)) + Text("\(s.puzzle.id)").font(.system(size: 25, weight: .heavy, design: .rounded)))
                                .multilineTextAlignment(.center).accessibilityLabel("Level \(s.puzzle.id)").accessibilityIdentifier("level_title")
                            VStack(spacing: 0) {
                                Text("Score").font(.system(size: 17, weight: .medium, design: .rounded))
                                Text("\(s.score)").font(.system(size: 25, weight: .heavy, design: .rounded)).accessibilityIdentifier("score")
                            }
                        }.frame(height: 56).opacity(model.hint == nil ? 1 : 0.35)
                        HStack(spacing: 18) {
                            progress(s)
                            HStack(spacing: 4) {
                                ForEach(0..<s.config.initialLives, id: \.self) { index in
                                    Image(systemName: "heart.fill").font(.system(size: 22, weight: .bold))
                                        .foregroundColor(index < s.lives ? CapyPalette.life : CapyPalette.orangeLight)
                                }
                            }.padding(.horizontal, 10).padding(.vertical, 5).background(CapyPalette.paper).clipShape(Capsule())
                                .accessibilityElement(children: .ignore).accessibilityLabel("Lives").accessibilityValue("\(s.lives)").accessibilityIdentifier("lives")
                        }.frame(height: 40).opacity(model.hint == nil ? 1 : 0.35)
                        Group {
                            if let hint = model.hint { HintPanel(hint: hint).frame(height: 66, alignment: .bottom) }
                            else { RuleStrip() }
                        }.frame(height: 66).padding(.top, 8)
                        Spacer(minLength: 10)
                        PuzzleBoardView(puzzle: s.puzzle, found: s.found, marks: s.marks, errors: s.errors,
                                        preview: Set(model.hint?.cells ?? []), tutorialTargets: Set(model.tutorial?.targetCells ?? []),
                                        locked: s.status != .playing || model.hint != nil || model.sheet != nil || model.tutorial?.action == "read",
                                        onToggle: model.toggle, onSubmit: model.submit, onMark: model.mark)
                            .frame(width: boardSide, height: boardSide)
                        Spacer(minLength: 10)
                        if model.hint != nil {
                            Button(action: model.applyHint) { Text("Apply").frame(maxWidth: .infinity) }
                                .buttonStyle(CapyButtonStyle()).frame(maxWidth: 280).accessibilityIdentifier("hint_apply").frame(height: 130)
                        } else if let tutorial = model.tutorial {
                            TutorialPanel(step: tutorial).padding(.top, 8)
                        } else {
                            VStack(spacing: 0) {
                                Group {
                                    if model.levelStartFreeAvailable {
                                        Button(action: model.levelStartFree) {
                                            HStack(spacing: 6) {
                                                Image(systemName: "play.rectangle.fill").foregroundColor(CapyPalette.video)
                                                Text("Free tool").font(.system(size: 13, weight: .bold, design: .rounded))
                                            }.padding(.horizontal, 16).frame(minHeight: 44)
                                        }.buttonStyle(CapyPressStyle()).accessibilityIdentifier("level_start_free")
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
                    }.disabled(s.status != .playing).padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 4)
                    if s.status != .playing && model.sheet != .reward { ResultPanel(won: s.status == .won) }
                    if showLastLife && s.status == .playing && model.hint == nil && model.sheet == nil {
                        VStack {
                            Text("Only one chance left!")
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
                    comboSequence += 1
                    let sequence = comboSequence
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { comboFeedback = combo > 1 ? s.comboText : nil }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                        if comboSequence == sequence { withAnimation { comboFeedback = nil } }
                    }
                }
                .onChange(of: s.lives) { lives in
                    if lives == 1 {
                        withAnimation { showLastLife = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { withAnimation { showLastLife = false } }
                    } else { showLastLife = false }
                }
            }
        }
    }

    private func progress(_ s: GameSession) -> some View {
        HStack(spacing: 3) {
            if s.puzzle.size <= 6 {
                ForEach(0..<s.puzzle.size, id: \.self) { index in
                    CapyMascot(mood: .happy, size: 23).opacity(index < s.found.count ? 1 : 0.17)
                }
            } else {
                CapyMascot(mood: .happy, size: 27)
                (Text("\(s.found.count)").foregroundColor(CapyPalette.green) + Text("/\(s.puzzle.size)"))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
            }
        }.padding(.horizontal, 9).padding(.vertical, 4).background(CapyPalette.paper).clipShape(Capsule())
            .accessibilityElement(children: .ignore).accessibilityLabel(s.lives == 1 ? "One heart left. \(s.found.count) of \(s.puzzle.size) found" : "\(s.found.count) of \(s.puzzle.size) found").accessibilityIdentifier("found_count")
            .overlay(alignment: .top) {
                if let combo = comboFeedback { Text(combo).font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundColor(CapyPalette.orange).offset(y: -18) }
            }
    }
}

struct ToolButton: View {
    let title: String
    let isDirect: Bool
    let count: Int
    let id: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
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
        }.buttonStyle(CapyPressStyle()).accessibilityLabel(title)
            .accessibilityValue(count > 0 ? "\(count) available" : "Video reward")
            .accessibilityIdentifier(id)
    }
}

struct RuleStrip: View {
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
            Text(title).font(.system(size: 10, weight: .semibold, design: .rounded)).minimumScaleFactor(0.8)
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
    let step: TutorialStep
    var body: some View {
        CapyCard(padding: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(model.progress.tutorialStep + 1)/\(model.tutorialCount) · \(step.title)")
                        .font(.system(size: 14, weight: .bold, design: .rounded)).accessibilityIdentifier("tutorial_title")
                    Spacer()
                    Button("Skip", action: model.skipTutorial).font(.system(size: 13, weight: .bold, design: .rounded)).frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("skip_tutorial")
                }
                Text(step.instruction).font(.system(size: 12, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                if step.action == "read" {
                    Button("Got it", action: model.advanceTutorial).buttonStyle(CapyButtonStyle(compact: true)).accessibilityIdentifier("tutorial_next")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HintPanel: View {
    let hint: PuzzleHint
    var body: some View {
        Text(hint.explanation).font(.system(size: 13, weight: .semibold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17).padding(.vertical, 11)
            .background(CapyPalette.paper).clipShape(RoundedRectangle(cornerRadius: 17))
            .accessibilityLabel("Hint. \(hint.rule). \(hint.explanation)")
    }
}

struct ResultPanel: View {
    @EnvironmentObject private var model: AppModel
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
                Color.black.opacity(0.78).ignoresSafeArea()
                VStack(spacing: 20) {
                    Text(won ? praise : (failure?.title ?? "So Close!"))
                        .font(.system(size: 39, weight: .heavy, design: .rounded)).foregroundColor(.white)
                        .shadow(color: CapyPalette.orange, radius: 0, x: 1, y: 2)
                        .accessibilityIdentifier(won ? "win_result" : "loss_result")
                    ZStack {
                        if won { Image(systemName: "sun.max.fill").resizable().scaledToFit().foregroundColor(CapyPalette.orange.opacity(0.28)).padding(8) }
                        CapyMascot(mood: won ? .happy : .sad, size: min(geometry.size.width * 0.65, 250))
                    }.frame(height: min(geometry.size.height * 0.34, 270))
                    Text(won ? victoryDetail : "The next Capybara is close. Your progress is worth keeping!")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(won ? Color(red: 1, green: 0.86, blue: 0.39) : CapyPalette.orangeLight)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button {
                        if won { model.next() } else { model.revive() }
                    } label: {
                        Text(won ? "Level \((model.session?.puzzle.id ?? 1) + 1)" : (failure?.reviveButtonTitle ?? "Play On")).frame(maxWidth: .infinity)
                    }.buttonStyle(CapyButtonStyle()).disabled(!won && !model.reviveAvailable).accessibilityIdentifier(won ? "next_level" : "revive")
                        .overlay(alignment: .topTrailing) {
                            if !won && model.reviveAvailable {
                                Group {
                                    if model.reviveNeedsVideo { Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)) }
                                    else { Text("Free").font(.system(size: 15, weight: .heavy, design: .rounded)) }
                                }.foregroundColor(.white).padding(.horizontal, 15).padding(.vertical, 8)
                                    .background(CapyPalette.video).clipShape(Capsule()).offset(y: -12).allowsHitTesting(false)
                            }
                        }
                    if !won {
                        Button(action: model.restart) { Text(failure?.restartButtonTitle ?? "Restart").frame(maxWidth: .infinity) }
                            .buttonStyle(CapyButtonStyle(secondary: true)).accessibilityIdentifier("result_restart")
                    }
                }.padding(.horizontal, 40).frame(maxWidth: 440).frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @AccessibilityFocusState private var headingFocused: Bool
    var body: some View {
        CapyCard(padding: 24) {
            VStack(spacing: 22) {
                Text("A New Challenge!").font(.system(size: 29, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused).accessibilityIdentifier("challenge_title")
                CapyMascot(mood: .happy, size: 160)
                Button(action: model.continueChallenge) { Text("Continue").frame(maxWidth: .infinity) }
                    .buttonStyle(CapyButtonStyle()).accessibilityIdentifier("challenge_continue")
            }
        }.frame(maxWidth: 350).padding(.horizontal, 24)
            .accessibilityAddTraits(.isModal).onAppear { headingFocused = true }
    }
}
