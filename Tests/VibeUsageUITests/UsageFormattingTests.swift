import Testing
@testable import VibeUsageUI

@Suite struct UsageFormattingTests {
    @Test func compactStringUsesBillionsForBillionScaleValues() {
        #expect(1_000_000_000.compactString == "1B")
        #expect(1_250_000_000.compactString == "1.2B")
        #expect((-1_250_000_000).compactString == "-1.2B")
    }
}
