import Testing
import VibeUsageAggregation
@testable import VibeUsageUI

@Suite struct MenuBarMetricPreferenceTests {
    @Test func migratesTheLegacySpendToggleWhenNoNewModeExists() {
        #expect(MenuBarMetricMode.resolve(storedRawValue: nil, legacyShowsSpend: true) == .spend)
        #expect(MenuBarMetricMode.resolve(storedRawValue: nil, legacyShowsSpend: false) == .hidden)
        #expect(MenuBarMetricMode.resolve(storedRawValue: nil, legacyShowsSpend: nil) == .spend)
    }

    @Test func storedModeWinsOverTheLegacySpendToggle() {
        #expect(MenuBarMetricMode.resolve(storedRawValue: "tokens", legacyShowsSpend: true) == .tokens)
        #expect(MenuBarMetricMode.resolve(storedRawValue: "hidden", legacyShowsSpend: true) == .hidden)
    }

    @Test func formatsTheSelectedMetricIncludingStableZeroValues() {
        let zero = UsageTotals()
        let usage = UsageTotals(tokens: .init(input: 10_000, output: 2_300), costUSD: 3.24)

        #expect(MenuBarMetricFormatter.text(for: .hidden, totals: usage) == nil)
        #expect(MenuBarMetricFormatter.text(for: .spend, totals: zero) == "$0")
        #expect(MenuBarMetricFormatter.text(for: .spend, totals: usage) == "$3.2")
        #expect(MenuBarMetricFormatter.text(for: .tokens, totals: zero) == "0K")
        #expect(MenuBarMetricFormatter.text(for: .tokens, totals: usage) == "12.3K")
    }
}
