import Foundation
import VibeUsageCore

public struct SyncUsageBucket: Sendable, Codable, Equatable {
    public let hourUTC: String
    public let sourceID: AgentSourceID
    public let modelFamily: String
    public let tokens: TokenCounts
    public let costUSD: Decimal
    public let eventCount: Int
    public let estimatedEventCount: Int

    public init(
        hourUTC: String,
        sourceID: AgentSourceID,
        modelFamily: String,
        tokens: TokenCounts,
        costUSD: Decimal,
        eventCount: Int,
        estimatedEventCount: Int
    ) {
        self.hourUTC = hourUTC
        self.sourceID = sourceID
        self.modelFamily = modelFamily
        self.tokens = tokens
        self.costUSD = costUSD
        self.eventCount = eventCount
        self.estimatedEventCount = estimatedEventCount
    }

    private enum CodingKeys: String, CodingKey {
        case hourUTC, sourceID, modelFamily, tokens, costUSD, eventCount, estimatedEventCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hourUTC = try container.decode(String.self, forKey: .hourUTC)
        sourceID = try container.decode(AgentSourceID.self, forKey: .sourceID)
        modelFamily = try container.decode(String.self, forKey: .modelFamily)
        tokens = try container.decode(TokenCounts.self, forKey: .tokens)
        let costString = try container.decode(String.self, forKey: .costUSD)
        guard let cost = Decimal(string: costString, locale: Locale(identifier: "en_US_POSIX")) else {
            throw SyncDocumentError.invalidDocument("costUSD is not a decimal")
        }
        costUSD = cost
        eventCount = try container.decode(Int.self, forKey: .eventCount)
        estimatedEventCount = try container.decode(Int.self, forKey: .estimatedEventCount)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hourUTC, forKey: .hourUTC)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(modelFamily, forKey: .modelFamily)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(NSDecimalNumber(decimal: costUSD).stringValue, forKey: .costUSD)
        try container.encode(eventCount, forKey: .eventCount)
        try container.encode(estimatedEventCount, forKey: .estimatedEventCount)
    }
}
