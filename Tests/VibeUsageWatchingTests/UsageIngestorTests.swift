import Foundation
import Testing
import VibeUsageCore
@testable import VibeUsageWatching

@Test func ingestionSummaryStoresCounts() {
    let started = Date(timeIntervalSince1970: 1)
    let finished = Date(timeIntervalSince1970: 2)
    let summary = IngestionSummary(
        scannedFiles: 2,
        insertedEvents: 3,
        discoveredSourceIDs: [.claudeCode],
        startedAt: started,
        finishedAt: finished
    )

    #expect(summary.scannedFiles == 2)
    #expect(summary.insertedEvents == 3)
    #expect(summary.discoveredSourceIDs == [.claudeCode])
    #expect(summary.startedAt == started)
    #expect(summary.finishedAt == finished)
}
