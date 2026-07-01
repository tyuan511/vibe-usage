import Foundation

/// Normalized token breakdown for a single usage event, agent-agnostic.
///
/// Field meaning per source:
/// - Claude Code: `cacheCreate` = `cache_creation_input_tokens`,
///   `cacheRead` = `cache_read_input_tokens`, `reasoning` always 0.
/// - Codex CLI: `cacheCreate` always 0 (Codex has no cache-write concept),
///   `cacheRead` = cached input tokens, `reasoning` = reasoning output tokens
///   (already included in `output`, tracked separately for display only).
public struct TokenCounts: Sendable, Codable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheCreate: Int
    public var cacheRead: Int
    public var reasoning: Int

    public init(input: Int = 0, output: Int = 0, cacheCreate: Int = 0, cacheRead: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreate = cacheCreate
        self.cacheRead = cacheRead
        self.reasoning = reasoning
    }

    public var total: Int { input + output + cacheCreate + cacheRead + reasoning }

    public static let zero = TokenCounts()

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheCreate: lhs.cacheCreate + rhs.cacheCreate,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    /// Component-wise subtraction, used by adapters (e.g. Codex) that must
    /// diff a cumulative snapshot against the previously-seen cumulative
    /// snapshot to recover a per-turn delta. Clamped at zero per component to
    /// guard against out-of-order or corrected cumulative values.
    public static func - (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: max(0, lhs.input - rhs.input),
            output: max(0, lhs.output - rhs.output),
            cacheCreate: max(0, lhs.cacheCreate - rhs.cacheCreate),
            cacheRead: max(0, lhs.cacheRead - rhs.cacheRead),
            reasoning: max(0, lhs.reasoning - rhs.reasoning)
        )
    }
}
