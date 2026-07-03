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
                Text(source.totals.costUSD.usdString)
                    .font(.callout.monospacedDigit())
                Text(source.totals.tokens.total.compactString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
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
            Text(model.costUSD.usdString)
                .font(.callout.monospacedDigit())
        }
        .padding(.vertical, 6)
    }
}
