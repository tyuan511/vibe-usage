import Foundation

/// Per-file incremental-parse resume point. Adapters must be able to resume
/// parsing a file given a previously-returned checkpoint and produce exactly
/// the events that correspond to content appended since that checkpoint.
public struct ParseCheckpoint: Sendable, Codable, Equatable {
    /// Byte offset into the file where the next unparsed line begins.
    public var byteOffset: Int64
    /// Number of lines successfully parsed so far (0-indexed count, i.e. the
    /// index of the next line to parse).
    public var lineIndex: Int
    /// Adapter-private state needed to resume correctly, opaque to storage
    /// and to other adapters. For example, Codex's adapter stores the last
    /// observed cumulative `TokenCounts` here (JSON-encoded) so it can keep
    /// computing correct deltas after resuming mid-file.
    public var adapterState: Data?

    public init(byteOffset: Int64 = 0, lineIndex: Int = 0, adapterState: Data? = nil) {
        self.byteOffset = byteOffset
        self.lineIndex = lineIndex
        self.adapterState = adapterState
    }

    public static let start = ParseCheckpoint()
}

/// Result of an incremental parse pass over a single file.
public struct ParseResult: Sendable {
    public let events: [UsageEvent]
    public let newCheckpoint: ParseCheckpoint

    public init(events: [UsageEvent], newCheckpoint: ParseCheckpoint) {
        self.events = events
        self.newCheckpoint = newCheckpoint
    }
}
