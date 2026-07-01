import Foundation

/// Persisted bookkeeping for a single tracked file: where parsing last left
/// off, and what the file looked like at that time (used to cheaply detect
/// "nothing changed" and to detect truncation/rewrite).
public struct FileParseMetadata: Sendable, Equatable {
    public let checkpoint: ParseCheckpoint
    public let fileSizeAtParse: Int64
    public let fileModifiedAtParse: Date?

    public init(checkpoint: ParseCheckpoint, fileSizeAtParse: Int64, fileModifiedAtParse: Date?) {
        self.checkpoint = checkpoint
        self.fileSizeAtParse = fileSizeAtParse
        self.fileModifiedAtParse = fileModifiedAtParse
    }
}

/// Storage-facing contract. Implemented by ``VibeUsageStorage`` (GRDB-backed);
/// kept as a protocol in Core so watching/aggregation/tests can depend on the
/// abstraction rather than a concrete database.
public protocol UsageEventStore: Sendable {
    /// Registers (or updates the display name of) a source in the DB's lookup
    /// table. Idempotent.
    func ensureSourceRegistered(_ descriptor: AgentSourceDescriptor) throws

    /// Returns the last-known parse state for `path`, or nil if never parsed.
    func fileMetadata(forFile path: String) throws -> FileParseMetadata?

    /// Atomically persists the events and checkpoint produced by one
    /// `parseIncrementally` call, applying dedup/conflict-resolution against
    /// any existing rows with a colliding dedup key.
    func applyParseResult(
        _ result: ParseResult,
        file: DiscoveredFile,
        fileSize: Int64,
        fileModifiedAt: Date?
    ) throws

    /// Removes all persisted events and parse state for `path`. Used when a
    /// file is detected as truncated/rewritten (its recorded size shrank),
    /// forcing a clean reparse from the start.
    func resetFile(_ path: String) throws
}
