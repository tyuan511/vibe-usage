import SwiftUI
import VibeUsageAggregation
import VibeUsageCore

// MARK: - Merged project row model

/// A project rolled up across sources by `ProjectNameHumanizer` key. The raw
/// `ProjectUsageSummary` rows are grouped per (project, source); the same
/// real-world project reported by two agents (e.g. Claude Code's munged path
/// and OpenCode's real path resolving to the same directory) must appear as
/// a single row in the Projects section.
struct MergedProjectRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let isUngrouped: Bool
    let costUSD: Decimal
    let totalTokens: Int
    let sessionCount: Int
    /// Contributing sources, sorted by their share of this row's cost, descending.
    let sourceIDs: [AgentSourceID]

    var dominantSourceID: AgentSourceID? { sourceIDs.first }

    static func merge(
        projects: [ProjectUsageSummary],
        humanizer: ProjectNameHumanizer
    ) -> [MergedProjectRow] {
        struct Accumulator {
            var title = ""
            var subtitle: String?
            var isUngrouped = false
            var costUSD: Decimal = 0
            var totalTokens = 0
            var sessionCount = 0
            var costBySource: [AgentSourceID: Decimal] = [:]
        }

        var accumulators: [String: Accumulator] = [:]
        var order: [String] = []

        for project in projects {
            let humanized = humanizer.humanize(project.project)
            let key = humanized?.key ?? "__ungrouped__"

            if accumulators[key] == nil {
                var accumulator = Accumulator()
                if let humanized {
                    accumulator.title = humanized.title
                    accumulator.subtitle = humanized.subtitle
                    accumulator.isUngrouped = false
                } else {
                    accumulator.title = UIStrings.text(zh: "未分组", en: "Ungrouped")
                    accumulator.subtitle = nil
                    accumulator.isUngrouped = true
                }
                accumulators[key] = accumulator
                order.append(key)
            }

            accumulators[key]?.costUSD += project.costUSD
            accumulators[key]?.totalTokens += project.tokens.total
            accumulators[key]?.sessionCount += project.sessionCount
            accumulators[key]?.costBySource[project.sourceID, default: 0] += project.costUSD
        }

        let rows = order.compactMap { key -> MergedProjectRow? in
            guard let accumulator = accumulators[key] else { return nil }
            let sortedSources = accumulator.costBySource
                .sorted { $0.value > $1.value }
                .map(\.key)
            return MergedProjectRow(
                id: key,
                title: accumulator.title,
                subtitle: accumulator.subtitle,
                isUngrouped: accumulator.isUngrouped,
                costUSD: accumulator.costUSD,
                totalTokens: accumulator.totalTokens,
                sessionCount: accumulator.sessionCount,
                sourceIDs: sortedSources
            )
        }

        return rows.sorted { $0.costUSD > $1.costUSD }
    }
}

// MARK: - Agent tile (per-source spend card)

