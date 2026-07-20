import Foundation
import Testing
@testable import VibeUsageAdapter

@Test func dateParserAcceptsSupportedISO8601Variants() throws {
    let plain = try #require(Date.vibeUsageParse("2026-07-20T08:47:23Z"))
    let fractional = try #require(Date.vibeUsageParse("2026-07-20T08:47:23.123456Z"))
    let offset = try #require(Date.vibeUsageParse("2026-07-20T16:47:23.123456+08:00"))

    #expect(abs(fractional.timeIntervalSince(plain) - 0.123456) < 0.000_001)
    #expect(abs(offset.timeIntervalSince(fractional)) < 0.000_001)
    #expect(Date.vibeUsageParse("not-a-date") == nil)
}
