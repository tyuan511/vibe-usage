import VibeUsageCore

/// Generic conflict-resolution rule applied whenever an incoming event's
/// `(source_id, dedup_key)` collides with an already-persisted row. Written
/// once, reused by every adapter (not just Claude, whose sidechain replays
/// are the primary reason this exists): prefer a non-sidechain-replay copy
/// over a sidechain replay; when that's not the deciding factor, prefer the
/// copy with the larger total token count (mirrors ccusage's
/// `should_replace_deduped_entry`).
enum DedupPolicy {
    static func shouldReplace(existing: UsageEvent, candidate: UsageEvent) -> Bool {
        if candidate.isSidechainReplay != existing.isSidechainReplay {
            return existing.isSidechainReplay
        }
        return candidate.tokens.total > existing.tokens.total
    }
}
