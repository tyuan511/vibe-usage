import Foundation

/// Per-model pricing rates, expressed as USD per one million tokens.
public struct ModelPricingRate: Sendable, Equatable {
    public let inputPerMillion: Decimal
    public let outputPerMillion: Decimal
    /// Rate for cache-write/cache-creation tokens. Falls back to
    /// `inputPerMillion` when nil.
    public let cacheWritePerMillion: Decimal?
    /// Rate for cache-read tokens. Falls back to `inputPerMillion` when nil.
    public let cacheReadPerMillion: Decimal?

    public init(
        inputPerMillion: Decimal,
        outputPerMillion: Decimal,
        cacheWritePerMillion: Decimal? = nil,
        cacheReadPerMillion: Decimal? = nil
    ) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
    }
}

/// Resolves pricing for an alias-resolved model family key. Implemented by
/// ``VibeUsagePricing``; adapters depend only on this protocol so pricing data
/// can be swapped/updated without touching adapter code.
public protocol PricingProvider: Sendable {
    /// - Parameter modelFamily: an alias-resolved key (e.g. "claude-sonnet-4", "gpt-5"),
    ///   never a raw dated model id.
    /// - Returns: nil if no pricing entry is known for this family.
    func rate(forModelFamily modelFamily: String) -> ModelPricingRate?

    /// Timestamp-aware lookup used when a source alias changed model families
    /// over time. Providers without temporal aliases use the default lookup.
    func rate(forModelFamily modelFamily: String, at timestamp: Date) -> ModelPricingRate?
}

public extension PricingProvider {
    func rate(forModelFamily modelFamily: String, at _: Date) -> ModelPricingRate? {
        rate(forModelFamily: modelFamily)
    }
}

/// Shared cost-calculation rules, reused by adapters and historical repricing
/// so cache and source-specific reasoning-token behavior is defined once.
public enum CostCalculator {
    /// Applies the source-specific reasoning-token convention used by adapters.
    /// Codex reports reasoning as a subset of output; other sources report it
    /// separately and therefore bill it at the output-token rate.
    public static func cost(
        for tokens: TokenCounts,
        sourceID: AgentSourceID,
        rate: ModelPricingRate
    ) -> Decimal {
        guard sourceID != .codexCLI else {
            return cost(for: tokens, rate: rate)
        }
        var billableTokens = tokens
        billableTokens.output += billableTokens.reasoning
        return cost(for: billableTokens, rate: rate)
    }

    public static func cost(for tokens: TokenCounts, rate: ModelPricingRate) -> Decimal {
        let million = Decimal(1_000_000)
        let cacheReadRate = rate.cacheReadPerMillion ?? rate.inputPerMillion
        let cacheWriteRate = rate.cacheWritePerMillion ?? rate.inputPerMillion

        let inputCost = Decimal(tokens.input) * rate.inputPerMillion / million
        let outputCost = Decimal(tokens.output) * rate.outputPerMillion / million
        let cacheReadCost = Decimal(tokens.cacheRead) * cacheReadRate / million
        let cacheCreateCost = Decimal(tokens.cacheCreate) * cacheWriteRate / million

        return inputCost + outputCost + cacheReadCost + cacheCreateCost
    }
}
