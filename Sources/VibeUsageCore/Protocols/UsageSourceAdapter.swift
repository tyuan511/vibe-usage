import Foundation

/// The extensibility seam of the whole app. A new agent source is added by
/// creating one new type conforming to this protocol (plus its own SPM
/// target) and registering an instance with ``AdapterRegistry`` — no other
/// module needs to change.
///
/// Conformances own everything specific to their source: where its log files
/// live, how to recognize the relevant ones, how to parse a line, how to
/// dedupe/resolve conflicts within their own data, and how to map their raw
/// model identifiers to a pricing-lookup key. Storage, watching, aggregation,
/// and UI code only ever interact with sources through this protocol and
/// through ``AgentSourceDescriptor`` — never through source-specific types.
public protocol UsageSourceAdapter: Sendable {
    /// Static, UI-facing identity for this source.
    var descriptor: AgentSourceDescriptor { get }

    /// Root directories that should be watched and scanned for this source's
    /// log files. May depend on environment variables (e.g. `CLAUDE_CONFIG_DIR`,
    /// `CODEX_HOME`). Directories that don't exist are simply not returned.
    func discoverRootDirectories() -> [URL]

    /// Enumerates every file, under the given roots, that this adapter
    /// considers a live source of usage data right now. Responsible for any
    /// source-specific file-level dedup (e.g. Codex's `sessions/` winning over
    /// `archived_sessions/` for the same relative path) so that the returned
    /// list contains each logical file exactly once.
    func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile]

    /// Parses `path` starting from `checkpoint` (nil means "start of file") and
    /// returns only the usage events newly discoverable since that checkpoint,
    /// plus an updated checkpoint. Must be resumable: given the same checkpoint
    /// and an unchanged file prefix, re-parsing produces the same events.
    ///
    /// Implementations are responsible for their own within-file (and, where
    /// relevant, cross-file-within-this-source) dedup policy; the caller only
    /// guarantees at-least-once delivery of "this file may have changed".
    func parseIncrementally(
        fileAt path: String,
        from checkpoint: ParseCheckpoint?,
        pricing: PricingProvider
    ) throws -> ParseResult
}
