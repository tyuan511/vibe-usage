import Foundation
import VibeUsageCore

/// A single rate-limit window reported by an upstream usage endpoint (e.g.
/// Claude's `five_hour`/`seven_day` windows, Codex's primary/secondary
/// windows), normalized into a shape the UI can render without knowing
/// anything about the source-specific JSON.
public struct QuotaWindow: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// Fraction of the window's quota already used, clamped to `0...1`.
    public let usedFraction: Double
    public let usedPercentText: String
    public let resetsAt: Date?
    public let resetCountdownText: String?

    public init(
        id: String,
        label: String,
        usedFraction: Double,
        usedPercentText: String,
        resetsAt: Date?,
        resetCountdownText: String?
    ) {
        self.id = id
        self.label = label
        self.usedFraction = min(max(usedFraction, 0), 1)
        self.usedPercentText = usedPercentText
        self.resetsAt = resetsAt
        self.resetCountdownText = resetCountdownText
    }
}

/// The state of a single quota source (Claude, Codex, ...) as of the most
/// recent fetch attempt.
public enum QuotaSourceState: Sendable, Equatable {
    /// The account is connected and the endpoint returned usable data.
    case ok([QuotaWindow])
    /// The user hasn't connected this account in-app yet.
    case notConnected
    /// The stored token was rejected (HTTP 401) even after a refresh attempt.
    case unauthorized
    /// A transport-level or decoding failure occurred.
    case networkError(String)
    /// Limit monitoring is turned off in settings.
    case disabled
}

/// One source's full quota state plus bookkeeping about when it was fetched.
public struct QuotaSourceSnapshot: Sendable, Equatable, Identifiable {
    public let sourceID: AgentSourceID
    public let displayName: String
    public let state: QuotaSourceState
    public let fetchedAt: Date
    /// Raw subscription tier string for a connected account (e.g. Claude's
    /// `"free"`/`"pro"`/`"max"`, Codex's `"free"`/`"go"`/`"plus"`/`"pro"`),
    /// whatever granularity the upstream source actually reports. `nil` when
    /// not connected or the tier isn't known.
    public let subscriptionTier: String?

    public var id: AgentSourceID { sourceID }

    public init(
        sourceID: AgentSourceID,
        displayName: String,
        state: QuotaSourceState,
        fetchedAt: Date,
        subscriptionTier: String? = nil
    ) {
        self.sourceID = sourceID
        self.displayName = displayName
        self.state = state
        self.fetchedAt = fetchedAt
        self.subscriptionTier = subscriptionTier
    }
}

/// Top-level snapshot of quota state across all configured sources.
public struct QuotaSnapshot: Sendable, Equatable {
    public let sources: [QuotaSourceSnapshot]
    public let generatedAt: Date

    public init(sources: [QuotaSourceSnapshot], generatedAt: Date) {
        self.sources = sources
        self.generatedAt = generatedAt
    }

    public static let empty = QuotaSnapshot(sources: [], generatedAt: .distantPast)
}
