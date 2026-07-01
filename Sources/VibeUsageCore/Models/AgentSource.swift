import Foundation

/// Stable identifier for a usage data source (e.g. Claude Code, Codex CLI).
///
/// Deliberately a string-backed struct rather than a Swift `enum` so that
/// adding a new agent later never requires touching an exhaustive `switch`
/// anywhere in aggregation or UI code — new adapters simply mint their own id.
public struct AgentSourceID: Hashable, Codable, RawRepresentable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension AgentSourceID: CustomStringConvertible {
    public var description: String { rawValue }
}

public extension AgentSourceID {
    /// Convenience constants for the adapters shipped in this repo. These are
    /// just typed shortcuts for adapter authors — nothing in Core, Storage,
    /// Aggregation, or UI switches on them.
    static let claudeCode = AgentSourceID(rawValue: "claude-code")
    static let codexCLI = AgentSourceID(rawValue: "codex-cli")
}

/// Everything the UI needs to render a source, without knowing anything else
/// about it. Populated by each adapter and exposed via ``AdapterRegistry``.
public struct AgentSourceDescriptor: Identifiable, Hashable, Sendable {
    public let id: AgentSourceID
    public let displayName: String
    public let shortLabel: String
    public let iconSystemName: String
    public let tintColorHex: String
    public let sortOrder: Int

    public init(
        id: AgentSourceID,
        displayName: String,
        shortLabel: String,
        iconSystemName: String,
        tintColorHex: String,
        sortOrder: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.shortLabel = shortLabel
        self.iconSystemName = iconSystemName
        self.tintColorHex = tintColorHex
        self.sortOrder = sortOrder
    }
}
