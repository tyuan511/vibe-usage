import Foundation
import VibeUsageCore

/// Loads the pricing snapshot bundled as a package resource
/// (`Sources/VibeUsagePricing/Resources/model_prices.json`) and serves
/// lookups by alias-resolved model family key.
///
/// Missing entries are a normal, expected condition (a new model shipped
/// after the last pricing refresh, or a truly unknown model) — callers
/// (adapters) are expected to fall back to `costIsEstimated = true` with a
/// zero or best-effort cost rather than this type inventing a price.
public final class BundledPricingProvider: PricingProvider {
    private let rates: [String: ModelPricingRate]

    public init() {
        self.rates = Self.loadRates(from: Self.resourceBundle())
    }

    /// Testing/advanced convenience: build a provider from an in-memory rate table.
    public init(rates: [String: ModelPricingRate]) {
        self.rates = rates
    }

    /// Internal seam for tests within this package that want to load from a
    /// specific bundle rather than the real packaged resource bundle.
    init(bundle: Bundle) {
        self.rates = Self.loadRates(from: bundle)
    }

    public func rate(forModelFamily modelFamily: String) -> ModelPricingRate? {
        rate(forCandidates: ModelAliasResolver.pricingCandidates(fromRawModel: modelFamily, at: nil))
    }

    public func rate(forModelFamily modelFamily: String, at timestamp: Date) -> ModelPricingRate? {
        rate(forCandidates: ModelAliasResolver.pricingCandidates(fromRawModel: modelFamily, at: timestamp))
    }

    private func rate(forCandidates candidates: [String]) -> ModelPricingRate? {
        candidates.lazy.compactMap { self.rates[$0] }.first
    }

    private static func loadRates(from bundle: Bundle) -> [String: ModelPricingRate] {
        guard let url = bundle.url(forResource: "model_prices", withExtension: "json") else {
            return [:]
        }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let snapshot = try? JSONDecoder().decode(PricingSnapshot.self, from: data) else {
            return [:]
        }
        return snapshot.mapValues { entry in
            ModelPricingRate(
                inputPerMillion: entry.inputPerMillion,
                outputPerMillion: entry.outputPerMillion,
                cacheWritePerMillion: entry.cacheWritePerMillion,
                cacheReadPerMillion: entry.cacheReadPerMillion
            )
        }
    }

    private static func resourceBundle() -> Bundle {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("VibeUsage_VibeUsagePricing.bundle"),
           let bundle = Bundle(url: resourceURL) {
            return bundle
        }
        return .module
    }
}
