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

@Test func watchPathsIncludeOnlyExistingAdapterRoots() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibe-usage-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = AdapterRegistry()
    registry.register(WatchPathTestAdapter(root: directory))

    let paths = UsageWatchPaths.directories(from: registry)
    #expect(paths == [directory.standardizedFileURL.path])
}

@Test func watchPathsIgnoreMissingAdapterRoots() {
    let registry = AdapterRegistry()
    registry.register(WatchPathTestAdapter(root: URL(fileURLWithPath: "/tmp/vibe-usage-missing-\(UUID().uuidString)")))

    #expect(UsageWatchPaths.directories(from: registry).isEmpty)
}

private struct WatchPathTestAdapter: UsageSourceAdapter {
    let root: URL

    var descriptor: AgentSourceDescriptor {
        AgentSourceDescriptor(
            id: AgentSourceID(rawValue: "watch-test"),
            displayName: "Watch Test",
            shortLabel: "Watch",
            iconSystemName: "folder",
            tintColorHex: "#000000",
            sortOrder: 999
        )
    }

    func discoverRootDirectories() -> [URL] {
        [root]
    }

    func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        []
    }

    func parseIncrementally(
        fileAt path: String,
        from checkpoint: ParseCheckpoint?,
        pricing: any PricingProvider
    ) throws -> ParseResult {
        ParseResult(events: [], newCheckpoint: checkpoint ?? .start)
    }
}
