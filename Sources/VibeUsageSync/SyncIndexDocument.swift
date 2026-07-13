import Foundation

public struct SyncIndexDocument: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let deviceID: String
    public let updatedAt: Date
    public let days: [SyncDayReference]

    public init(
        schemaVersion: Int = SyncDocumentCodec.schemaVersion,
        deviceID: String,
        updatedAt: Date,
        days: [SyncDayReference]
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.updatedAt = updatedAt
        self.days = days
    }
}
