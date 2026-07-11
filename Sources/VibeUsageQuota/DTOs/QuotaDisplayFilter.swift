import VibeUsageCore

/// Applies the user's display-only preferences to quota snapshots. Hiding a
/// source here never changes its connection state or polling behavior.
public enum QuotaDisplayFilter {
    public static func visibleSources(
        from sources: [QuotaSourceSnapshot],
        hiddenSourceIDs: Set<AgentSourceID>
    ) -> [QuotaSourceSnapshot] {
        sources.filter { !hiddenSourceIDs.contains($0.sourceID) }
    }
}
