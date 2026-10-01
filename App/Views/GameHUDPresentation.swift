import SwiftUI
import CapydokuCore

/// Short acknowledgements of committed state, never a second gameplay ledger.
@MainActor final class GameHUDPresentation: ObservableObject {
    struct LifeLoss: Identifiable {
        let id = UUID()
        let index: Int
    }
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    @Published private(set) var highlightedRules: Set<VisibleConflictKind> = []
    @Published private(set) var lifeLosses: [LifeLoss] = []
    private var sessionID: UUID?
    private var lastLives = 0
    private var generation = UUID()
    private var conflictToken = UUID()
    private var presentationEnabled = true
    private let schedule: Schedule

    init(schedule: @escaping Schedule = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: action))
    }) { self.schedule = schedule }

    func bind(sessionID: UUID, lives: Int) {
        clear(); self.sessionID = sessionID; lastLives = lives
    }

    func setPresentationEnabled(_ enabled: Bool) {
        presentationEnabled = enabled
        if !enabled { clear() }
    }

    func conflict(_ kinds: [VisibleConflictKind], sessionID: UUID, visible: Bool) {
        guard self.sessionID == sessionID else { return }
        conflictToken = UUID(); let token = conflictToken
        highlightedRules = visible && presentationEnabled ? Set(kinds) : []
        guard !highlightedRules.isEmpty else { return }
        schedule(0.9) { [weak self] in
            guard self?.conflictToken == token else { return }
            self?.highlightedRules = []
        }
    }

    func lifeChanged(_ lives: Int, sessionID: UUID, visible: Bool) {
        guard self.sessionID == sessionID else { bind(sessionID: sessionID, lives: lives); return }
        let before = lastLives; lastLives = lives
        // Restores, revives and hidden changes establish the new baseline only.
        guard visible, presentationEnabled, lives >= 0, before > lives, before <= 16 else { return }
        let token = generation
        let losses = (lives..<before).map { LifeLoss(index: $0) }
        let replaced = Set(losses.map(\.index))
        lifeLosses.removeAll { replaced.contains($0.index) }
        lifeLosses = Array((lifeLosses + losses).suffix(16))
        let ids = Set(losses.map(\.id))
        schedule(0.48) { [weak self] in
            guard self?.generation == token else { return }
            self?.lifeLosses.removeAll { ids.contains($0.id) }
        }
    }

    func clear() {
        generation = UUID(); conflictToken = UUID()
        highlightedRules = []; lifeLosses = []
    }
}

struct LifeHeartView: View {
    let available: Bool
    let size: CGFloat
    let lossID: UUID?
    let reduceMotion: Bool
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundColor(available ? CapyPalette.life : CapyPalette.orangeLight)
            .overlay {
                if let lossID {
                    LifeHeartLoss(size: size, reduceMotion: reduceMotion).id(lossID)
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct LifeHeartLoss: View {
    let size: CGFloat
    let reduceMotion: Bool
    @State private var released = false
    var body: some View {
        ZStack {
            if reduceMotion {
                Image(systemName: "heart.slash")
                    .font(.system(size: size, weight: .bold)).foregroundColor(CapyPalette.life)
            } else {
                ForEach(0..<2) { side in
                    Image(systemName: "heart.fill")
                        .font(.system(size: size, weight: .bold)).foregroundColor(CapyPalette.life)
                        .mask(GeometryReader { geometry in
                            Rectangle().frame(width: geometry.size.width / 2)
                                .offset(x: side == 0 ? 0 : geometry.size.width / 2)
                        })
                        .offset(x: released ? (side == 0 ? -6 : 6) : 0, y: released ? 7 : 0)
                        .rotationEffect(.degrees(released ? (side == 0 ? -16 : 16) : 0))
                        .opacity(released ? 0 : 1)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.42)) { released = true }
            }
    }
}
