import SwiftUI
import UIKit
import CapydokuCore

/// Presentation follows the persisted claim; this object never grants rewards.
/// A freshly mounted/restored page only binds a baseline and cannot replay it.
@MainActor final class CheckInChoreography: ObservableObject {
    enum Phase: Int { case idle, illuminating, streak, reward, settled }
    struct Snapshot: Equatable {
        let day: Int?
        let cycleDay: Int
        let streak: Int
        let hints: Int
        let direct: Int
        init(_ progress: PlayerProgress) {
            day = progress.checkIn.lastClaimedDay
            cycleDay = progress.checkIn.cycleDay; streak = progress.checkIn.streak
            hints = progress.bonusHints; direct = progress.bonusDirect
        }
    }
    struct Receipt: Equatable {
        let day: Int
        let cycleDay: Int
        let hints: Int
        let direct: Int
    }
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var animationID: UUID?
    @Published private(set) var receipt: Receipt?
    private var snapshot: Snapshot?
    private var generation = UUID()
    private let schedule: Schedule
    init(schedule: @escaping Schedule = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: action))
    }) { self.schedule = schedule }

    func bind(_ current: Snapshot) {
        cancel(); snapshot = current; receipt = nil; phase = .idle
    }
    func observe(_ current: Snapshot, visible: Bool, animated: Bool) {
        guard let previous = snapshot else { bind(current); return }
        snapshot = current
        guard let day = current.day, day != previous.day,
              previous.day == nil || day > previous.day!, current.streak > 0 else { return }
        cancel()
        guard visible else { receipt = nil; phase = .idle; return }
        receipt = Receipt(day: day, cycleDay: current.cycleDay,
                          hints: max(0, current.hints - previous.hints),
                          direct: max(0, current.direct - previous.direct))
        guard animated else { phase = .settled; return }
        let token = UUID(); generation = token; animationID = token; phase = .illuminating
        advance(.streak, after: 0.24, token: token)
        advance(.reward, after: 0.52, token: token)
        advance(.settled, after: 1.12, token: token)
    }
    /// Cancelled effects settle; resuming never replays an old claim.
    func cancel() {
        generation = UUID(); animationID = nil
        phase = receipt == nil ? .idle : .settled
    }
    func unbind() { cancel(); snapshot = nil; receipt = nil; phase = .idle }
    private func advance(_ next: Phase, after delay: TimeInterval, token: UUID) {
        schedule(delay) { [weak self] in
            guard let self, self.generation == token else { return }
            self.phase = next
            if next == .settled { self.animationID = nil }
        }
    }
}

/// Existing original artwork goes from a muted reward plaque to warm colour.
/// Decorative layers never own input or replace the readable seven-day row.
struct CheckInRewardArtwork: View {
    let claimable: Bool
    let phase: CheckInChoreography.Phase
    let animationID: UUID?
    let animated: Bool
    var body: some View {
        ZStack {
            if let animationID {
                CheckInLightBurst().id(animationID).allowsHitTesting(false)
            }
            Group {
                if let art = UIImage(named: "CapyCheckIn") {
                    Image(uiImage: art).resizable().scaledToFit()
                } else {
                    CapyMascot(mood: .happy, size: 170)
                }
            }
            .saturation(claimable ? 0.08 : 1)
            .brightness(claimable ? -0.22 : 0)
            .scaleEffect(phase == .illuminating ? 1.035 : 1)
            .rotationEffect(.degrees(phase == .illuminating ? -2 : 0))
            .animation(animated ? .easeOut(duration: 0.24) : nil, value: claimable)
            .animation(animated ? .spring(response: 0.28, dampingFraction: 0.55) : nil, value: phase)
        }.accessibilityHidden(true)
    }
}

/// One bounded drawing pass sequence, with a warm centre, expanding halo and
/// two depths of sparkles. Removal on interruption cancels the whole subtree.
private struct CheckInLightBurst: View {
    @State private var progress: CGFloat = 0
    var body: some View {
        CheckInLightParticles(progress: progress)
            .onAppear { withAnimation(.linear(duration: 1.05)) { progress = 1 } }
            .accessibilityHidden(true)
    }
}
private struct CheckInLightParticles: View, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height * 0.54)
            let extent = min(size.width, size.height)
            let glow = CGRect(x: centre.x - extent * 0.58, y: centre.y - extent * 0.58,
                              width: extent * 1.16, height: extent * 1.16)
            context.opacity = Double(min(1, (1 - progress) * 2))
            context.fill(Path(ellipseIn: glow), with: .radialGradient(
                Gradient(colors: [Color.yellow.opacity(0.7), CapyPalette.orangeLight.opacity(0.42), .clear]),
                center: centre, startRadius: 0, endRadius: extent * 0.58))
            let radius = extent * (0.18 + progress * 0.40)
            context.opacity = Double(max(0, 1 - progress * 1.35))
            context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                 width: radius * 2, height: radius * 2)),
                           with: .color(CapyPalette.orangeLight), lineWidth: 2)
            for index in 0..<18 {
                let near = index.isMultiple(of: 2)
                let angle = CGFloat(index) * .pi * 2 / 18
                let distance = extent * (0.20 + progress * (near ? 0.41 : 0.28))
                let point = CGPoint(x: centre.x + cos(angle) * distance,
                                    y: centre.y + sin(angle) * distance + progress * progress * 14)
                context.opacity = Double(max(0, 1 - progress))
                context.draw(Text(near ? "✦" : "●")
                    .font(.system(size: near ? 16 : 5, weight: .bold))
                    .foregroundColor(near ? CapyPalette.orange : Color.yellow), at: point)
            }
        }
    }
}

/// A page can be recreated repeatedly while the same app model is alive. Keep
/// only the ready-gift acknowledgement across those mounts, with weak ownership
/// so neither tests nor abandoned models leave retained application state.
@MainActor enum CheckInGiftCueMemory {
    private final class Entry {
        weak var owner: AnyObject?
        var day: Int
        init(owner: AnyObject, day: Int) { self.owner = owner; self.day = day }
    }
    private static var entries: [ObjectIdentifier: Entry] = [:]
    static func consume(owner: AnyObject, day: Int) -> Bool {
        entries = entries.filter { $0.value.owner != nil }
        let key = ObjectIdentifier(owner)
        if let entry = entries[key], day <= entry.day { return false }
        entries[key] = Entry(owner: owner, day: day)
        return true
    }
}
