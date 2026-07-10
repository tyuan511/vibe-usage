import Foundation
import GRDB
import VibeUsageCore

struct UsageEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "usage_event"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64?
    var sourceId: String
    var dedupKey: String
    var isSidechainReplay: Bool?
    var timestampUtc: Date
    var sessionId: String
    var projectOrWorkspace: String?
    var requestId: String?
    var modelRaw: String
    var modelFamily: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreateTokens: Int
    var cacheReadTokens: Int
    var reasoningTokens: Int
    var costUsd: Double
    var costIsEstimated: Bool
    var sourceFilePath: String
    var sourceFileLine: Int?
    var createdAt: Date

    var tokens: TokenCounts {
        TokenCounts(
            input: inputTokens,
            output: outputTokens,
            cacheCreate: cacheCreateTokens,
            cacheRead: cacheReadTokens,
            reasoning: reasoningTokens
        )
    }

    init(id: Int64? = nil, event: UsageEvent, createdAt: Date = Date()) {
        self.id = id
        self.sourceId = event.sourceID.rawValue
        self.dedupKey = event.dedupKey
        self.isSidechainReplay = event.isSidechainReplay
        self.timestampUtc = event.timestamp
        self.sessionId = event.sessionID
        self.projectOrWorkspace = event.projectOrWorkspace
        self.requestId = event.requestID
        self.modelRaw = event.model
        self.modelFamily = event.modelFamily
        self.inputTokens = event.tokens.input
        self.outputTokens = event.tokens.output
        self.cacheCreateTokens = event.tokens.cacheCreate
        self.cacheReadTokens = event.tokens.cacheRead
        self.reasoningTokens = event.tokens.reasoning
        self.costUsd = (event.costUSD as NSDecimalNumber).doubleValue
        self.costIsEstimated = event.costIsEstimated
        self.sourceFilePath = event.sourceFilePath
        self.sourceFileLine = event.sourceFileLine
        self.createdAt = createdAt
    }

    func toUsageEvent() -> UsageEvent {
        UsageEvent(
            sourceID: AgentSourceID(rawValue: sourceId),
            timestamp: timestampUtc,
            sessionID: sessionId,
            projectOrWorkspace: projectOrWorkspace,
            requestID: requestId,
            model: modelRaw,
            modelFamily: modelFamily,
            tokens: tokens,
            costUSD: Decimal(costUsd),
            costIsEstimated: costIsEstimated,
            dedupKey: dedupKey,
            isSidechainReplay: isSidechainReplay ?? false,
            sourceFilePath: sourceFilePath,
            sourceFileLine: sourceFileLine
        )
    }
}
