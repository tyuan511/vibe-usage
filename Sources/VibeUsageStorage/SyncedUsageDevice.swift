import Foundation

public struct SyncedUsageDevice: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let lastSyncedAt: Date?
    public let isLocal: Bool

    public init(id: String, name: String, lastSyncedAt: Date?, isLocal: Bool) {
        self.id = id
        self.name = name
        self.lastSyncedAt = lastSyncedAt
        self.isLocal = isLocal
    }
}
