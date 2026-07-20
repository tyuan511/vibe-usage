import Darwin
import Foundation
import Testing
import VibeUsageCore
import VibeUsagePricing
import VibeUsageStorage
import XCTest
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
    ) { _ in
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
    ) { _ in
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

@Test func watchPathsMapChangedFilesToMatchingSources() throws {
    let rootA = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibe-usage-map-a-\(UUID().uuidString)", isDirectory: true)
    let rootB = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibe-usage-map-b-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: rootA)
        try? FileManager.default.removeItem(at: rootB)
    }

    let registry = AdapterRegistry()
    let adapterA = WatchPathTestAdapter(id: "map-a", root: rootA)
    let adapterB = WatchPathTestAdapter(id: "map-b", root: rootB)
    registry.register(adapterA)
    registry.register(adapterB)

    let changed = [rootA.appendingPathComponent("events.jsonl").path]
    let matched = UsageWatchPaths.sourceIDs(forChangedPaths: changed, registry: registry)
    #expect(matched == [adapterA.descriptor.id])
}

@Test func watchPathsReturnEmptyWhenPathIsUnmapped() {
    let registry = AdapterRegistry()
    registry.register(WatchPathTestAdapter(root: URL(fileURLWithPath: "/tmp/vibe-usage-unmapped-root")))
    let matched = UsageWatchPaths.sourceIDs(
        forChangedPaths: ["/tmp/some-other-path/events.jsonl"],
        registry: registry
    )
    #expect(matched.isEmpty)
}

@Test func ingestorRespectsSourceFilter() async throws {
    let environment = try IngestorTestEnvironment.make(extraAdapterIDs: ["ingestor-b"])
    defer { environment.cleanup() }

    try environment.writeLog("{\"line\":1}\n", adapterID: "ingestor-a")
    try environment.writeLog("{\"line\":1}\n", adapterID: "ingestor-b")

    let onlyA = try await environment.ingestor.scanOnce(
        sourceFilter: [AgentSourceID(rawValue: "ingestor-a")]
    )
    #expect(onlyA.discoveredSourceIDs == [AgentSourceID(rawValue: "ingestor-a")])
    #expect(onlyA.insertedEvents == 1)
}

@Test func ingestorRespectsChangedPathFilter() async throws {
    let environment = try IngestorTestEnvironment.make(extraAdapterIDs: ["ingestor-b"])
    defer { environment.cleanup() }

    try environment.writeLog("{\"line\":1}\n", adapterID: "ingestor-a")
    try environment.writeLog("{\"line\":1}\n", adapterID: "ingestor-b")

    let pathA = environment.root
        .appendingPathComponent("ingestor-a", isDirectory: true)
        .appendingPathComponent("events.jsonl")
        .path
    let summary = try await environment.ingestor.scanOnce(
        changedPaths: [pathA]
    )
    #expect(summary.discoveredSourceIDs == [AgentSourceID(rawValue: "ingestor-a")])
    #expect(summary.insertedEvents == 1)
}

final class UsageIngestorConcurrencyTests: XCTestCase {
    func testIngestorParsesFilesWithoutSaturatingMultipleCores() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-usage-concurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<4 {
            try Data([UInt8(index)]).write(to: root.appendingPathComponent("events-\(index).jsonl"))
        }

        let tracker = ParseConcurrencyTracker()
        let registry = AdapterRegistry()
        registry.register(ConcurrencyTrackingAdapter(root: root, tracker: tracker))
        let store = GRDBUsageEventStore(database: try UsageDatabase())
        let ingestor = UsageIngestor(registry: registry, store: store, pricing: BundledPricingProvider())

        let summary = try await ingestor.scanOnce()

        XCTAssertEqual(summary.scannedFiles, 4)
        XCTAssertEqual(tracker.maximumConcurrentParses, 1)
        XCTAssertLessThanOrEqual(tracker.maximumQoSClass, QOS_CLASS_UTILITY.rawValue)
    }
}

private func verifyIngestorPersistsParsedFilesAsOneBatch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibe-usage-batch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for index in 0..<3 {
        try Data([UInt8(index)]).write(to: root.appendingPathComponent("events-\(index).jsonl"))
    }

    let registry = AdapterRegistry()
    registry.register(ConcurrencyTrackingAdapter(root: root, tracker: ParseConcurrencyTracker()))
    let store = BatchRecordingStore(base: GRDBUsageEventStore(database: try UsageDatabase()))
    let ingestor = UsageIngestor(registry: registry, store: store, pricing: BundledPricingProvider())

    let summary = try await ingestor.scanOnce()

    XCTAssertEqual(summary.scannedFiles, 3)
    XCTAssertEqual(store.batchCallCount, 1)
    XCTAssertEqual(store.individualCallCount, 0)
}

