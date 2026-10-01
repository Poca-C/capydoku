import SwiftUI
import UIKit
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
        let diameter: CGFloat
        private let columnRoute: ColumnRoute?

        init(origin: CGPoint, destination: CGPoint, sourceCell: CGRect? = nil, boardFrame: CGRect? = nil) {
            self.destination = destination
            if let cell = sourceCell, !cell.isEmpty,
               [cell.minX, cell.minY, cell.width, cell.height].allSatisfy(\.isFinite) {
                diameter = max(8, min(14, cell.width * 0.28))
                let side: CGFloat = destination.x < cell.midX ? -1 : 1
                // The full rotating star and a small glow clear the source
                // before flight begins, so the new happy face stays readable.
                self.origin = CGPoint(x: cell.midX + side * cell.width * 0.18,
                                      y: cell.minY - diameter * sqrt(2) / 2 - 3)
            } else {
                self.origin = origin; diameter = 14
            }
            if let cell = sourceCell, let board = boardFrame {
                columnRoute = ColumnRoute(origin: self.origin, destination: destination,
                                          source: cell, board: board, diameter: diameter)
            } else { columnRoute = nil }
        }

        func position(at progress: CGFloat) -> CGPoint {
            if let columnRoute { return columnRoute.position(at: progress) }
            let t = min(1, max(0, progress)), u = 1 - t
            let control = CGPoint(x: origin.x + (destination.x - origin.x) * 0.28,
                                  y: min(origin.y, destination.y) - 30)
            return CGPoint(x: u * u * origin.x + 2 * u * t * control.x + t * t * destination.x,
                           y: u * u * origin.y + 2 * u * t * control.y + t * t * destination.y)
        }

        /// One character per column makes this corridor safe for both current
        /// and later finds. It uses layout only, never hidden solution cells.
        private struct ColumnRoute {
            let points: [CGPoint]
            let distances: [CGFloat]

            init?(origin: CGPoint, destination: CGPoint, source: CGRect, board: CGRect, diameter: CGFloat) {
                guard [origin.x, origin.y, destination.x, destination.y,
                       source.minX, source.minY, source.width, source.height,
                       board.minX, board.minY, board.width, board.height].allSatisfy(\.isFinite),
                      !source.isEmpty, !board.isEmpty, board.insetBy(dx: -0.001, dy: -0.001).contains(source) else { return nil }
                let radius = diameter * sqrt(2) / 2
                let exit = CGPoint(x: source.midX, y: board.minY - radius - 3 - max(8, source.width * 0.28))
                let rise = origin.y - exit.y, headroom = exit.y - destination.y
                guard rise > 0, headroom > 0 else { return nil }
                let first = [origin, CGPoint(x: origin.x, y: origin.y - rise * 0.35),
                             CGPoint(x: source.midX, y: exit.y + rise * 0.35), exit]
                let second = [exit, CGPoint(x: source.midX, y: exit.y - min(36, headroom * 0.42)),
                              CGPoint(x: destination.x, y: destination.y + min(18, headroom * 0.25)), destination]
                func point(_ control: [CGPoint], _ t: CGFloat) -> CGPoint {
                    let u = 1 - t
                    return CGPoint(x: u*u*u*control[0].x + 3*u*u*t*control[1].x + 3*u*t*t*control[2].x + t*t*t*control[3].x,
                                   y: u*u*u*control[0].y + 3*u*u*t*control[1].y + 3*u*t*t*control[2].y + t*t*t*control[3].y)
                }
                let path = (0...32).map { point(first, CGFloat($0) / 32) }
                    + (1...32).map { point(second, CGFloat($0) / 32) }
                var lengths: [CGFloat] = [0]
                for index in 1..<path.count {
                    lengths.append(lengths[index - 1] + hypot(path[index].x - path[index - 1].x,
                                                               path[index].y - path[index - 1].y))
                }
                guard let length = lengths.last, length.isFinite, length > 0 else { return nil }
                points = path; distances = lengths
            }

            func position(at progress: CGFloat) -> CGPoint {
                let t = min(1, max(0, progress))
                if t == 0 { return points[0] }
                if t == 1 { return points[points.count - 1] }
                let target = t * distances[distances.count - 1]
                var lower = 1, upper = distances.count - 1
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if distances[middle] < target { lower = middle + 1 } else { upper = middle }
                }
                let before = points[lower - 1], after = points[lower]
                let span = distances[lower] - distances[lower - 1]
                let fraction = span > 0 ? (target - distances[lower - 1]) / span : 0
                // Arc-length interpolation keeps the two tangent-continuous
                // curves from pausing or jumping at their shared exit point.
                return CGPoint(x: before.x + (after.x - before.x) * fraction,
                               y: before.y + (after.y - before.y) * fraction)
            }
        }
    }
    struct LocalScore: Identifiable {
        let id = UUID()
        let amount: Int
        let placement: CellScorePlacement
        var origin: CGPoint { placement.center }
        let reduceMotion: Bool
    }
    struct ToolReveal: Identifiable {
        let id: UUID
        let origin: CGPoint
        let destination: CGPoint
        let reduceMotion: Bool
    }
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    @Published private(set) var flights: [Flight] = []
    @Published private(set) var progressPulse = false
    @Published private(set) var progressArrivalID: UUID?
    @Published private(set) var applauseID: UUID?
    @Published private(set) var scoreDelta: Int?
    /// Reuses the score expiry token so equal, consecutive awards still have
    /// distinct presentation identities without adding a gameplay event stream.
    @Published private(set) var scorePulseID: UUID?
    @Published private(set) var localScores: [LocalScore] = []
    @Published private(set) var toolReveal: ToolReveal?
    private var sessionID: UUID?
    private var lastScore = 0
    private var generation = UUID()
    private var scoreToken = UUID()
    private var pulseToken = UUID()
    private var acknowledged = Set<Int>()
    private var acknowledgedTools = Set<UUID>()
    private var presentationEnabled = true
    private let schedule: Schedule

    init(schedule: @escaping Schedule = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: action))
    }) { self.schedule = schedule }

    func bind(sessionID: UUID, score: Int) {
        guard self.sessionID != sessionID else { return }
        clear(); self.sessionID = sessionID; lastScore = score; acknowledged = []; acknowledgedTools = []
    }

    func setPresentationEnabled(_ enabled: Bool) {
        presentationEnabled = enabled
        if !enabled { clear() }
    }

    func scoreChanged(_ score: Int, sessionID: UUID, visible: Bool) {
        guard self.sessionID == sessionID else { bind(sessionID: sessionID, score: score); return }
        let change = score - lastScore
        lastScore = score
        guard visible, presentationEnabled, change > 0 else { return }
        scoreToken = UUID(); let token = scoreToken
        scoreDelta = change
        scorePulseID = token
        schedule(0.75) { [weak self] in
            guard self?.scoreToken == token else { return }
            self?.scoreDelta = nil
            self?.scorePulseID = nil
        }
    }

    func found(index: Int, sessionID: UUID, origin: CGPoint, destination: CGPoint, sourceCell: CGRect? = nil, boardFrame: CGRect? = nil, reduceMotion: Bool) {
        guard self.sessionID == sessionID, acknowledged.insert(index).inserted, presentationEnabled else { return }
        let token = generation
        let event = UUID(); applauseID = event
        schedule(0.75) { [weak self] in
            guard self?.generation == token, self?.applauseID == event else { return }
            self?.applauseID = nil
        }
        if reduceMotion {
            pulseProgress()
            return
        }
        let flight = Flight(origin: origin, destination: destination, sourceCell: sourceCell, boardFrame: boardFrame)
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

    /// The board supplies its committed positive delta once, even if UIKit
    /// coalesces several accepted moves into a single render transaction.
    func scoreAward(_ amount: Int, sessionID: UUID, placement: CellScorePlacement, reduceMotion: Bool) {
        guard self.sessionID == sessionID, presentationEnabled, amount > 0,
              placement.center.x.isFinite, placement.center.y.isFinite else { return }
        let token = generation
        let item = LocalScore(amount: amount, placement: placement, reduceMotion: reduceMotion)
        // A fresh award stays tied to its source instead of moving farther
        // away to make room for old text. Retire only conflicting decoration;
        // each remaining item keeps its UUID and original expiry deadline.
        let retained = localScores.filter { !$0.placement.sweptFrame.intersects(placement.sweptFrame) }
        localScores = Array((retained + [item]).suffix(4))
        schedule(0.72) { [weak self] in
            guard self?.generation == token else { return }
            self?.localScores.removeAll { $0.id == item.id }
        }
    }

    /// A newer accepted character takes priority over an earlier floating badge.
    /// Keep unrelated badges and their original independent expiry deadlines.
    func retireScores(overlapping frames: [CGRect], sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        localScores.removeAll { item in frames.contains { $0.intersects(item.placement.sweptFrame) } }
    }

    func directReveal(_ event: DirectRevealFeedback, origin: CGPoint, destination: CGPoint, reduceMotion: Bool) {
        guard sessionID == event.sessionID, acknowledgedTools.insert(event.id).inserted,
              presentationEnabled, [origin.x, origin.y, destination.x, destination.y].allSatisfy(\.isFinite) else { return }
        let token = generation
        toolReveal = ToolReveal(id: event.id, origin: origin, destination: destination, reduceMotion: reduceMotion)
        schedule(0.52) { [weak self] in
            guard self?.generation == token, self?.toolReveal?.id == event.id else { return }
            self?.toolReveal = nil
        }
    }

    private func pulseProgress() {
        pulseToken = UUID(); let token = pulseToken
        progressArrivalID = token
        progressPulse = true
        schedule(0.16) { [weak self] in
            guard self?.pulseToken == token else { return }
            self?.progressPulse = false
        }
    }

    func clear() {
        generation = UUID(); scoreToken = UUID(); pulseToken = UUID()
        flights = []; progressPulse = false; progressArrivalID = nil; applauseID = nil
        scoreDelta = nil; scorePulseID = nil; localScores = []; toolReveal = nil
    }
}

