import SwiftUI
import VibeUsageCore

/// Shared visual language for the dashboard window: a stable per-source color
/// palette (so chart/legend/tile colors never reshuffle between refreshes,
/// unlike Swift Charts' auto-assigned palette) plus the typography scale used
/// throughout the redesigned layout.
enum DashboardTheme {
    /// Hand-picked hues that stay legible in both light and dark appearances
    /// and are visually distinct from one another at a glance (chart bars,
    /// legend chips, tile accents, share bars).
    private static let palette: [Color] = [
        Color(hex: "007AFF"), // blue
        Color(hex: "FF9500"), // orange
        Color(hex: "34C759"), // green
        Color(hex: "AF52DE"), // purple
        Color(hex: "FF2D55"), // pink
        Color(hex: "30B0C7"), // teal
        Color(hex: "5856D6"), // indigo
        Color(hex: "FFCC00"), // yellow
        Color(hex: "FF3B30"), // red
        Color(hex: "00C7BE"), // mint
        Color(hex: "A2845E"), // brown
        Color(hex: "32ADE6") // cyan
    ]

    /// Deterministic color assignment from `sourceID.rawValue`, stable across
    /// launches and refreshes. With 13+ shipped adapters and a 12-color
    /// palette, a bare hash can collide; callers that render several sources
    /// side by side (chart, agent tiles) should use
    /// `colors(for:)` instead, which keeps this same base assignment but
    /// resolves collisions *within that specific set* via linear probing so
    /// two sources visible in the same view never look identical.
    static func color(for sourceID: AgentSourceID) -> Color {
        palette[Int(fnv1aHash(sourceID.rawValue) % UInt64(palette.count))]
    }

    /// Assigns colors to every source in `sourceIDs` (order-independent,
    /// stable across calls with the same set), starting from each source's
    /// base hash slot and probing forward to the next free slot when two
    /// sources in the set would otherwise collide. Falls back to sharing
    /// colors only once every palette slot is taken (13th+ simultaneous
    /// source).
    static func colors(for sourceIDs: [AgentSourceID]) -> [AgentSourceID: Color] {
        var assigned: [AgentSourceID: Color] = [:]
        var usedSlots = Set<Int>()
        // Deterministic iteration order regardless of caller's array order.
        for sourceID in sourceIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            let baseSlot = Int(fnv1aHash(sourceID.rawValue) % UInt64(palette.count))
            var slot = baseSlot
            var attempts = 0
            while usedSlots.contains(slot), attempts < palette.count {
                slot = (slot + 1) % palette.count
                attempts += 1
            }
            usedSlots.insert(slot)
            assigned[sourceID] = palette[slot]
        }
        return assigned
    }

    /// Muted, source-agnostic color for the "ungrouped" project bucket.
    static let ungroupedColor = Color.gray

    private static func fnv1aHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    // MARK: - Typography

    static let heroNumberFont = Font.system(size: 34, weight: .bold, design: .rounded).monospacedDigit()
    static let sectionTitleFont = Font.headline
    static let cardLabelFont = Font.caption

    // MARK: - Layout

    static let contentMaxWidth: CGFloat = 980
    static let sectionSpacing: CGFloat = 22
}
