import Foundation
import VibeUsageCore

public struct SyncedUsageBucket: Sendable, Equatable {
    public let deviceID: String
    public let hourUTC: String
    public let sourceID: AgentSourceID
    public let modelFamily: String
    public let tokens: TokenCounts
    public let costUSD: Decimal
    public let eventCount: Int
    public let estimatedEventCount: Int

    public init(
        deviceID: String,
        hourUTC: String,
        sourceID: AgentSourceID,
        modelFamily: String,
        tokens: TokenCounts,
        costUSD: Decimal,
        eventCount: Int,
        estimatedEventCount: Int
    ) {
        self.deviceID = deviceID
        self.hourUTC = hourUTC
        self.sourceID = sourceID
        self.modelFamily = modelFamily
        self.tokens = tokens
        self.costUSD = costUSD
        self.eventCount = eventCount
        self.estimatedEventCount = estimatedEventCount
    }
}
