import Foundation

/// Aggregates recognition attempts, rather than finger-down time. A tap may
/// still be waiting for its double-tap dependency after the finger lifts.
@MainActor
final class BoardInputActivity {
    let ownerID = UUID()
    var onChange: ((UUID, Bool) -> Void)?
    private var recognizers = Set<UUID>()

    var isBusy: Bool { !recognizers.isEmpty }

    func begin(_ recognizerID: UUID) {
        let wasBusy = isBusy
        recognizers.insert(recognizerID)
        if !wasBusy { onChange?(ownerID, true) }
    }

    func end(_ recognizerID: UUID) {
        guard recognizers.remove(recognizerID) != nil, !isBusy else { return }
        onChange?(ownerID, false)
    }

    /// Lifecycle cancellation invalidates every attempt owned by this board.
    /// Later recognizer resets are harmless, and cannot release another board.
    func cancelAll() {
        guard isBusy else { return }
        recognizers.removeAll()
        onChange?(ownerID, false)
    }
}