final class UsageIngestorBatchTests: XCTestCase {
    func testPersistsParsedFilesAsOneBatch() async throws {
        try await verifyIngestorPersistsParsedFilesAsOneBatch()
    }
}

@Test func watchPathsNormalizeSQLiteSidecars() {
    let db = "/tmp/opencode.db"
    #expect(UsageWatchPaths.canonicalWatchPath(db + "-wal") == db)
    #expect(UsageWatchPaths.canonicalWatchPath(db + "-shm") == db)
    #expect(UsageWatchPaths.file(db, matchesChangedPaths: [db + "-wal"]))
}

private final class ParseConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var activeParses = 0
    private var recordedMaximum = 0
    private var recordedMaximumQoSClass: qos_class_t.RawValue = 0

    var maximumConcurrentParses: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedMaximum
    }

    var maximumQoSClass: qos_class_t.RawValue {
        lock.lock()
        defer { lock.unlock() }
        return recordedMaximumQoSClass
    }

    func begin(qosClass: qos_class_t.RawValue) {
        lock.lock()
        activeParses += 1
        recordedMaximum = max(recordedMaximum, activeParses)
        recordedMaximumQoSClass = max(recordedMaximumQoSClass, qosClass)
        lock.unlock()
    }

    func end() {
        lock.lock()
        activeParses -= 1
        lock.unlock()
    }
}

private final class BatchRecordingStore: UsageEventStore, @unchecked Sendable {
    private let base: GRDBUsageEventStore
    private let lock = NSLock()
    private var recordedBatchCalls = 0
    private var recordedIndividualCalls = 0

    init(base: GRDBUsageEventStore) {
        self.base = base
    }

    var batchCallCount: Int {
        lock.withLock { recordedBatchCalls }
    }

    var individualCallCount: Int {
        lock.withLock { recordedIndividualCalls }
    }

    func ensureSourceRegistered(_ descriptor: AgentSourceDescriptor) throws {
        try base.ensureSourceRegistered(descriptor)
    }

    func fileMetadata(forFile path: String) throws -> FileParseMetadata? {
        try base.fileMetadata(forFile: path)
    }

    func fileMetadata(forFiles paths: [String]) throws -> [String: FileParseMetadata] {
        try base.fileMetadata(forFiles: paths)
    }

    func applyParseResult(
        _ result: ParseResult,
        file: DiscoveredFile,
        fileSize: Int64,
        fileModifiedAt: Date?
    ) throws {
        lock.withLock { recordedIndividualCalls += 1 }
        try base.applyParseResult(
            result,
            file: file,
            fileSize: fileSize,
            fileModifiedAt: fileModifiedAt
        )
    }

    func applyParseResults(_ applications: [FileParseApplication]) throws {
        lock.withLock { recordedBatchCalls += 1 }
        try base.applyParseResults(applications)
    }

    func repriceEstimatedEvents(using pricing: any PricingProvider) throws -> Int {
        try base.repriceEstimatedEvents(using: pricing)
    }

    func resetFile(_ path: String) throws {
        try base.resetFile(path)
    }
}

private struct ConcurrencyTrackingAdapter: UsageSourceAdapter {
    let root: URL
    let tracker: ParseConcurrencyTracker

    var descriptor: AgentSourceDescriptor {
        AgentSourceDescriptor(
            id: AgentSourceID(rawValue: "concurrency-test"),
            displayName: "Concurrency Test",
            shortLabel: "Concurrency",
            iconSystemName: "gauge.with.dots.needle.67percent",
            tintColorHex: "#000000",
            sortOrder: 0
        )
    }

    func discoverRootDirectories() -> [URL] { [root] }

    func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        try roots.flatMap { root in
            try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).map { DiscoveredFile(path: $0.path, sourceID: descriptor.id) }
        }
    }

    func parseIncrementally(
        fileAt path: String,
        from checkpoint: ParseCheckpoint?,
        pricing: any PricingProvider
    ) throws -> ParseResult {
        tracker.begin(qosClass: qos_class_self().rawValue)
        defer { tracker.end() }
        Thread.sleep(forTimeInterval: 0.1)
        return ParseResult(
            events: [],
            newCheckpoint: ParseCheckpoint(byteOffset: 1, lineIndex: 1)
        )
    }
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
    let id: String
    let root: URL

    init(id: String = "watch-test", root: URL) {
        self.id = id
        self.root = root
    }

    var descriptor: AgentSourceDescriptor {
        AgentSourceDescriptor(
            id: AgentSourceID(rawValue: id),
            displayName: id,
            shortLabel: id,
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
