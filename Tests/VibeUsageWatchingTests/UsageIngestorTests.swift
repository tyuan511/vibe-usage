import Foundation
import Testing
import VibeUsageCore
import VibeUsagePricing
import VibeUsageStorage
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

@Test func ingestorSkipsUnmodifiedFiles() async throws {
    let environment = try IngestorTestEnvironment.make()
    defer { environment.cleanup() }

    try environment.writeLog("{\"line\":1}\n")
    let first = try await environment.ingestor.scanOnce()
    #expect(first.scannedFiles == 1)
    #expect(first.insertedEvents == 1)
    #expect(first.skippedFiles == 0)

    let second = try await environment.ingestor.scanOnce()
    #expect(second.scannedFiles == 0)
    #expect(second.skippedFiles == 1)
    #expect(second.insertedEvents == 0)
}

@Test func ingestorResetsWhenFileShrinks() async throws {
    let environment = try IngestorTestEnvironment.make()
    defer { environment.cleanup() }

    try environment.writeLog("{\"line\":1}\n{\"line\":2}\n")
    let first = try await environment.ingestor.scanOnce()
    #expect(first.insertedEvents == 1)

    try environment.writeLog("{\"line\":1}\n")
    let second = try await environment.ingestor.scanOnce()
    #expect(second.scannedFiles == 1)
    #expect(second.insertedEvents == 1)
}

@Test func ingestorDiscoversMultipleRegisteredAdapters() async throws {
    let environment = try IngestorTestEnvironment.make(extraAdapterIDs: ["ingestor-b"])
    defer { environment.cleanup() }

    try environment.writeLog("{\"line\":1}\n", adapterID: "ingestor-a")
    try environment.writeLog("{\"line\":1}\n", adapterID: "ingestor-b")

    let summary = try await environment.ingestor.scanOnce()
    #expect(summary.discoveredSourceIDs.count == 2)
    #expect(summary.insertedEvents == 2)
}

@Test func coordinatorTriggersInitialRefresh() async throws {
    let counter = RefreshCounter()
    let registry = AdapterRegistry()
    let coordinator = UsageAutoRefreshCoordinator(
        registry: registry,
        refreshInterval: 3600,
        debounceInterval: 0.05
    ) {
        await counter.increment()
    }

    coordinator.start()
    try await Task.sleep(for: .milliseconds(150))
    coordinator.stop()

    let count = await counter.value
    #expect(count >= 1)
}

@Test func coordinatorDebouncesRapidFileChanges() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibe-usage-debounce-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let registry = AdapterRegistry()
    registry.register(WatchPathTestAdapter(root: directory))

    let counter = RefreshCounter()
    let coordinator = UsageAutoRefreshCoordinator(
        registry: registry,
        refreshInterval: 3600,
        debounceInterval: 0.15
    ) {
        await counter.increment()
    }

    coordinator.start()
    try await Task.sleep(for: .milliseconds(50))
    let afterStart = await counter.value
    #expect(afterStart >= 1)

    let logFile = directory.appendingPathComponent("events.jsonl")
    for index in 0..<4 {
        try Data("{\"i\":\(index)}\n".utf8).write(to: logFile)
        try await Task.sleep(for: .milliseconds(20))
    }

    try await Task.sleep(for: .milliseconds(400))
    coordinator.stop()

    let finalCount = await counter.value
    #expect(finalCount <= afterStart + 2)
}

private actor RefreshCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private struct IngestorTestEnvironment {
    let root: URL
    let registry: AdapterRegistry
    let ingestor: UsageIngestor

    static func make(extraAdapterIDs: [String] = []) throws -> IngestorTestEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-ingestor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let registry = AdapterRegistry()
        registry.register(IngestorTestAdapter(id: "ingestor-a", root: root.appendingPathComponent("ingestor-a", isDirectory: true)))
        for extraID in extraAdapterIDs {
            registry.register(IngestorTestAdapter(id: extraID, root: root.appendingPathComponent(extraID, isDirectory: true)))
        }

        let store = GRDBUsageEventStore(database: try UsageDatabase())
        let ingestor = UsageIngestor(registry: registry, store: store, pricing: BundledPricingProvider())
        return IngestorTestEnvironment(root: root, registry: registry, ingestor: ingestor)
    }

    func writeLog(_ contents: String, adapterID: String = "ingestor-a") throws {
        let adapterRoot = root.appendingPathComponent(adapterID, isDirectory: true)
        try FileManager.default.createDirectory(at: adapterRoot, withIntermediateDirectories: true)
        let file = adapterRoot.appendingPathComponent("events.jsonl")
        try Data(contents.utf8).write(to: file)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct IngestorTestAdapter: UsageSourceAdapter {
    let id: String
    let root: URL

    var descriptor: AgentSourceDescriptor {
        AgentSourceDescriptor(
            id: AgentSourceID(rawValue: id),
            displayName: id,
            shortLabel: id,
            iconSystemName: "folder",
            tintColorHex: "#000000",
            sortOrder: 0
        )
    }

    func discoverRootDirectories() -> [URL] { [root] }

    func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        roots.flatMap { root in
            let file = root.appendingPathComponent("events.jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else { return [DiscoveredFile]() }
            return [DiscoveredFile(path: file.path, sourceID: descriptor.id)]
        }
    }

    func parseIncrementally(
        fileAt path: String,
        from checkpoint: ParseCheckpoint?,
        pricing: any PricingProvider
    ) throws -> ParseResult {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let start = max(0, Int(checkpoint?.byteOffset ?? 0))
        let newEvents = max(0, data.count - start)
        guard newEvents > 0 else {
            return ParseResult(events: [], newCheckpoint: checkpoint ?? .start)
        }

        let event = UsageEvent(
            sourceID: descriptor.id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            sessionID: "session",
            projectOrWorkspace: nil,
            requestID: nil,
            model: "claude-sonnet-4",
            modelFamily: "claude-sonnet-4",
            tokens: TokenCounts(input: newEvents, output: 0),
            costUSD: Decimal(newEvents) / 100,
            costIsEstimated: true,
            dedupKey: "\(path)-\(data.count)",
            sourceFilePath: path,
            sourceFileLine: 1
        )
        return ParseResult(
            events: [event],
            newCheckpoint: ParseCheckpoint(byteOffset: Int64(data.count), lineIndex: 1)
        )
    }
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

    func discoverRootDirectories() -> [URL] { [root] }

    func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] { [] }

    func parseIncrementally(
        fileAt path: String,
        from checkpoint: ParseCheckpoint?,
        pricing: any PricingProvider
    ) throws -> ParseResult {
        ParseResult(events: [], newCheckpoint: checkpoint ?? .start)
    }
}
