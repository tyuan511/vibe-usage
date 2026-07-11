import Foundation
import Testing
import VibeUsageCore
@testable import VibeUsageQuota

@Suite struct QuotaDisplayFilterTests {
    @Test func keepsOnlySourcesTheUserHasNotHidden() {
        let claude = makeSource(.claudeQuota)
        let codex = makeSource(.codexQuota)

        let visible = QuotaDisplayFilter.visibleSources(
            from: [claude, codex],
            hiddenSourceIDs: [.claudeQuota]
        )

        #expect(visible == [codex])
    }

    @Test func returnsNoSourcesWhenEveryQuotaCardIsHidden() {
        let sources = [makeSource(.claudeQuota), makeSource(.codexQuota)]

        let visible = QuotaDisplayFilter.visibleSources(
            from: sources,
            hiddenSourceIDs: [.claudeQuota, .codexQuota]
        )

        #expect(visible.isEmpty)
    }

    private func makeSource(_ sourceID: AgentSourceID) -> QuotaSourceSnapshot {
        QuotaSourceSnapshot(
            sourceID: sourceID,
            displayName: sourceID == .claudeQuota ? "Claude" : "Codex",
            state: .notConnected,
            fetchedAt: .distantPast
        )
    }
}
