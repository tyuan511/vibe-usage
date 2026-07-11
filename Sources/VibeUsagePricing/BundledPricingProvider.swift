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

    public convenience init() {
        self.init(localSnapshotURL: PricingSnapshotStore().snapshotURL)
    }

    /// Loads bundled rates first, then lets a successfully downloaded local
    /// snapshot override matching families while preserving bundled fallbacks.
    public init(localSnapshotURL: URL?) {
        var snapshot = Self.loadSnapshot(from: Self.resourceBundle())
        if let localSnapshotURL,
           let localSnapshot = Self.loadSnapshot(from: localSnapshotURL) {
            snapshot.merge(localSnapshot) { _, downloadedRate in downloadedRate }
        }
        self.rates = Self.rates(from: snapshot)
    }

    /// Testing/advanced convenience: build a provider from an in-memory rate table.
    public init(rates: [String: ModelPricingRate]) {
        self.rates = rates
    }

    /// Internal seam for tests within this package that want to load from a
    /// specific bundle rather than the real packaged resource bundle.
    init(bundle: Bundle) {
        self.rates = Self.rates(from: Self.loadSnapshot(from: bundle))
    }

    public func rate(forModelFamily modelFamily: String) -> ModelPricingRate? {
        rate(forCandidates: ModelAliasResolver.pricingCandidates(fromRawModel: modelFamily, at: nil))
    }

    public func rate(forModelFamily modelFamily: String, at timestamp: Date) -> ModelPricingRate? {
        rate(forCandidates: ModelAliasResolver.pricingCandidates(fromRawModel: modelFamily, at: timestamp))
    }

    private func rate(forCandidates candidates: [String]) -> ModelPricingRate? {
        candidates.lazy.compactMap { candidate in
            self.rates[candidate] ?? self.rates[candidate.lowercased()]
        }.first
    }

    private static func loadSnapshot(from bundle: Bundle) -> PricingSnapshot {
        guard let url = bundle.url(forResource: "model_prices", withExtension: "json") else {
            return [:]
        }
        return loadSnapshot(from: url) ?? [:]
    }

    private static func loadSnapshot(from url: URL) -> PricingSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PricingSnapshot.self, from: data)
    }

    private static func rates(from snapshot: PricingSnapshot) -> [String: ModelPricingRate] {
        var rates: [String: ModelPricingRate] = [:]
        for (family, entry) in snapshot {
            let rate = ModelPricingRate(
                inputPerMillion: entry.inputPerMillion,
                outputPerMillion: entry.outputPerMillion,
                cacheWritePerMillion: entry.cacheWritePerMillion,
                cacheReadPerMillion: entry.cacheReadPerMillion
            )
            rates[family] = rate
            if rates[family.lowercased()] == nil {
                rates[family.lowercased()] = rate
            }
        }
        return rates
    }

    private static func resourceBundle() -> Bundle {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("VibeUsage_VibeUsagePricing.bundle"),
           let bundle = Bundle(url: resourceURL) {
            return bundle
        }
        return .module
    }
}
