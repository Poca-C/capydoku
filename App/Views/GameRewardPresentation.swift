import SwiftUI
import CapydokuCore

private struct CapyMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var capyMotionOverride: Bool? {
        get { self[CapyMotionOverrideKey.self] }
        set { self[CapyMotionOverrideKey.self] = newValue }
    }
}

/// Match the board's UIKit-window coordinates even across nested hosting views.
struct FeedbackWindowFrameReader: UIViewRepresentable {
    let onChange: (CGRect) -> Void
    func makeUIView(context: Context) -> FeedbackWindowFrameView { FeedbackWindowFrameView() }
    func updateUIView(_ view: FeedbackWindowFrameView, context: Context) {
        view.onChange = onChange
        view.reportFrame()
    }
}

final class FeedbackWindowFrameView: UIView {
    var onChange: ((CGRect) -> Void)?
    private var lastReported: CGRect?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false; accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); reportFrame() }
    override func didMoveToWindow() { super.didMoveToWindow(); lastReported = nil; reportFrame() }
    func reportFrame() {
        guard let window, !bounds.isEmpty else { return }
        let frame = convert(bounds, to: window)
        guard frame != lastReported else { return }
        lastReported = frame
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, self.lastReported == frame else { return }
            self.onChange?(frame)
        }
    }
}

/// Original [129, 252, 254]: visual acknowledgement follows an accepted move.
/// These short Demo timings are presentation only, never delayed game commits.
@MainActor final class GameRewardPresentation: ObservableObject {
    struct Flight: Identifiable {
        let id = UUID()
        let origin: CGPoint
        let destination: CGPoint
    }
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    @Published private(set) var flights: [Flight] = []
    @Published private(set) var progressPulse = false
    @Published private(set) var scoreDelta: Int?
    private var sessionID: UUID?
    private var lastScore = 0
    private var generation = UUID()
    private var scoreToken = UUID()
    private var pulseToken = UUID()
    private var acknowledged = Set<Int>()
    private let schedule: Schedule

    init(schedule: @escaping Schedule = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: action))
    }) { self.schedule = schedule }

    func bind(sessionID: UUID, score: Int) {
        guard self.sessionID != sessionID else { return }
        clear(); self.sessionID = sessionID; lastScore = score; acknowledged = []
    }

    func scoreChanged(_ score: Int, sessionID: UUID, visible: Bool) {
        guard self.sessionID == sessionID else { bind(sessionID: sessionID, score: score); return }
        let change = score - lastScore
        lastScore = score
        guard visible, change > 0 else { return }
        scoreToken = UUID(); let token = scoreToken
        scoreDelta = change
        schedule(0.75) { [weak self] in
            guard self?.scoreToken == token else { return }
            self?.scoreDelta = nil
        }
    }

    func found(index: Int, sessionID: UUID, origin: CGPoint, destination: CGPoint, reduceMotion: Bool) {
        guard self.sessionID == sessionID, acknowledged.insert(index).inserted else { return }
        let token = generation
        if reduceMotion {
            pulseProgress()
            return
        }
        let flight = Flight(origin: origin, destination: destination)
        flights = Array((flights + [flight]).suffix(4))
        schedule(0.44) { [weak self] in
            guard let self, self.generation == token,
                  self.flights.contains(where: { $0.id == flight.id }) else { return }
            self.pulseProgress()
        }
        schedule(0.58) { [weak self] in
            guard self?.generation == token else { return }
            self?.flights.removeAll { $0.id == flight.id }
        }
    }

    private func pulseProgress() {
        pulseToken = UUID(); let token = pulseToken
        progressPulse = true
        schedule(0.16) { [weak self] in
            guard self?.pulseToken == token else { return }
            self?.progressPulse = false
        }
    }

    func clear() {
        generation = UUID(); scoreToken = UUID(); pulseToken = UUID()
        flights = []; progressPulse = false; scoreDelta = nil
    }
}

/// Only result decoration waits for the last-cell feedback; next/revive actions
/// are available immediately and board input is already locked by Core.
/// Restored results, reduced motion and background transitions show immediately.
@MainActor final class ResultEntrancePresentation: ObservableObject {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    @Published private(set) var ready = true
    private var sessionID: UUID?
    private var status: GameStatus?
    private var token = UUID()
    private let schedule: Schedule
    init(schedule: @escaping Schedule = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: action))
    }) { self.schedule = schedule }

    func shows(sessionID: UUID, status: GameStatus, animate: Bool) -> Bool {
        guard status != .playing else { return false }
        if self.sessionID != sessionID || self.status == nil || !animate { return true }
        if self.status == .playing { return false }
        return ready
    }

    func update(sessionID: UUID?, status: GameStatus?, animate: Bool) {
        let freshResult = self.sessionID == sessionID && self.status == .playing && status != nil && status != .playing
        let changed = self.sessionID != sessionID || self.status != status
        self.sessionID = sessionID; self.status = status
        guard changed || !animate else { return }
        token = UUID(); let current = token
        ready = !(freshResult && animate)
        if !ready {
            schedule(status == .won ? 0.48 : 0.60) { [weak self] in
                guard self?.token == current else { return }
                self?.ready = true
            }
        }
    }
}

private struct ProgressStarPath: AnimatableModifier {
    var progress: CGFloat
    let origin: CGPoint
    let destination: CGPoint
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let t = progress, u = 1 - t
        let control = CGPoint(x: origin.x + (destination.x - origin.x) * 0.28,
                              y: min(origin.y, destination.y) - 30)
        let point = CGPoint(x: u * u * origin.x + 2 * u * t * control.x + t * t * destination.x,
                            y: u * u * origin.y + 2 * u * t * control.y + t * t * destination.y)
        content.scaleEffect(1 - t * 0.42).rotationEffect(.degrees(Double(t) * 110))
            .opacity(t > 0.94 ? Double((1 - t) / 0.06) : 1)
            .position(point)
    }
}

struct ProgressFlightStar: View {
    let flight: GameRewardPresentation.Flight
    @State private var progress: CGFloat = 0
    var body: some View {
        Image(systemName: "star.fill").font(.system(size: 22, weight: .black))
            .foregroundColor(CapyPalette.orange)
            .shadow(color: .white.opacity(0.9), radius: 2)
            .modifier(ProgressStarPath(progress: progress, origin: flight.origin, destination: flight.destination))
            .allowsHitTesting(false).accessibilityHidden(true)
            .onAppear { withAnimation(.easeInOut(duration: 0.44)) { progress = 1 } }
    }
}

struct VictorySparkles: View {
    @State private var expanded = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<12) { index in
                    let angle = Double(index) * .pi / 6
                    Image(systemName: index.isMultiple(of: 3) ? "sparkle" : "star.fill")
                        .font(.system(size: index.isMultiple(of: 2) ? 15 : 10, weight: .bold))
                        .foregroundColor(index.isMultiple(of: 2) ? CapyPalette.orange : CapyPalette.paper)
                        .offset(x: cos(angle) * geometry.size.width * (expanded ? 0.46 : 0.12),
                                y: sin(angle) * geometry.size.height * (expanded ? 0.47 : 0.12))
                        .scaleEffect(expanded ? 0.55 : 1)
                        .opacity(expanded ? 0 : 1)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.allowsHitTesting(false).accessibilityHidden(true)
            .onAppear { withAnimation(.easeOut(duration: 0.7)) { expanded = true } }
    }
}
