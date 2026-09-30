import Foundation
import CapydokuCore

enum RewardScenario: String, CaseIterable, Identifiable {
    case success = "Success", cancel = "Cancel", failure = "Failure"
    case duplicate = "Duplicate callback", interrupted = "Interrupt after reward"
    case timeout = "No callback (timeout)"
    var id: String { rawValue }
}
enum RewardSignal: Equatable { case earned, cancelled, failed, interrupted, timedOut }
enum RewardReadiness { case ready, unavailable }

/// Placement-based loading boundary; real adapters coalesce concurrent preload requests
/// and keep at most one ready ad per configured unit. No network SDK is linked here.
protocol RewardProvider {
    func preload(placement: RewardKind, completion: @escaping (RewardReadiness) -> Void)
    func isReady(placement: RewardKind) -> Bool
    func present(placement: RewardKind, offerID: String, completion: @escaping (RewardSignal) -> Void)
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void)
    func replenish(placement: RewardKind)
}

extension RewardProvider {
    // Existing synchronous mock/test adapters remain source-compatible. A live adapter
    // supplies its own load/ready implementation after its SDK privacy initialization.
    func preload(placement: RewardKind, completion: @escaping (RewardReadiness) -> Void) { completion(.ready) }
    func isReady(placement: RewardKind) -> Bool { true }
    func present(placement: RewardKind, offerID: String, completion: @escaping (RewardSignal) -> Void) {
        present(offerID: offerID, completion: completion)
    }
    // A new adapter can implement only the placement-aware display API. Legacy local
    // providers implement the offer-only overload above and use the compatibility bridge.
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) { completion(.failed) }
    func replenish(placement: RewardKind) { preload(placement: placement) { _ in } }
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
            case .timeout: break // The app must release its lock without trusting the adapter.
            case .duplicate:
                completion(.earned)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { completion(.earned) }
            }
        }
    }
}

enum InterstitialSignal { case closed, failed, timedOut }
protocol InterstitialProvider {
    func present(completion: @escaping (InterstitialSignal) -> Void)
}
struct MockInterstitialProvider: InterstitialProvider {
    let scenario: RewardScenario
    func present(completion: @escaping (InterstitialSignal) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            switch scenario {
            case .timeout: break
            case .failure, .interrupted: completion(.failed)
            case .success, .cancel: completion(.closed)
            case .duplicate: completion(.closed); completion(.closed)
            }
        }
    }
}
