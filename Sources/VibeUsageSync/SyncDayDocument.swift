import Foundation

public struct SyncDayDocument: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let deviceID: String
    public let day: String
    public let generatedAt: Date
    public let buckets: [SyncUsageBucket]

    public init(
        schemaVersion: Int = SyncDocumentCodec.schemaVersion,
        deviceID: String,
        day: String,
        generatedAt: Date,
        buckets: [SyncUsageBucket]
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.day = day
        self.generatedAt = generatedAt
        self.buckets = buckets
    }
}
