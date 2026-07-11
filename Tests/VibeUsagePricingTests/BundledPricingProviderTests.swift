import Foundation
import Testing
import VibeUsageCore
@testable import VibeUsagePricing

@Test func loadsRealBundledSnapshotAndResolvesKnownFamily() {
    let provider = BundledPricingProvider(localSnapshotURL: nil)
    let rate = provider.rate(forModelFamily: "claude-sonnet-4")
    #expect(rate != nil)
    #expect((rate?.inputPerMillion ?? 0) > 0)
    #expect((rate?.outputPerMillion ?? 0) > 0)
}

@Test func loadsGeminiQwenAndKimiFamiliesFromBundledSnapshot() {
    let provider = BundledPricingProvider(localSnapshotURL: nil)
    #expect(provider.rate(forModelFamily: "gemini-3-flash-preview") != nil)
    #expect(provider.rate(forModelFamily: "qwen3-coder-plus") != nil)
    #expect(provider.rate(forModelFamily: "kimi-k2") != nil)
}

@Test func loadsCommonDirectProviderFamiliesFromBundledSnapshot() {
    let provider = BundledPricingProvider(localSnapshotURL: nil)
    #expect(provider.rate(forModelFamily: "deepseek-v3.2") != nil)
    #expect(provider.rate(forModelFamily: "glm-5") != nil)
    #expect(provider.rate(forModelFamily: "minimax-m2.5") != nil)
    #expect(provider.rate(forModelFamily: "grok-4") != nil)
}

@Test func loadsGPT56FamilyWithCurrentStandardPricing() {
    let provider = BundledPricingProvider(localSnapshotURL: nil)
    let expectedRates: [String: ModelPricingRate] = [
        "gpt-5.6": ModelPricingRate(
            inputPerMillion: 5,
            outputPerMillion: 30,
            cacheWritePerMillion: 6.25,
            cacheReadPerMillion: 0.5
        ),
        "gpt-5.6-sol": ModelPricingRate(
            inputPerMillion: 5,
            outputPerMillion: 30,
            cacheWritePerMillion: 6.25,
            cacheReadPerMillion: 0.5
        ),
        "gpt-5.6-terra": ModelPricingRate(
            inputPerMillion: 2.5,
            outputPerMillion: 15,
            cacheWritePerMillion: 3.125,
            cacheReadPerMillion: 0.25
        ),
        "gpt-5.6-luna": ModelPricingRate(
            inputPerMillion: 1,
            outputPerMillion: 6,
            cacheWritePerMillion: 1.25,
            cacheReadPerMillion: 0.1
        ),
    ]

    for (model, expected) in expectedRates {
        #expect(provider.rate(forModelFamily: model) == expected)
    }
}

@Test func resolvesStoredAliasesForHistoricalRepricing() throws {
    let provider = BundledPricingProvider(localSnapshotURL: nil)
    #expect(
        provider.rate(forModelFamily: "gemini-3-pro-high")
            == provider.rate(forModelFamily: "gemini-3-pro-preview")
    )
    #expect(
        provider.rate(forModelFamily: "k2p6")
            == provider.rate(forModelFamily: "kimi-k2.6")
    )
    #expect(
        provider.rate(forModelFamily: "claude-sonnet-4.5")
            == provider.rate(forModelFamily: "claude-sonnet-4-5")
    )
    #expect(
        provider.rate(forModelFamily: "claude-opus-45")
            == provider.rate(forModelFamily: "claude-opus-4-5")
    )

    let cutoff = Date(timeIntervalSince1970: 1_776_698_890.072)
    #expect(
        provider.rate(forModelFamily: "kimi-for-coding", at: cutoff.addingTimeInterval(-1))
            == provider.rate(forModelFamily: "kimi-k2.5")
    )
    #expect(
        provider.rate(forModelFamily: "kimi-for-coding", at: cutoff)
            == provider.rate(forModelFamily: "kimi-k2.6")
    )
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
