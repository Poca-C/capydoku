import SwiftUI
import CapydokuCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ZStack {
            CapyPalette.cream.ignoresSafeArea()
            switch model.screen {
            case .home: HomeView()
            case .game: GameView()
            case .checkIn: CheckInView()
            }
            if model.loading {
                Color.black.opacity(0.15).ignoresSafeArea()
                CapyCard {
                    VStack(spacing: 14) {
                        ProgressView().tint(CapyPalette.orange)
                        Text("Growing a new puzzle…").font(.headline)
                        Text("Checking every rule and its unique solution.")
                            .font(.caption).foregroundColor(CapyPalette.muted)
                    }.padding(12)
                }.padding(28)
            }
        }
        .foregroundColor(CapyPalette.ink)
        .sheet(item: $model.sheet) { item in
            switch item {
            case .settings: SettingsView()
            case .debug: DebugView()
            case .reward: RewardView()
            }
        }
        .alert("Capydoku", isPresented: Binding(get: { model.errorMessage != nil || model.notice != nil }, set: { if !$0 { model.errorMessage = nil; model.notice = nil } })) {
            Button("OK") { model.errorMessage = nil; model.notice = nil }
        } message: { Text(model.errorMessage ?? model.notice ?? "") }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 26) {
                    HStack {
                        Text("A LITTLE LOGIC. A LOT OF CALM.")
                            .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.3)
                        Spacer()
                        IconButton(symbol: "gearshape", label: "Settings", id: "settings") { model.sheet = .settings }
                    }
                    VStack(spacing: 0) {
                        ZStack {
                            Circle().fill(CapyPalette.orangeLight.opacity(0.55)).frame(width: 210, height: 210)
                            Circle().stroke(CapyPalette.line, style: StrokeStyle(lineWidth: 1, dash: [3, 7])).frame(width: 244, height: 244)
                            CapyMascot(mood: .happy, size: 208)
                            Image(systemName: "sparkle").font(.title2).foregroundColor(CapyPalette.orange).offset(x: 100, y: -68)
                            Image(systemName: "leaf.fill").foregroundColor(CapyPalette.green).rotationEffect(.degrees(-25)).offset(x: -106, y: 65)
                        }.frame(height: 254)
                        Text("capydoku").font(.system(size: 48, weight: .heavy, design: .rounded)).tracking(-2)
                        Text("Find your quiet little moment.").font(.system(size: 16, design: .rounded)).foregroundColor(CapyPalette.muted).padding(.top, 8)
                    }
                    CapyCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("YOUR LITTLE JOURNEY").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.6).foregroundColor(CapyPalette.muted)
                                    Text("Level \(model.session?.puzzle.id ?? model.progress.currentLevel)").font(.system(size: 28, weight: .bold, design: .rounded))
                                }
                                Spacer()
                                Text("\(model.progress.completedLevels.count)\nsolved").multilineTextAlignment(.trailing).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(CapyPalette.green).fixedSize()
                            }
                            Button(action: model.startOrContinue) {
                                HStack { Text(model.session == nil ? "Let's play" : "Continue playing"); Spacer(); Image(systemName: "arrow.right") }.frame(maxWidth: .infinity)
                            }.buttonStyle(CapyButtonStyle()).accessibilityIdentifier("play")
                        }
                    }
                    Button { model.screen = .checkIn } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "gift.fill").font(.title2).foregroundColor(CapyPalette.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("A daily little treat").font(.system(size: 16, weight: .bold, design: .rounded))
                                Text(model.progress.checkIn.canClaim(on: model.now) ? "Your check-in reward is ready" : "All claimed. See you tomorrow!").font(.caption).foregroundColor(CapyPalette.muted)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption.bold())
                        }.padding(.horizontal, 10)
                    }.buttonStyle(.plain).accessibilityIdentifier("check_in")
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        Image(systemName: "leaf")
                        Text("INTERNAL DEMO · 150 PUZZLES + LOCAL LAB")
                    }.font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(CapyPalette.muted)
                }
                .padding(.horizontal, 26).padding(.top, 10).padding(.bottom, 20)
                .frame(minHeight: geometry.size.height)
            }
        }
    }
}

