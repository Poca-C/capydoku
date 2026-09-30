import Foundation

/// Original specification §6.3. An unknown legacy source is represented by nil,
/// never by assigning an unverified value from this required analytics enum.
public enum ToolInventorySource: String, Codable, Equatable, Sendable {
    case initialFree = "initial_free"
    case levelConfigFree = "level_config_free"
    case rewardedAd = "rewarded_ad"
}

/// Provenance accompanies a quantity; the existing inventory remains authoritative.
/// Contiguous grants of the same source share one batch, with FIFO use inside a pool.
struct ToolSourceQueue: Codable, Equatable, Sendable {
    struct Batch: Codable, Equatable, Sendable {
        var source: ToolInventorySource?
        var count: Int
    }
    private var batches: [Batch] = []

    init(count: Int = 0, source: ToolInventorySource? = nil) {
        if count > 0 { batches = [Batch(source: source, count: count)] }
    }

    var count: Int? {
        var result = 0
        for batch in batches {
            guard batch.count > 0 else { return nil }
            let sum = result.addingReportingOverflow(batch.count)
            guard !sum.overflow else { return nil }
            result = sum.partialValue
        }
        return result
    }
    var nextSource: ToolInventorySource? { batches.first?.source }

    /// Public legacy fields may change independently. A mismatch cannot tell us
    /// which grant changed, so forget the entire pool's attribution, not its stock.
    func matching(_ actualCount: Int) -> Self {
        guard actualCount >= 0, count == actualCount else { return Self(count: actualCount) }
        return self
    }

    mutating func append(_ other: Self) {
        guard let ownCount = count, let otherCount = other.count,
              !ownCount.addingReportingOverflow(otherCount).overflow else {
            batches = []
            return
        }
        for batch in other.batches {
            if let last = batches.last, last.source == batch.source {
                batches[batches.count - 1].count += batch.count
            } else { batches.append(batch) }
        }
        // Keep untrusted or exceptionally old histories bounded. Losing attribution
        // is safe; discarding or inventing spendable inventory would not be.
        if batches.count > 4_096 { self = Self(count: ownCount + otherCount) }
    }

    mutating func consumeOne() {
        guard !batches.isEmpty else { return }
        if batches[0].count == 1 { batches.removeFirst() }
        else { batches[0].count -= 1 }
    }
}

struct ToolInventorySources: Codable, Equatable, Sendable {
    var hints = ToolSourceQueue()
    var direct = ToolSourceQueue()

    func matching(_ balance: ToolBalance) -> Self {
        Self(hints: hints.matching(balance.hints), direct: direct.matching(balance.direct))
    }
}
