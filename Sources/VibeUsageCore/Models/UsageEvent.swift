import Foundation

/// One normalized, deduplicated usage record, agent-agnostic, as produced by
/// an adapter's `parseIncrementally` and as persisted to storage.
public struct UsageEvent: Sendable, Equatable {
    public let sourceID: AgentSourceID
    public let timestamp: Date
    public let sessionID: String
    public let projectOrWorkspace: String?
    public let requestID: String?
    /// Raw model identifier exactly as seen in the log line (e.g. "claude-sonnet-4-20250514").
    public let model: String
    /// Alias-resolved key used for pricing lookup and for grouping in the "by model" view
    /// (e.g. "claude-sonnet-4").
    public let modelFamily: String
    public let tokens: TokenCounts
    public let costUSD: Decimal
    /// True when `costUSD` was computed from a pricing-table fallback (e.g. missing
    /// pricing entry, or a Codex log with no model metadata) rather than a source-
    /// reported cost or a confident pricing match.
    public let costIsEstimated: Bool
    /// Stable key used for idempotent upsert / cross-file dedup within a source.
    public let dedupKey: String
    /// True when this event is a sidechain replay of a parent message (Claude Code
    /// `/btw` side-question logs). Used purely for dedup tie-breaking and auditability;
    /// never affects UI grouping.
    public let isSidechainReplay: Bool
    public let sourceFilePath: String
    public let sourceFileLine: Int?

    public init(
        sourceID: AgentSourceID,
        timestamp: Date,
        sessionID: String,
        projectOrWorkspace: String?,
        requestID: String?,
        model: String,
        modelFamily: String,
        tokens: TokenCounts,
        costUSD: Decimal,
        costIsEstimated: Bool,
        dedupKey: String,
        isSidechainReplay: Bool = false,
        sourceFilePath: String,
        sourceFileLine: Int?
    ) {
        self.sourceID = sourceID
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.projectOrWorkspace = projectOrWorkspace
        self.requestID = requestID
        self.model = model
        self.modelFamily = modelFamily
        self.tokens = tokens
        self.costUSD = costUSD
        self.costIsEstimated = costIsEstimated
        self.dedupKey = dedupKey
        self.isSidechainReplay = isSidechainReplay
        self.sourceFilePath = sourceFilePath
        self.sourceFileLine = sourceFileLine
    }
}

/// A JSONL (or other per-file log format) file discovered by an adapter as
/// relevant to its source.
public struct DiscoveredFile: Sendable, Hashable {
    public let path: String
    public let sourceID: AgentSourceID

    public init(path: String, sourceID: AgentSourceID) {
        self.path = path
        self.sourceID = sourceID
    }
}
