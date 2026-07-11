import Foundation
import VibeUsageAggregation

public enum MenuBarMetricMode: String, Sendable {
    case hidden
    case usage

    public static func resolve(storedRawValue: String?, legacyShowsSpend: Bool?) -> Self {
        switch storedRawValue {
        case Self.hidden.rawValue:
            return .hidden
        case Self.usage.rawValue, "spend", "tokens":
            return .usage
        default:
            return legacyShowsSpend == false ? .hidden : .usage
        }
    }
}

public struct MenuBarMetricValues: Equatable, Sendable {
    public let tokens: String
    public let spend: String

    public init(tokens: String, spend: String) {
        self.tokens = tokens
        self.spend = spend
    }
}

public enum MenuBarMetricFormatter {
    public static func values(for mode: MenuBarMetricMode, totals: UsageTotals) -> MenuBarMetricValues? {
        guard mode == .usage else { return nil }
        return MenuBarMetricValues(
            tokens: totals.tokens.total == 0 ? "0K" : totals.tokens.total.compactString,
            spend: spendText(totals.costUSD)
        )
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
