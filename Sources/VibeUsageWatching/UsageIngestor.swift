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
        let workerLimit = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        var results: [ParsedJob] = []
        results.reserveCapacity(jobs.count)

        try await withThrowingTaskGroup(of: ParsedJob.self) { group in
            var iterator = jobs.makeIterator()
            for _ in 0..<workerLimit {
                guard let job = iterator.next() else { break }
                group.addTask { [pricing] in
                    let result = try adapter.parseIncrementally(fileAt: job.file.path, from: job.checkpoint, pricing: pricing)
                    return ParsedJob(job: job, result: result)
                }
            }

            while let parsed = try await group.next() {
                results.append(parsed)
                if let next = iterator.next() {
                    group.addTask { [pricing] in
                        let result = try adapter.parseIncrementally(fileAt: next.file.path, from: next.checkpoint, pricing: pricing)
                        return ParsedJob(job: next, result: result)
                    }
                }
            }
        }
        return results
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