/// Only result decoration waits for the last-cell feedback; next/revive actions
/// are available immediately and board input is already locked by Core.
/// Restored results, reduced motion and background transitions show immediately.
@MainActor final class ResultEntrancePresentation: ObservableObject {
    enum Stage: Int, Comparable {
        case board, character, title, detail, settled
        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    @Published private(set) var ready = true
    @Published private(set) var animationID: UUID?
    @Published private(set) var stage = Stage.settled
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
        animationID = nil
        ready = !(freshResult && animate)
        stage = ready ? .settled : .board
        if !ready {
            let characterDelay = status == .won ? 0.82 : 0.60
            schedule(characterDelay) { [weak self] in
                guard self?.token == current else { return }
                self?.ready = true
                self?.animationID = UUID()
                self?.stage = .character
            }
            for (delay, stage) in [(0.16, Stage.title), (0.32, Stage.detail), (0.50, Stage.settled)] {
                schedule(characterDelay + delay) { [weak self] in
                    guard self?.token == current else { return }
                    self?.stage = stage
                }
            }
        }
    }
}

/// Only flying stars use this mask; the real board, text and hit rectangles
/// remain unchanged. Partition the exact union into non-overlapping holes before
/// even-odd filling: overlaps cannot reveal stars, and empty space stays visible.
struct ProgressFlightTextMask: Shape {
    var protectedFrames: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for frame in Self.mergedFrames(protectedFrames, inside: rect) {
            path.addRect(frame)
        }
        return path
    }

    static func mergedFrames(_ frames: [CGRect], inside bounds: CGRect) -> [CGRect] {
        var result: [CGRect] = []
        for frame in frames {
            guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
                  !frame.isEmpty else { continue }
            let clipped = frame.intersection(bounds)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            var uncovered = [clipped]
            for existing in result {
                uncovered = uncovered.flatMap { subtract(existing, from: $0) }
            }
            result.append(contentsOf: uncovered)
        }
        return result
    }

    private static func subtract(_ covered: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(covered)
        guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
        // Top/bottom take the full width. Side pieces use only the overlap's
        // height, so all four residuals are disjoint and preserve the exact area.
        return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
                CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)]
            .filter { !$0.isEmpty }
    }
}

