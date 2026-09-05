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
            inputPerMillion: 4,
            outputPerMillion: 20,
            cacheWritePerMillion: 5,
            cacheReadPerMillion: 0.4
        ),
        "gpt-5.6-sol": ModelPricingRate(
            inputPerMillion: 4,
            outputPerMillion: 20,
            cacheWritePerMillion: 5,
            cacheReadPerMillion: 0.4
        ),
        "gpt-5.6-terra": ModelPricingRate(
            inputPerMillion: 2,
            outputPerMillion: 12,
            cacheWritePerMillion: 2.5,
            cacheReadPerMillion: 0.2
        ),
        "gpt-5.6-luna": ModelPricingRate(
            inputPerMillion: 0.2,
            outputPerMillion: 1.2,
            cacheWritePerMillion: 0.25,
            cacheReadPerMillion: 0.02
        ),
    ]

    for (model, expected) in expectedRates {
        #expect(provider.rate(forModelFamily: model) == expected)
    }
}

@Test func loadsGPT6AstraWithStandardPricing() {
    let provider = BundledPricingProvider(localSnapshotURL: nil)
    let expected = ModelPricingRate(
        inputPerMillion: 10,
        outputPerMillion: 50,
        cacheWritePerMillion: 12.5,
        cacheReadPerMillion: 1
    )
    for model in ["gpt-6-astra", "openai/gpt-6-astra"] {
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
