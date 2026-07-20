import Foundation
import VibeUsageCore

public struct IngestionSummary: Sendable, Equatable {
    public let scannedFiles: Int
    public let skippedFiles: Int
    public let insertedEvents: Int
    public let discoveredSourceIDs: Set<AgentSourceID>
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        scannedFiles: Int,
        skippedFiles: Int = 0,
        insertedEvents: Int,
        discoveredSourceIDs: Set<AgentSourceID> = [],
        startedAt: Date,
        finishedAt: Date
    ) {
        self.scannedFiles = scannedFiles
        self.skippedFiles = skippedFiles
        self.insertedEvents = insertedEvents
        self.discoveredSourceIDs = discoveredSourceIDs
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public final class UsageIngestor: Sendable {
    private let registry: AdapterRegistry
    private let store: any UsageEventStore
    private let pricing: any PricingProvider
    /// Parsing is CPU-bound. Keep it serial and below user-initiated work so a
    /// large first import cannot make the rest of the system unresponsive.
    private let parseQueue = DispatchQueue(label: "com.vibeusage.ingestion-parse", qos: .utility)

    public init(
        registry: AdapterRegistry = .shared,
        store: any UsageEventStore,
        pricing: any PricingProvider
    ) {
        self.registry = registry
        self.store = store
        self.pricing = pricing
    }

    public func scanOnce(
        sourceFilter: Set<AgentSourceID> = [],
        changedPaths: Set<String>? = nil
    ) async throws -> IngestionSummary {
        let started = Date()
        var scannedFiles = 0
        var skippedFiles = 0
        var insertedEvents = 0
        var discoveredSourceIDs = Set<AgentSourceID>()

        for adapter in registry.allAdapters where sourceFilter.isEmpty || sourceFilter.contains(adapter.descriptor.id) {
            let roots = adapter.discoverRootDirectories()
            var files = try adapter.discoverFiles(in: roots)
            if let changedPaths {
                files = files.filter { UsageWatchPaths.file($0.path, matchesChangedPaths: changedPaths) }
            }
            guard !files.isEmpty else { continue }

            discoveredSourceIDs.insert(adapter.descriptor.id)
            try store.ensureSourceRegistered(adapter.descriptor)

            let metadataByPath = try store.fileMetadata(forFiles: files.map(\.path))
            let jobs = try files.compactMap { file -> ScanJob? in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return nil }
                let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let modifiedAt = attributes[.modificationDate] as? Date
                let metadata = metadataByPath[file.path]

                if let metadata,
                   fileSize == metadata.fileSizeAtParse,
                   !Self.fileWasModified(after: metadata.fileModifiedAtParse, currentModifiedAt: modifiedAt) {
                    skippedFiles += 1
                    return nil
                }

                if let metadata, fileSize < metadata.fileSizeAtParse {
                    try store.resetFile(file.path)
                    return ScanJob(file: file, checkpoint: nil, fileSize: fileSize, modifiedAt: modifiedAt)
                }
                return ScanJob(file: file, checkpoint: metadata?.checkpoint, fileSize: fileSize, modifiedAt: modifiedAt)
            }

            let parsed = try await parse(jobs: jobs, adapter: adapter)
            for item in parsed {
                try store.applyParseResult(
                    item.result,
                    file: item.job.file,
                    fileSize: item.job.fileSize,
                    fileModifiedAt: item.job.modifiedAt
                )
                scannedFiles += 1
                insertedEvents += item.result.events.count
            }
        }

        return IngestionSummary(
            scannedFiles: scannedFiles,
            skippedFiles: skippedFiles,
            insertedEvents: insertedEvents,
            discoveredSourceIDs: discoveredSourceIDs,
            startedAt: started,
            finishedAt: Date()
        )
    }

    private func parse(jobs: [ScanJob], adapter: any UsageSourceAdapter) async throws -> [ParsedJob] {
        try await withCheckedThrowingContinuation { continuation in
            parseQueue.async { [pricing] in
                do {
                    let results = try jobs.map { job in
                        let result = try adapter.parseIncrementally(
                            fileAt: job.file.path,
                            from: job.checkpoint,
                            pricing: pricing
                        )
                        return ParsedJob(job: job, result: result)
                    }
                    continuation.resume(returning: results)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fileWasModified(after stored: Date?, currentModifiedAt: Date?) -> Bool {
        guard let stored, let currentModifiedAt else { return false }
        return currentModifiedAt.timeIntervalSince(stored) > 0.001
    }
}

private struct ScanJob: Sendable {
    let file: DiscoveredFile
    let checkpoint: ParseCheckpoint?
    let fileSize: Int64
    let modifiedAt: Date?
}

private struct ParsedJob: Sendable {
    let job: ScanJob
    let result: ParseResult
}
