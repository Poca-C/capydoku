import UIKit

enum HapticFeedbackPattern: Equatable { case selection, correct, error, success }

@MainActor
protocol HapticFeedbackDriver: AnyObject {
    func prepare(_ pattern: HapticFeedbackPattern)
    func emit(_ pattern: HapticFeedbackPattern)
}

/// Retain generators across moves so preparing them can benefit the next input.
@MainActor
final class UIKitHapticFeedbackDriver: HapticFeedbackDriver {
    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()

    func prepare(_ pattern: HapticFeedbackPattern) {
        switch pattern {
        case .selection: selection.prepare()
        case .correct: impact.prepare()
        case .error, .success: notification.prepare()
        }
    }

    func emit(_ pattern: HapticFeedbackPattern) {
        switch pattern {
        case .selection: selection.selectionChanged()
        case .correct: impact.impactOccurred(intensity: 0.75)
        case .error: notification.notificationOccurred(.error)
        case .success: notification.notificationOccurred(.success)
        }
    }
}

/// Haptics have no audio resource/session dependency and never queue delayed pulses.
/// This is a local responsiveness policy, not a claimed reference-game parameter.
@MainActor
final class HapticFeedbackPlayer {
    static let lightMinimumInterval: TimeInterval = 0.06

    private let driver: HapticFeedbackDriver?
    private let clock: () -> TimeInterval
    private let observer: ((FeedbackEvent) -> Void)?
    private var enabled = true
    private var interrupted = false
    private var environment = FeedbackEnvironment(page: .startup)
    private var lastLightTime: TimeInterval?

    init(driver: HapticFeedbackDriver?, clock: @escaping () -> TimeInterval,
         observer: ((FeedbackEvent) -> Void)? = nil) {
        self.driver = driver; self.clock = clock; self.observer = observer
    }

    func update(enabled: Bool, environment: FeedbackEnvironment, interrupted: Bool) {
        guard self.enabled != enabled || self.environment != environment || self.interrupted != interrupted else { return }
        self.enabled = enabled; self.environment = environment; self.interrupted = interrupted
        lastLightTime = nil
        guard allowsInput else { return }
        prepareForInput()
    }

    func prepareForInput() {
        guard allowsInput else { return }
        driver?.prepare(.selection)
        driver?.prepare(.correct)
        driver?.prepare(.error) // Success uses this same notification generator.
    }

    func play(_ event: FeedbackEvent, acceptedIn context: FeedbackEnvironment? = nil) {
        let pattern: HapticFeedbackPattern
        switch event {
        case .tap, .combo: return // Buttons retain their explicit policy; Combo is not another move.
        case .mark, .erase: pattern = .selection
        case .correct: pattern = .correct
        case .wrong: pattern = .error
        case .win: pattern = .success
        }
        guard enabled, !interrupted, environment.page == .game,
              environment.blocks.intersection([.paused, .advertisement, .background]).isEmpty else { return }
        if let context {
            // A committed reveal may finish after its input overlay has closed or
            // become a result/error overlay. It must still belong to this board.
            guard event == .correct || event == .win,
                  context.page == .game, context.level == environment.level,
                  context.blocks.isEmpty, inputOverlay(context.overlay) else { return }
        } else {
            guard allowsInput else { return }
        }
        if pattern == .selection {
            let now = clock()
            guard now.isFinite else { return }
            if let lastLightTime, now >= lastLightTime,
               now - lastLightTime < Self.lightMinimumInterval { return }
            lastLightTime = now
        }
        driver?.emit(pattern)
        observer?(event)
        if allowsInput { driver?.prepare(pattern) }
    }

    func playMarks(count: Int) {
        guard count > 0 else { return }
        // Coalesce a batch and rapid adjacent callbacks into one light selection.
        play(.mark)
    }

    private var allowsInput: Bool {
        enabled && !interrupted && environment.page == .game && environment.blocks.isEmpty && inputOverlay(environment.overlay)
    }
    private func inputOverlay(_ overlay: FeedbackAudioOverlay) -> Bool {
        overlay == .none || overlay == .tutorial
    }
}
