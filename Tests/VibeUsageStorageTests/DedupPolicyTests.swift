import Foundation
import Testing
import VibeUsageCore
@testable import VibeUsageStorage

private func makeEvent(
    tokens: TokenCounts = TokenCounts(input: 10),
    isSidechainReplay: Bool = false
) -> UsageEvent {
    UsageEvent(
        sourceID: .claudeCode,
        timestamp: Date(timeIntervalSince1970: 0),
        sessionID: "session",
        projectOrWorkspace: nil,
        requestID: nil,
        model: "claude-sonnet-4-20250514",
        modelFamily: "claude-sonnet-4",
        tokens: tokens,
        costUSD: 0,
        costIsEstimated: false,
        dedupKey: "dedup",
        isSidechainReplay: isSidechainReplay,
        sourceFilePath: "/tmp/file.jsonl",
        sourceFileLine: 1
    )
}

@Test func nonSidechainCandidateReplacesSidechainExisting() {
    let existing = makeEvent(isSidechainReplay: true)
    let candidate = makeEvent(isSidechainReplay: false)
    #expect(DedupPolicy.shouldReplace(existing: existing, candidate: candidate))
}

@Test func sidechainCandidateNeverReplacesNonSidechainExisting() {
    let existing = makeEvent(isSidechainReplay: false)
    let candidate = makeEvent(tokens: TokenCounts(input: 1_000), isSidechainReplay: true)
    #expect(!DedupPolicy.shouldReplace(existing: existing, candidate: candidate))
}

@Test func largerTokenTotalWinsWhenSidechainStatusMatches() {
    let existing = makeEvent(tokens: TokenCounts(input: 10))
    let candidate = makeEvent(tokens: TokenCounts(input: 20))
    #expect(DedupPolicy.shouldReplace(existing: existing, candidate: candidate))
    #expect(!DedupPolicy.shouldReplace(existing: candidate, candidate: existing))
}
