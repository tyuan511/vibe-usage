import Foundation
import VibeUsageCore

/// Shared formatting helpers for turning raw fractions/dates into the
/// bilingual strings `QuotaWindow` carries. Centralized here so both quota
/// providers use identical rounding/threshold behavior.
public enum QuotaFormatting {
    /// Integer percent text, e.g. "87%".
    public static func percentText(usedFraction: Double) -> String {
        let clamped = min(max(usedFraction, 0), 1)
        let percent = Int((clamped * 100).rounded())
        return "\(percent)%"
    }

    /// Relative countdown text to `resetsAt` from `now`, e.g. zh "3小时12分后重置"
    /// / en "resets in 3h 12m". Returns nil once the reset time has passed
    /// (the caller's next fetch is expected to supersede it).
    public static func countdownText(resetsAt: Date?, now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else { return nil }

        let totalMinutes = Int((interval / 60).rounded(.up))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return VibeUsageStrings.text(
                zh: "\(days)天\(hours)小时后重置",
                en: "resets in \(days)d \(hours)h"
            )
        }
        if hours > 0 {
            return VibeUsageStrings.text(
                zh: "\(hours)小时\(minutes)分后重置",
                en: "resets in \(hours)h \(minutes)m"
            )
        }
        return VibeUsageStrings.text(
            zh: "\(minutes)分钟后重置",
            en: "resets in \(minutes)m"
        )
    }

    /// Badge text for a raw subscription tier string (Claude's
    /// `subscriptionType` / Codex's `chatgpt_plan_type`). Plan names are
    /// brand terms Anthropic/OpenAI don't translate, so this just normalizes
    /// casing rather than localizing — `"max"` → `"Max"`, `"pro"` → `"Pro"`,
    /// an unrecognized value is capitalized as-is rather than hidden, so a
    /// new plan name upstream still shows *something* instead of vanishing.
    public static func subscriptionTierBadgeText(_ raw: String) -> String {
        let known: [String: String] = [
            "free": "Free",
            "pro": "Pro",
            "max": "Max",
            "go": "Go",
            "plus": "Plus",
            "team": "Team",
            "business": "Business",
            "enterprise": "Enterprise"
        ]
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return known[normalized] ?? raw.capitalized
    }
}
