import Foundation
import VibeUsageCore

/// A synchronized pricing-provider reference shared by ingestion and manual
/// price updates. Replacing the provider makes future lookups use the newest
/// locally persisted snapshot without recreating the ingestion pipeline.
public final class CurrentPricingProvider: PricingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var provider: any PricingProvider

    public init(_ provider: any PricingProvider) {
        self.provider = provider
    }

    public func replace(with provider: any PricingProvider) {
        lock.lock()
        self.provider = provider
        lock.unlock()
    }

    public func rate(forModelFamily modelFamily: String) -> ModelPricingRate? {
        providerSnapshot().rate(forModelFamily: modelFamily)
    }

    public func rate(forModelFamily modelFamily: String, at timestamp: Date) -> ModelPricingRate? {
        providerSnapshot().rate(forModelFamily: modelFamily, at: timestamp)
    }

    private func providerSnapshot() -> any PricingProvider {
        lock.lock()
        defer { lock.unlock() }
        return provider
    }
}
