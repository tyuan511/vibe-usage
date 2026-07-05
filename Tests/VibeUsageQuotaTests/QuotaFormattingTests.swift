import Foundation
import Testing
@testable import VibeUsageQuota

@Suite struct QuotaFormattingTests {
    @Test func percentTextRoundsToNearestInteger() {
        #expect(QuotaFormatting.percentText(usedFraction: 0.874) == "87%")
        #expect(QuotaFormatting.percentText(usedFraction: 0.876) == "88%")
        #expect(QuotaFormatting.percentText(usedFraction: 0) == "0%")
        #expect(QuotaFormatting.percentText(usedFraction: 1) == "100%")
    }

    @Test func percentTextClampsOutOfRangeFractions() {
        #expect(QuotaFormatting.percentText(usedFraction: 1.5) == "100%")
        #expect(QuotaFormatting.percentText(usedFraction: -0.2) == "0%")
    }

    @Test func countdownTextReturnsNilForPastOrNilDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(QuotaFormatting.countdownText(resetsAt: nil, now: now) == nil)
        #expect(QuotaFormatting.countdownText(resetsAt: now.addingTimeInterval(-10), now: now) == nil)
    }

    @Test func countdownTextFormatsHoursAndMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetsAt = now.addingTimeInterval(3 * 3600 + 12 * 60)
        let text = QuotaFormatting.countdownText(resetsAt: resetsAt, now: now)
        #expect(text != nil)
        // Bilingual output depends on locale; just assert it mentions the hour count.
        #expect(text?.contains("3") == true)
    }

    @Test func countdownTextFormatsDaysAndHoursForLongWindows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetsAt = now.addingTimeInterval(2 * 86400 + 5 * 3600)
        let text = QuotaFormatting.countdownText(resetsAt: resetsAt, now: now)
        #expect(text != nil)
        #expect(text?.contains("2") == true)
    }

    @Test func countdownTextFormatsMinutesOnlyForSubHourWindows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetsAt = now.addingTimeInterval(15 * 60)
        let text = QuotaFormatting.countdownText(resetsAt: resetsAt, now: now)
        #expect(text != nil)
        #expect(text?.contains("15") == true)
    }

    @Test func subscriptionTierBadgeTextNormalizesKnownValues() {
        #expect(QuotaFormatting.subscriptionTierBadgeText("free") == "Free")
        #expect(QuotaFormatting.subscriptionTierBadgeText("MAX") == "Max")
        #expect(QuotaFormatting.subscriptionTierBadgeText("go") == "Go")
        #expect(QuotaFormatting.subscriptionTierBadgeText("plus") == "Plus")
    }

    @Test func subscriptionTierBadgeTextCapitalizesUnknownValues() {
        #expect(QuotaFormatting.subscriptionTierBadgeText("mystery_tier") == "Mystery_Tier")
    }
}
