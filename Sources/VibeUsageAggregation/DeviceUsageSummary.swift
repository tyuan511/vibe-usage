import Foundation

public struct DeviceUsageSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let isLocal: Bool
    public let lastSyncedAt: Date?
    public let totals: UsageTotals
    public let hasEstimatedCost: Bool

    public init(
        id: String,
        name: String,
        isLocal: Bool,
        lastSyncedAt: Date?,
        totals: UsageTotals,
        hasEstimatedCost: Bool
    ) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
        self.lastSyncedAt = lastSyncedAt
        self.totals = totals
        self.hasEstimatedCost = hasEstimatedCost
    }
}
