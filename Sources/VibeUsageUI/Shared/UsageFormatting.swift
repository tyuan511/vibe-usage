import Foundation
import SwiftUI

public extension Decimal {
    var usdString: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = self < 1 ? 4 : 2
        return formatter.string(from: self as NSDecimalNumber) ?? "$0.00"
    }

    /// Adaptive currency formatting for large, skewed spend values (a single
    /// heavy source can run into the thousands): `< $1000` behaves like
    /// `usdString`; `>= $1000` drops fractional cents (`$2,457`); `>= $10,000`
    /// compacts to one decimal with a `K` suffix (`$8.1K`).
    var usdCompactString: String {
        let magnitude = abs(self)
        if magnitude >= 10_000 {
            let thousands = (self as NSDecimalNumber).doubleValue / 1_000
            return "$" + String(format: "%.1f", thousands) + "K"
        }
        if magnitude >= 1_000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            formatter.currencySymbol = "$"
            formatter.maximumFractionDigits = 0
            return formatter.string(from: self as NSDecimalNumber) ?? usdString
        }
        return usdString
    }
}

extension Int {
    var compactString: String {
        let absolute = abs(self)
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
        if absolute >= 1_000 {
            return String(format: "%.1fK", Double(self) / 1_000).replacingOccurrences(of: ".0K", with: "K")
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(hex, radix: 16) ?? 0
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
