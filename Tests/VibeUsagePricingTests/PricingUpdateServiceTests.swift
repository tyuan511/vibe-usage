import Foundation
import Testing
import VibeUsageCore
@testable import VibeUsagePricing

@Test func manualUpdatePersistsRepositorySnapshotAndOverridesBundledPricing() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PricingUpdateServiceTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = PricingSnapshotStore(directoryURL: directory)
    let service = PricingUpdateService(
        fetcher: PricingDataFetcherStub(data: try completeSnapshotData(overrides: [
            "gpt-5": PricingSnapshotEntry(
                inputPerMillion: 2,
                outputPerMillion: 10,
                cacheWritePerMillion: 2.5,
                cacheReadPerMillion: 0.2
            ),
            "kimi-k2": PricingSnapshotEntry(
                inputPerMillion: 1,
                outputPerMillion: 4,
                cacheWritePerMillion: nil,
                cacheReadPerMillion: nil
            )
        ])),
        store: store
    )

    let result = try await service.update()
    let provider = BundledPricingProvider(localSnapshotURL: store.snapshotURL)

    #expect(result.modelCount == 108)
    #expect(provider.rate(forModelFamily: "gpt-5") == ModelPricingRate(
        inputPerMillion: 2,
        outputPerMillion: 10,
        cacheWritePerMillion: 2.5,
        cacheReadPerMillion: 0.2
    ))
    #expect(provider.rate(forModelFamily: "kimi-k2") == ModelPricingRate(
        inputPerMillion: 1,
        outputPerMillion: 4
    ))
    #expect(store.lastUpdatedAt != nil)
}

@Test func incompleteManualUpdatePreservesLastSuccessfulSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PricingUpdateServiceTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = PricingSnapshotStore(directoryURL: directory)
    try store.save([
        "gpt-5": PricingSnapshotEntry(
            inputPerMillion: 3,
            outputPerMillion: 12,
            cacheWritePerMillion: nil,
            cacheReadPerMillion: nil
        )
    ])
    let snapshotBeforeUpdate = try Data(contentsOf: store.snapshotURL)
    let service = PricingUpdateService(fetcher: PricingDataFetcherStub(data: Data("""
    {
      "gpt-5": {
        "inputPerMillion": 2,
        "outputPerMillion": 10
      }
    }
    """.utf8)), store: store)

    await #expect(throws: PricingUpdateError.invalidSnapshot) {
        try await service.update()
    }

    #expect(try Data(contentsOf: store.snapshotURL) == snapshotBeforeUpdate)
}

@Test func failedManualUpdatePreservesLastSuccessfulSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PricingUpdateServiceTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = PricingSnapshotStore(directoryURL: directory)
    try store.save([
        "gpt-5": PricingSnapshotEntry(
            inputPerMillion: 3,
            outputPerMillion: 12,
            cacheWritePerMillion: nil,
            cacheReadPerMillion: nil
        )
    ])
    let snapshotBeforeUpdate = try Data(contentsOf: store.snapshotURL)
    let service = PricingUpdateService(fetcher: FailingPricingDataFetcher(), store: store)

    await #expect(throws: PricingDataFetcherError.unavailable) {
        try await service.update()
    }

    #expect(try Data(contentsOf: store.snapshotURL) == snapshotBeforeUpdate)
    let provider = BundledPricingProvider(localSnapshotURL: store.snapshotURL)
    #expect(provider.rate(forModelFamily: "gpt-5") == ModelPricingRate(inputPerMillion: 3, outputPerMillion: 12))
}

@Test func localSnapshotNeedsAutomaticRefreshOnlyAfterOneDay() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PricingUpdateServiceTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = PricingSnapshotStore(directoryURL: directory)
    #expect(store.needsAutomaticRefresh(at: Date()))

    try store.save([
        "gpt-5": PricingSnapshotEntry(
            inputPerMillion: 1,
            outputPerMillion: 2,
            cacheWritePerMillion: nil,
            cacheReadPerMillion: nil
        )
    ])
    let lastUpdatedAt = try #require(store.lastUpdatedAt)

    #expect(!store.needsAutomaticRefresh(at: lastUpdatedAt.addingTimeInterval(23 * 60 * 60)))
    #expect(store.needsAutomaticRefresh(at: lastUpdatedAt.addingTimeInterval(24 * 60 * 60)))
}

@Test func automaticRefreshAttemptIsThrottledForOneDay() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PricingUpdateServiceTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = PricingSnapshotStore(directoryURL: directory)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(store.shouldAttemptAutomaticRefresh(lastAttemptAt: nil, at: now))
    #expect(!store.shouldAttemptAutomaticRefresh(
        lastAttemptAt: now.addingTimeInterval(-23 * 60 * 60),
        at: now
    ))
    #expect(store.shouldAttemptAutomaticRefresh(
        lastAttemptAt: now.addingTimeInterval(-24 * 60 * 60),
        at: now
    ))

    try store.save([
        "gpt-5": PricingSnapshotEntry(
            inputPerMillion: 1,
            outputPerMillion: 2,
            cacheWritePerMillion: nil,
            cacheReadPerMillion: nil
        )
    ])
    #expect(!store.shouldAttemptAutomaticRefresh(lastAttemptAt: nil, at: Date()))
}

private struct PricingDataFetcherStub: PricingDataFetching {
    let data: Data

    func fetch(from _: URL) async throws -> Data {
        data
    }
}

private struct FailingPricingDataFetcher: PricingDataFetching {
    func fetch(from _: URL) async throws -> Data {
        throw PricingDataFetcherError.unavailable
    }
}

private enum PricingDataFetcherError: Error {
    case unavailable
}

private func completeSnapshotData(
    overrides: [String: PricingSnapshotEntry]
) throws -> Data {
    let standardRate = PricingSnapshotEntry(
        inputPerMillion: 1,
        outputPerMillion: 2,
        cacheWritePerMillion: nil,
        cacheReadPerMillion: nil
    )
    var snapshot: PricingSnapshot = [
        "gpt-5": standardRate,
        "claude-sonnet-4": standardRate,
        "grok-4": standardRate,
        "gemini-2.5-flash": standardRate,
        "deepseek-v3": standardRate,
        "glm-5": standardRate,
        "kimi-k2": standardRate,
        "MiniMax-M2.5": standardRate
    ]
    for index in 0..<100 {
        snapshot["fixture-model-\(index)"] = standardRate
    }
    snapshot.merge(overrides) { _, override in override }
    return try JSONEncoder().encode(snapshot)
}