private struct ProgressStarPath: AnimatableModifier {
    var progress: CGFloat
    let flight: GameRewardPresentation.Flight
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let t = progress
        content.scaleEffect(1 - t * 0.42).rotationEffect(.degrees(Double(t) * 110))
            .opacity(t > 0.94 ? Double((1 - t) / 0.06) : 1)
            .position(flight.position(at: t))
    }
}

struct ProgressFlightStar: View {
    let flight: GameRewardPresentation.Flight
    @State private var progress: CGFloat = 0
    var body: some View {
        Image(systemName: "star.fill").resizable().scaledToFit()
            .frame(width: flight.diameter, height: flight.diameter)
            .foregroundColor(CapyPalette.orange)
            .shadow(color: .white.opacity(0.9), radius: 1)
            .modifier(ProgressStarPath(progress: progress, flight: flight))
            .allowsHitTesting(false).accessibilityHidden(true)
            .onAppear { withAnimation(.easeInOut(duration: 0.44)) { progress = 1 } }
    }
}

/// Place the entire badge and its travel outside the accepted cell. The board
/// supplies actual geometry; no duplicated padding or guessed cell dimensions.
struct CellScorePlacement {
    let center: CGPoint
    let size: CGSize
    let verticalTravel: CGFloat
    let fontSize: CGFloat
    var horizontalPadding: CGFloat { fontSize <= 15 ? 3 : 6 }

