import Foundation

public struct SyncProfileDocument: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let deviceID: String
    public let name: String
    public let lastSyncedAt: Date

    public init(
        schemaVersion: Int = SyncDocumentCodec.schemaVersion,
        deviceID: String,
        name: String,
        lastSyncedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.name = name
        self.lastSyncedAt = lastSyncedAt
    }
}
