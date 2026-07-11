import Foundation
import VibeUsageAggregation

public enum MenuBarMetricMode: String, CaseIterable, Identifiable, Sendable {
    case hidden
    case spend
    case tokens

    public var id: String { rawValue }

    public static func resolve(storedRawValue: String?, legacyShowsSpend: Bool?) -> Self {
        if let storedRawValue, let stored = Self(rawValue: storedRawValue) {
            return stored
        }
        return legacyShowsSpend == false ? .hidden : .spend
    }
}

public enum MenuBarMetricFormatter {
    public static func text(for mode: MenuBarMetricMode, totals: UsageTotals) -> String? {
        switch mode {
        case .hidden:
            return nil
        case .spend:
            return spendText(totals.costUSD)
        case .tokens:
            return totals.tokens.total == 0 ? "0K" : totals.tokens.total.compactString
        }
    }

    private static func spendText(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = amount < 100 ? 1 : 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0"
    }
}