    init(amount: Int, center: CGPoint, verticalTravel: CGFloat = -12) {
        self.init(amount: amount, center: center, verticalTravel: verticalTravel, fontSize: 19)
    }

    private init(amount: Int, center: CGPoint, verticalTravel: CGFloat, fontSize: CGFloat) {
        let base = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let font = UIFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: fontSize)
        let textWidth = ("+\(amount)" as NSString).size(withAttributes: [.font: font]).width
        self.center = center; self.fontSize = fontSize
        size = CGSize(width: ceil(textWidth) + (fontSize <= 15 ? 6 : 12),
                      height: max(ceil(font.lineHeight) + 4, ceil(fontSize * 24 / 19) + 4))
        self.verticalTravel = verticalTravel
    }

    private init(center: CGPoint, size: CGSize, verticalTravel: CGFloat, fontSize: CGFloat) {
        self.center = center; self.size = size; self.verticalTravel = verticalTravel; self.fontSize = fontSize
    }

    var sweptFrame: CGRect {
        let start = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                           width: size.width, height: size.height)
        return start.union(start.offsetBy(dx: 0, dy: verticalTravel))
    }

    static func anchored(amount: Int, cellFrame: CGRect, boardFrame: CGRect, avoiding: [CGRect] = []) -> CellScorePlacement? {
        let preferredSize = max(15, min(19, cellFrame.width * 0.6))
        let preferred = place(amount: amount, cellFrame: cellFrame, boardFrame: boardFrame,
                              avoiding: avoiding, fontSize: preferredSize)
        guard preferredSize > 15 else { return preferred }
        let compact = place(amount: amount, cellFrame: cellFrame, boardFrame: boardFrame,
                            avoiding: avoiding, fontSize: 15)
        guard let preferred else { return compact }
        guard let compact else { return preferred }
        // Preserve the more readable original type unless smaller text makes
        // a material difference to its association with the new character.
        let compactCost = compact.proximityCost(to: cellFrame) + (preferredSize - 15) * 2
        return compactCost + 0.001 < preferred.proximityCost(to: cellFrame) ? compact : preferred
    }

    private func proximityCost(to cell: CGRect) -> CGFloat {
        // Small tie-break preference for visible drift; never send a badge
        // across the board merely to keep a full12pt upward movement.
        hypot(center.x - cell.midX, center.y - cell.midY) + (12 - abs(verticalTravel)) * 0.25
    }

    private static func place(amount: Int, cellFrame: CGRect, boardFrame: CGRect, avoiding: [CGRect], fontSize: CGFloat) -> CellScorePlacement? {
        guard amount > 0, !cellFrame.isEmpty, !boardFrame.isEmpty,
              [cellFrame.minX, cellFrame.minY, cellFrame.width, cellFrame.height,
               boardFrame.minX, boardFrame.minY, boardFrame.width, boardFrame.height].allSatisfy(\.isFinite) else { return nil }
        let bounds = boardFrame.insetBy(dx: 2, dy: 2)
        let measured = CellScorePlacement(amount: amount, center: .zero, verticalTravel: -12, fontSize: fontSize)
        let size = CGSize(width: min(measured.size.width, bounds.width), height: measured.size.height)
        guard size.width > 0, bounds.height >= size.height else { return nil }
        let obstacles = [cellFrame] + avoiding.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, bounds.minX + size.width / 2), bounds.maxX - size.width / 2) }
        func candidate(x: CGFloat, y: CGFloat, direction: CGFloat, travel: CGFloat = 12) -> CellScorePlacement? {
            let result = CellScorePlacement(center: CGPoint(x: x, y: y), size: size,
                verticalTravel: direction * travel, fontSize: fontSize)
            guard bounds.insetBy(dx: -0.0001, dy: -0.0001).contains(result.sweptFrame),
                  !obstacles.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(result.sweptFrame) }) else { return nil }
            return result
        }
        let x = clampX(cellFrame.midX)
        var best: CellScorePlacement?
        var bestCost = CGFloat.infinity
        func consider(_ option: CellScorePlacement?) {
            guard let option else { return }
            let cost = option.proximityCost(to: cellFrame)
            if cost + 0.001 < bestCost { best = option; bestCost = cost }
        }
        for direction in [CGFloat(-1), CGFloat(1)] {
            let y = direction < 0 ? cellFrame.minY - 4 - size.height / 2 : cellFrame.maxY + 4 + size.height / 2
            let direct = candidate(x: x, y: y, direction: direction)
            // Aligned above/below is the shortest clear axis for this wide
            // label. Keep the normal-board fast path and its familiar motion.
            if let direct, abs(x - cellFrame.midX) < 0.001 { return direct }
            consider(direct)
        }
        // Tight late-game boards may have another animal above and below.
        // Search only obstacle edges and board limits, then choose the closest
        // clear position; at most 10 occupied cells bound this small search.
        // Search just beyond the required2pt exclusion. Using the normal4pt
        // aesthetic gap here can miss valid narrow slots between two animals.
        let searchGap: CGFloat = 2.25
        var horizontal = [x, bounds.minX + size.width / 2, bounds.maxX - size.width / 2]
        for obstacle in obstacles {
            horizontal.append(clampX(obstacle.minX - searchGap - size.width / 2))
            horizontal.append(clampX(obstacle.maxX + searchGap + size.width / 2))
        }
        let xs = Array(Set(horizontal)).sorted()
        for travel in [CGFloat(12), CGFloat(6), CGFloat(0)] {
            for direction in [CGFloat(-1), CGFloat(1)] {
                let upward: CGFloat = direction < 0 ? travel : 0
                let downward: CGFloat = direction > 0 ? travel : 0
                var vertical = [cellFrame.midY, bounds.minY + size.height / 2 + upward,
                                bounds.maxY - size.height / 2 - downward]
                for obstacle in obstacles {
                    vertical.append(obstacle.minY - searchGap - size.height / 2 - downward)
                    vertical.append(obstacle.maxY + searchGap + size.height / 2 + upward)
                }
                let ys = Array(Set(vertical)).sorted()
                for cx in xs { for cy in ys {
                    guard let option = candidate(x: cx, y: cy, direction: direction, travel: travel) else { continue }
                    consider(option)
                } }
            }
        }
        return best
    }
}

struct CellScoreLabel: View {
    let item: GameRewardPresentation.LocalScore
    @State private var lifted = false
    var body: some View {
        Text("+\(item.amount)")
            .font(.system(size: item.placement.fontSize, weight: .heavy, design: .rounded))
            .foregroundColor(CapyPalette.actionOrange)
            .lineLimit(1).minimumScaleFactor(0.5)
            .padding(.horizontal, item.placement.horizontalPadding)
            .frame(width: item.placement.size.width, height: item.placement.size.height)
            .background(CapyPalette.paper.opacity(0.96)).clipShape(Capsule())
            .capyLayoutProbe("local_score_\(item.amount)")
            .shadow(color: CapyPalette.ink.opacity(0.12), radius: 2, y: 1)
            .position(x: item.origin.x, y: item.origin.y + (lifted ? item.placement.verticalTravel : 0))
            .opacity(lifted ? 0 : 1)
            .allowsHitTesting(false).accessibilityHidden(true)
            .onAppear {
                guard !item.reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.68)) { lifted = true }
            }
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
