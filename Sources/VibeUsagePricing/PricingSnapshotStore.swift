import Foundation

/// Persists the last successfully downloaded pricing snapshot outside the app
/// bundle so it can survive application updates.
public struct PricingSnapshotStore: Sendable {
    public static let automaticRefreshInterval: TimeInterval = 24 * 60 * 60

    public let directoryURL: URL

    public init() {
        self.init(directoryURL: Self.defaultDirectoryURL())
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public var snapshotURL: URL {
        directoryURL.appendingPathComponent("model_prices.json")
    }

    public var lastUpdatedAt: Date? {
        try? snapshotURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Whether the last successful remote snapshot is older than one day.
    /// An app with no downloaded snapshot should refresh immediately.
    public func needsAutomaticRefresh(at date: Date = Date()) -> Bool {
        guard let lastUpdatedAt else { return true }
        return date.timeIntervalSince(lastUpdatedAt) >= Self.automaticRefreshInterval
    }

    /// A failed background request is also throttled for one day, while a
    /// fresh local snapshot suppresses automatic requests altogether.
    public func shouldAttemptAutomaticRefresh(
        lastAttemptAt: Date?,
        at date: Date = Date()
    ) -> Bool {
        guard needsAutomaticRefresh(at: date) else { return false }
        guard let lastAttemptAt else { return true }
        return date.timeIntervalSince(lastAttemptAt) >= Self.automaticRefreshInterval
    }

    func loadSnapshot() -> PricingSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(PricingSnapshot.self, from: data)
    }

    func save(_ snapshot: PricingSnapshot) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.pricingSnapshot.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    private static func defaultDirectoryURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport.appendingPathComponent("VibeUsage", isDirectory: true)
    }
}

private extension JSONEncoder {
    static let pricingSnapshot: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