struct AgentSpendTile: View {
    let descriptor: AgentSourceDescriptor
    let costUSD: Decimal
    let share: Double // 0...1
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentSourceIcon(descriptor: descriptor, size: 20)
                Text(descriptor.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(costUSD.usdCompactString)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            ShareCapsule(progress: share, tint: tint)

            Text(sharePercentText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 168, maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    private var sharePercentText: String {
        let percent = Int((share * 100).rounded())
        if percent == 0, share > 0 {
            return UIStrings.text(zh: "占比 <1%", en: "<1% of total")
        }
        return UIStrings.text(zh: "占比 \(percent)%", en: "\(percent)% of total")
    }
}

struct ShareCapsule: View {
    let progress: Double // 0...1
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Delta badge

struct DeltaBadge: View {
    let current: Decimal
    let previous: Decimal

    var body: some View {
        HStack(spacing: 4) {
            if let percent {
                Image(systemName: isIncrease ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.bold))
                Text(labelText(percent: percent))
                    .font(.caption.weight(.medium))
            } else {
                Image(systemName: "minus")
                    .font(.caption2.weight(.bold))
                Text(UIStrings.text(zh: "无对比数据", en: "No comparison"))
                    .font(.caption.weight(.medium))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }

    private var percent: Int? {
        guard previous > 0 else { return nil }
        let ratio = (current - previous) / previous
        return Int((NSDecimalNumber(decimal: ratio).doubleValue * 100).rounded())
    }

    private var isIncrease: Bool { (percent ?? 0) >= 0 }

    private var color: Color {
        guard let percent else { return .secondary }
        if percent == 0 { return .secondary }
        return percent > 0 ? .red : .green
    }

    private func labelText(percent: Int) -> String {
        let magnitude = abs(percent)
        return UIStrings.text(
            zh: "\(magnitude)% 较上一周期",
            en: "\(magnitude)% vs previous period"
        )
    }
}

// MARK: - Stat tile (hero row, right side)

struct HeroStatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DashboardTheme.cardLabelFont)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Project row (Screen Time style, with share bar behind it)

struct ProjectRow: View {
    let project: MergedProjectRow
    let descriptorsByID: [AgentSourceID: AgentSourceDescriptor]
    let colors: [AgentSourceID: Color]
    let maxCostUSD: Decimal

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let subtitle = project.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            contributingIcons

            VStack(alignment: .trailing, spacing: 1) {
                Text(project.costUSD.usdCompactString)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(project.totalTokens.compactString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 8)
                    .fill(tintColor.opacity(0.07))
                    .frame(width: barWidth(totalWidth: proxy.size.width))
            }
        }
    }

    private var tintColor: Color {
        project.isUngrouped ? DashboardTheme.ungroupedColor : (project.dominantSourceID.flatMap { colors[$0] } ?? .secondary)
    }

    private func barWidth(totalWidth: CGFloat) -> CGFloat {
        guard maxCostUSD > 0, project.costUSD > 0 else { return 0 }
        let ratio = (project.costUSD / maxCostUSD)
        let width = totalWidth * CGFloat(NSDecimalNumber(decimal: ratio).doubleValue)
        return max(4, min(width, totalWidth))
    }

    @ViewBuilder
    private var avatar: some View {
        if project.isUngrouped {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DashboardTheme.ungroupedColor)
                .frame(width: 28, height: 28)
                .background(DashboardTheme.ungroupedColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
        } else if let dominant = project.dominantSourceID, let descriptor = descriptorsByID[dominant] {
            AgentSourceIcon(descriptor: descriptor, size: 28, imageSize: 16)
                .background((colors[dominant] ?? .secondary).opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "folder")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var contributingIcons: some View {
        if project.sourceIDs.count > 1 {
            HStack(spacing: 3) {
                ForEach(Array(project.sourceIDs.prefix(3)), id: \.self) { sourceID in
                    if let descriptor = descriptorsByID[sourceID] {
                        AgentSourceIcon(descriptor: descriptor, size: 18, imageSize: 12)
                            .background(
                                (colors[sourceID] ?? .secondary).opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                }
                if project.sourceIDs.count > 3 {
                    Text("+\(project.sourceIDs.count - 3)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }
}

// MARK: - Model row (Screen Time style, with share bar behind it)

/// One row per (modelFamily, source) pair, exactly as delivered by
/// `UsageInsightsSnapshot.models` -- unlike projects, model rows are
/// intentionally NOT merged across sources, since the same model family
/// billed through two different agents can have different pricing/estimation
/// characteristics worth distinguishing at a glance.
struct ModelRow: View {
    let model: ModelUsageSummary
    let descriptor: AgentSourceDescriptor?
    let tint: Color
    let maxCostUSD: Decimal

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(model.modelFamily)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(UIStrings.costLabel(model.costUSD.usdCompactString, estimated: model.hasEstimatedCost))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(model.tokens.total.compactString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.07))
                    .frame(width: barWidth(totalWidth: proxy.size.width))
            }
        }
    }

    private var subtitle: String {
        let sourceName = descriptor?.displayName ?? model.sourceID.rawValue
        let countText = UIStrings.text(
            zh: "\(model.eventCount.compactString) 次请求",
            en: "\(model.eventCount.compactString) requests"
        )
        return "\(sourceName) · \(countText)"
    }

    private func barWidth(totalWidth: CGFloat) -> CGFloat {
        guard maxCostUSD > 0, model.costUSD > 0 else { return 0 }
        let ratio = (model.costUSD / maxCostUSD)
        let width = totalWidth * CGFloat(NSDecimalNumber(decimal: ratio).doubleValue)
        return max(4, min(width, totalWidth))
    }

    @ViewBuilder
    private var avatar: some View {
        if let descriptor {
            AgentSourceIcon(descriptor: descriptor, size: 28, imageSize: 16)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "cpu")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Show all / show less expander

struct ShowAllToggle: View {
    let isExpanded: Bool
    let totalCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(isExpanded
                    ? UIStrings.text(zh: "收起", en: "Show less")
                    : UIStrings.text(zh: "显示全部 (\(totalCount))", en: "Show all (\(totalCount))"))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}
