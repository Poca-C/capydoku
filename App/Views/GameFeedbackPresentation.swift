import Foundation
import Combine

/// Short-lived text never enters the saved session. Old scheduled text cannot
/// reappear after an error, a new session, backgrounding or navigation.
@MainActor final class GameFeedbackPresentation: ObservableObject {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    @Published private(set) var comboText: String?
    @Published private(set) var comboRevision = UUID()
    @Published private(set) var showLastLife = false
    private var comboToken = UUID()
    private var presentationEnabled = true
    private let schedule: Schedule

    init(schedule: @escaping Schedule = { delay, operation in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: operation))
    }) { self.schedule = schedule }

    func setPresentationEnabled(_ enabled: Bool) {
        guard presentationEnabled != enabled else { return }
        presentationEnabled = enabled
        if !enabled { clear() }
    }

    func combo(_ presentation: ComboFeedbackPresentation?) {
        comboToken = UUID()
        let token = comboToken
        comboText = nil
        guard presentationEnabled, let presentation else { return }
        let show = { [weak self] in
            guard let self, self.comboToken == token else { return }
            self.comboRevision = UUID()
            self.comboText = presentation.text
            // This visible duration is still temporary; only the starting delay
            // comes from the verified audio mapping when it has been supplied.
            self.schedule(1.3) { [weak self] in
                guard let self, self.comboToken == token else { return }
                self.comboText = nil
            }
        }
        if presentation.delay == 0 { show() } else { schedule(presentation.delay, show) }
    }

    func life(_ lives: Int) {
        showLastLife = presentationEnabled && lives == 1
    }

    // The focus reminder is acknowledged by the player, never by a timer.
    // It is still ephemeral: restoring, covering or leaving a game clears it.
    func dismissLastLife() { showLastLife = false }

    func clear() {
        combo(nil)
        showLastLife = false
    }
}
