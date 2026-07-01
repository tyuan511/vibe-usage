import Foundation

/// On-disk shape of `Resources/model_prices.json`: a flat map from
/// alias-resolved model family key (e.g. "claude-sonnet-4", "gpt-5") to its
/// rates. Refreshed by `Scripts/update-pricing.py` from LiteLLM's community
/// pricing dataset.
struct PricingSnapshotEntry: Decodable {
    let inputPerMillion: Decimal
    let outputPerMillion: Decimal
    let cacheWritePerMillion: Decimal?
    let cacheReadPerMillion: Decimal?
}

typealias PricingSnapshot = [String: PricingSnapshotEntry]
