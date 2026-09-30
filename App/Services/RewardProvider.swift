import Foundation
import CapydokuCore

enum RewardScenario: String, CaseIterable, Identifiable {
    case success = "Success", cancel = "Cancel", failure = "Failure"
    case duplicate = "Duplicate callback", interrupted = "Interrupt after reward"
    var id: String { rawValue }
}
enum RewardSignal { case earned, cancelled, failed, interrupted }

/// A real SDK adapter can implement this boundary without owning game state or inventory.
protocol RewardProvider {
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void)
}

struct MockRewardProvider: RewardProvider {
    let scenario: RewardScenario
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            switch scenario {
            case .success: completion(.earned)
            case .cancel: completion(.cancelled)
            case .failure: completion(.failed)
            case .interrupted: completion(.interrupted)
            case .duplicate:
                completion(.earned)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { completion(.earned) }
            }
        }
    }
}
