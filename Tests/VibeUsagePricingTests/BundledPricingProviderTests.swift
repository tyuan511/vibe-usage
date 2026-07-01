import Testing
import VibeUsageCore
@testable import VibeUsagePricing

@Test func loadsRealBundledSnapshotAndResolvesKnownFamily() {
    let provider = BundledPricingProvider()
    let rate = provider.rate(forModelFamily: "claude-sonnet-4")
    #expect(rate != nil)
    #expect((rate?.inputPerMillion ?? 0) > 0)
    #expect((rate?.outputPerMillion ?? 0) > 0)
}

@Test func missingFamilyReturnsNilRatherThanGuessing() {
    let provider = BundledPricingProvider()
    #expect(provider.rate(forModelFamily: "definitely-not-a-real-model-family") == nil)
}

@Test func costCalculatorFallsBackToInputRateWhenNoCacheWriteRate() {
    let provider = BundledPricingProvider(rates: [
        "test-model": ModelPricingRate(inputPerMillion: 2, outputPerMillion: 10)
    ])
    let rate = provider.rate(forModelFamily: "test-model")!
    let tokens = TokenCounts(input: 0, output: 0, cacheCreate: 1_000_000, cacheRead: 0)
    #expect(CostCalculator.cost(for: tokens, rate: rate) == 2) // falls back to input rate
}
