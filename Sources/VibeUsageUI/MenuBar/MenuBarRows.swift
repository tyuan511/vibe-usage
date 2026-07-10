import SwiftUI
import VibeUsageAggregation
import VibeUsageCore

struct AgentSettingLabel: View {
    let descriptor: AgentSourceDescriptor

    var body: some View {
        HStack(spacing: 8) {
            AgentSourceIcon(descriptor: descriptor, size: 18)
            Text(descriptor.displayName)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
    }
}

struct SourceMetricRow: View {
    let source: SourceUsageSummary

    var body: some View {
        HStack(spacing: 8) {
            AgentSourceIcon(descriptor: source.descriptor, size: 18)
            Text(source.descriptor.displayName)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(UIStrings.costLabel(source.totals.costUSD.usdString, estimated: source.hasEstimatedCost))
                    .font(.callout.monospacedDigit())
                Text(tokenDetailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, 6)
    }

    private var tokenDetailText: String {
        let total = source.totals.tokens.total.compactString
        guard let ratio = source.totals.tokens.cacheReadRatio else { return total }
        return "\(total) · \(UIStrings.cacheRead) \(UIStrings.percentage(ratio))"
    }
}

struct ModelMetricRow: View {
    let model: ModelUsageSummary

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.modelFamily)
                    .font(.callout)
                    .lineLimit(1)
                Text(UIStrings.modelTokenLine(
                    sourceID: model.sourceID.rawValue,
                    tokens: model.tokens.total.compactString
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text(UIStrings.costLabel(model.costUSD.usdString, estimated: model.hasEstimatedCost))
                .font(.callout.monospacedDigit())
        }
        .padding(.vertical, 6)
    }
}
