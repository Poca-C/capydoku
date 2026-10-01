import SwiftUI
import UIKit

/// A HUD acknowledgement, never a deferred count update. Each arrival replaces
/// the previous finite envelope; old jobs cannot settle a newer arrival.
@MainActor final class ProgressArrivalPresentation: ObservableObject {
    typealias Schedule = (TimeInterval, DispatchWorkItem) -> Void
    @Published private(set) var scale: CGFloat = 1
    @Published private(set) var activeID: UUID?
    @Published private(set) var resetID = UUID()
    private var sessionID: UUID?
    private var lastArrivalID: UUID?
    private var generation = UUID()
    private var jobs: [DispatchWorkItem] = []
    private let schedule: Schedule

    init(schedule: @escaping Schedule = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) { self.schedule = schedule }

    deinit { jobs.forEach { $0.cancel() } }

    func bind(sessionID: UUID, arrivalID: UUID?) {
        cancel()
        self.sessionID = sessionID; lastArrivalID = arrivalID
    }

    func update(sessionID: UUID, arrivalID: UUID?, enabled: Bool, reduceMotion: Bool, lowPower: Bool) {
        guard self.sessionID == sessionID else {
            bind(sessionID: sessionID, arrivalID: arrivalID); return
        }
        let fresh = arrivalID != nil && arrivalID != lastArrivalID
        lastArrivalID = arrivalID
        guard enabled, !reduceMotion, !lowPower, let arrivalID else { cancel(); return }
        guard fresh else { return }
        // Keep the currently visible interpolation when a new arrival comes
        // in. A tiny release makes true consecutive arrivals distinguishable.
        invalidateJobs()
        let token = generation
        activeID = arrivalID
        withAnimation(.easeOut(duration: 0.035)) { scale = 0.99 }
        enqueue(after: 0.04, token: token) { view in
            withAnimation(.easeOut(duration: 0.085)) { view.scale = 1.10 }
        }
        enqueue(after: 0.135, token: token) { view in
            withAnimation(.easeOut(duration: 0.185)) { view.scale = 1 }
        }
        enqueue(after: 0.32, token: token) { view in
            view.activeID = nil
            view.jobs.removeAll()
        }
    }

    func cancel() {
        let wasAnimating = activeID != nil || !jobs.isEmpty || scale != 1
        invalidateJobs()
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) {
            activeID = nil; scale = 1
            // During the return, SwiftUI already has a model target of 1.
            // Assigning 1 again cannot remove that in-flight interpolation.
            // Replace only its decorated child, under the stable lifecycle host.
            if wasAnimating { resetID = UUID() }
        }
    }

    private func invalidateJobs() {
        generation = UUID(); jobs.forEach { $0.cancel() }; jobs.removeAll()
    }

    private func enqueue(after delay: TimeInterval, token: UUID, action: @escaping (ProgressArrivalPresentation) -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            action(self)
        }
        jobs.append(work); schedule(delay, work)
    }
}

/// Keeps the existing SwiftUI counter, sizing and accessibility intact. Root's
/// presentation gate and SwiftUI lifecycle own visibility; no extra app timer.
@MainActor struct ProgressArrivalPulseModifier: ViewModifier {
    let sessionID: UUID
    let arrivalID: UUID?
    let enabled: Bool
    let reduceMotion: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @StateObject private var presentation: ProgressArrivalPresentation

    init(sessionID: UUID, arrivalID: UUID?, enabled: Bool, reduceMotion: Bool,
         presentation: ProgressArrivalPresentation? = nil) {
        self.sessionID = sessionID; self.arrivalID = arrivalID
        self.enabled = enabled; self.reduceMotion = reduceMotion
        _presentation = StateObject(wrappedValue: presentation ?? ProgressArrivalPresentation())
    }

    func body(content: Content) -> some View {
        ZStack {
            content.scaleEffect(presentation.scale)
                .id(presentation.resetID)
                .transition(.identity)
                .transaction {
                    if presentation.activeID == nil { $0.animation = nil; $0.disablesAnimations = true }
                }
        }
            // These callbacks belong to the stable container. Resetting the
            // animation child must not bind/cancel the arrival again.
            .onAppear { presentation.bind(sessionID: sessionID, arrivalID: arrivalID) }
            .onChange(of: arrivalID) { _ in update() }
            .onChange(of: sessionID) { _ in update() }
            .onChange(of: enabled) { _ in update() }
            .onChange(of: reduceMotion) { _ in update() }
            .onChange(of: scenePhase) { _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                update()
            }
            .onDisappear { presentation.cancel() }
    }

    private func update() {
        presentation.update(sessionID: sessionID, arrivalID: arrivalID,
                            enabled: enabled && scenePhase == .active,
                            reduceMotion: reduceMotion, lowPower: lowPower)
    }
}