struct IconButton: View {
    let symbol: String; let label: String; let id: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44).background(CapyPalette.paper).clipShape(Circle()) }
            .buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }
}

struct GameView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmRestart = false
    var body: some View {
        GeometryReader { geometry in
            if let s = model.session {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            IconButton(symbol: "chevron.left", label: "Home", id: "home", action: model.home)
                            Spacer()
                            VStack(spacing: 3) {
                                Text("Level \(s.puzzle.id)").font(.system(size: 22, weight: .bold, design: .rounded)).accessibilityIdentifier("level_title")
                                Text(s.puzzle.id > 150 ? "LOCAL GENERATION LAB" : s.puzzle.difficulty.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.5).foregroundColor(CapyPalette.muted)
                            }
                            Spacer()
                            IconButton(symbol: "gearshape", label: "Settings", id: "settings") { model.sheet = .settings }
                        }
                        HStack {
                            HStack(spacing: 5) { ForEach(0..<s.config.initialLives, id: \.self) { index in
                                Image(systemName: index < s.lives ? "heart.fill" : "heart").foregroundColor(index < s.lives ? CapyPalette.orange : CapyPalette.line)
                            } }.accessibilityElement(children: .ignore).accessibilityLabel("Lives").accessibilityValue("\(s.lives)").accessibilityIdentifier("lives")
                            Spacer()
                            Text("\(s.score)").font(.system(size: 23, weight: .bold, design: .rounded)).accessibilityIdentifier("score")
                            Text("PTS").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(CapyPalette.muted)
                        }.padding(.horizontal, 6)
                        HStack(spacing: 12) {
                            CapyMascot(mood: s.status == .lost ? .sad : s.combo > 1 ? .happy : .neutral, size: 54)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.comboText.map { "\($0)!" } ?? "A place for every capy.").font(.system(size: 16, weight: .bold, design: .rounded))
                                Text(s.lives == 1 && s.status == .playing ? "One heart left · take your time" : "\(s.found.count) of \(s.puzzle.size) found · take your time").font(.caption).foregroundColor(s.lives == 1 ? CapyPalette.orange : CapyPalette.muted).accessibilityIdentifier("found_count")
                            }
                            Spacer()
                        }
                        PuzzleBoardView(puzzle: s.puzzle, found: s.found, marks: s.marks, errors: s.errors,
                                        preview: Set(model.hint?.cells ?? []), tutorialTargets: Set(model.tutorial?.targetCells ?? []),
                                        locked: s.status != .playing || model.hint != nil || model.tutorial?.action == "read",
                                        onToggle: model.toggle, onSubmit: model.submit, onMark: model.mark)
                            .frame(width: min(geometry.size.width - 36, 500), height: min(geometry.size.width - 36, 500))
                        if let hint = model.hint { HintPanel(hint: hint) }
                        else if s.status != .playing { ResultPanel(won: s.status == .won) }
                        else if let tutorial = model.tutorial { TutorialPanel(step: tutorial) }
                        else {
                            HStack(spacing: 12) {
                                tool("Find a capy", symbol: "sparkles", count: model.progress.availableDirect, id: "direct", action: model.direct)
                                tool("Hint", symbol: "lightbulb", count: model.progress.availableHints, id: "hint", action: model.showHint)
                            }
                            HStack(spacing: 6) {
                                Image(systemName: "hand.tap"); Text("Tap to mark · double-tap to find · swipe to mark")
                            }.font(.system(size: 10, design: .rounded)).foregroundColor(CapyPalette.muted)
                            HStack {
                                Button { confirmRestart = true } label: { Label("Restart", systemImage: "arrow.counterclockwise") }.accessibilityIdentifier("restart")
                                Spacer()
                                #if DEBUG
                                Button { model.sheet = .debug } label: { Label("Developer", systemImage: "wrench.and.screwdriver") }.accessibilityIdentifier("debug")
                                #endif
                            }.font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(CapyPalette.muted).padding(.horizontal, 8)
                        }
                        if model.tutorial == nil { RuleStrip() }
                    }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 22).frame(maxWidth: 540)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .alert("Restart this puzzle?", isPresented: $confirmRestart) {
            Button("Keep playing", role: .cancel) {}
            Button("Restart", role: .destructive, action: model.restart)
        } message: { Text("The board and score reset. Used tools stay used.") }
    }

    private func tool(_ title: String, symbol: String, count: Int, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(count > 0 ? "\(count) available" : "Simulated reward").font(.system(size: 10, design: .rounded)).foregroundColor(CapyPalette.muted)
                }
                Spacer(minLength: 0)
            }.padding(16).frame(maxWidth: .infinity).background(CapyPalette.paper).clipShape(RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(CapyPalette.line, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

struct RuleStrip: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rule("rectangle.split.1x2", "1 per row")
            rule("rectangle.split.2x1", "1 per column")
            rule("square.dashed", "1 per region")
            rule("arrow.up.left.and.arrow.down.right", "No touching")
        }.padding(.vertical, 10).background(CapyPalette.paper.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
    private func rule(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 5) { Image(systemName: icon).font(.system(size: 15)); Text(title).font(.system(size: 9, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7) }.foregroundColor(CapyPalette.muted).frame(maxWidth: .infinity)
    }
}

struct TutorialPanel: View {
    @EnvironmentObject private var model: AppModel
    let step: TutorialStep
    var body: some View {
        CapyCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(model.progress.tutorialStep + 1)/\(model.tutorialCount) · \(step.title)").font(.system(size: 16, weight: .bold, design: .rounded)).accessibilityIdentifier("tutorial_title")
                    Spacer()
                    Button("Skip", action: model.skipTutorial).font(.caption).foregroundColor(CapyPalette.muted).accessibilityIdentifier("skip_tutorial")
                }
                Text(step.instruction).font(.system(size: 13, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                if step.action == "read" {
                    Button("Got it", action: model.advanceTutorial).buttonStyle(CapyButtonStyle(compact: true)).accessibilityIdentifier("tutorial_next")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HintPanel: View {
    @EnvironmentObject private var model: AppModel
    let hint: PuzzleHint
    var body: some View {
        CapyCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(hint.rule).font(.system(size: 17, weight: .bold, design: .rounded))
                Text(hint.explanation).font(.system(size: 13, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                Text("PREVIEW · The board changes only when you apply.").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(CapyPalette.muted)
                HStack {
                    Button("Close") { model.hint = nil }.buttonStyle(CapyButtonStyle(secondary: true, compact: true)).accessibilityIdentifier("hint_close")
                    Spacer()
                    Button("Apply marks", action: model.applyHint).buttonStyle(CapyButtonStyle(compact: true)).accessibilityIdentifier("hint_apply")
                }
            }
        }
    }
}

struct ResultPanel: View {
    @EnvironmentObject private var model: AppModel
    let won: Bool
    var body: some View {
        CapyCard(padding: 18) {
            VStack(spacing: 12) {
                Text(won ? "Everyone found their place!" : "A little pause. Try again?").font(.system(size: 19, weight: .bold, design: .rounded)).accessibilityIdentifier(won ? "win_result" : "loss_result")
                Text(won ? "Lovely thinking. Another quiet puzzle awaits." : "Revive to keep your capybaras and marks.").font(.caption).foregroundColor(CapyPalette.muted)
                Button(won ? "Next puzzle" : "Revive · simulated reward") { if won { model.next() } else { model.offer(.revive) } }
                    .buttonStyle(CapyButtonStyle()).accessibilityIdentifier(won ? "next_level" : "revive")
                Button("Play this puzzle again", action: model.restart).font(.caption).foregroundColor(CapyPalette.muted).accessibilityIdentifier("result_restart")
            }.frame(maxWidth: .infinity)
        }
    }
}
