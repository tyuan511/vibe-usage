import Testing
import VibeUsageAggregation
@testable import VibeUsageUI

@Suite struct MenuBarMetricPreferenceTests {
    @Test func migratesTheLegacySpendToggleWhenNoNewModeExists() {
        #expect(MenuBarMetricMode.resolve(storedRawValue: nil, legacyShowsSpend: true) == .usage)
        #expect(MenuBarMetricMode.resolve(storedRawValue: nil, legacyShowsSpend: false) == .hidden)
        #expect(MenuBarMetricMode.resolve(storedRawValue: nil, legacyShowsSpend: nil) == .usage)
    }

    @Test func migratesStoredSingleMetricModesToCombinedUsage() {
        #expect(MenuBarMetricMode.resolve(storedRawValue: "spend", legacyShowsSpend: false) == .usage)
        #expect(MenuBarMetricMode.resolve(storedRawValue: "tokens", legacyShowsSpend: false) == .usage)
        #expect(MenuBarMetricMode.resolve(storedRawValue: "usage", legacyShowsSpend: false) == .usage)
        #expect(MenuBarMetricMode.resolve(storedRawValue: "hidden", legacyShowsSpend: true) == .hidden)
    }

    @Test func formatsBothMetricsIncludingStableZeroValues() {
        let zero = UsageTotals()
        let usage = UsageTotals(tokens: .init(input: 10_000, output: 2_300), costUSD: 3.24)

        #expect(MenuBarMetricFormatter.values(for: .hidden, totals: usage) == nil)
        #expect(MenuBarMetricFormatter.values(for: .usage, totals: zero) == .init(tokens: "0K", spend: "$0"))
        #expect(MenuBarMetricFormatter.values(for: .usage, totals: usage) == .init(tokens: "12.3K", spend: "$3.2"))
    }
}
