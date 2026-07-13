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

struct DeviceMetricRow: View {
    let device: DeviceUsageSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.isLocal ? "desktopcomputer" : "laptopcomputer")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.callout)
                    .lineLimit(1)
                if device.isLocal {
                    Text(UIStrings.text(zh: "此 Mac", en: "This Mac"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(UIStrings.costLabel(device.totals.costUSD.usdString, estimated: device.hasEstimatedCost))
                    .font(.callout.monospacedDigit())
                Text(device.totals.tokens.total.compactString)
                    .font(.caption2.monospacedDigit())
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
            Text(UIStrings.costLabel(model.costUSD.usdString, estimated: model.hasEstimatedCost))
                .font(.callout.monospacedDigit())
        }
        .padding(.vertical, 6)
    }
}
