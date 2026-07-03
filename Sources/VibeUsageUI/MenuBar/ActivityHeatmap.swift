import SwiftUI
import VibeUsageAggregation
import VibeUsageCore

struct ActivityHeatmap: View {
    let daily: [DailyUsageSummary]
    let generatedAt: Date
    @State private var hoveredDay: ActivityDay?

    private let weekCount = 24
    private let daysPerWeek = 7
    private let rowSpacing: CGFloat = 4
    private let cellSize: CGFloat = 10

    private var activityByDay: [String: UsageTotals] {
        Self.activityByDay(from: daily)
    }

    private var columns: [[ActivityDay]] {
        let days = Self.lastDays(endingAt: generatedAt, count: weekCount * daysPerWeek)
        let values = activityByDay
        return stride(from: 0, to: days.count, by: 7).map { start in
            days[start..<min(start + 7, days.count)].map { day in
                ActivityDay(day: day, totals: values[day] ?? UsageTotals())
            }
        }
    }

    private var maxTokens: Int {
        max(1, activityByDay.values.map(\.tokens.total).max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                MenuSectionTitle(UIStrings.text(zh: "活跃", en: "Activity"))
                Spacer()
                Text(hoveredDay.map(helpText) ?? " ")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            GeometryReader { proxy in
                let columnSpacing = columnSpacing(for: proxy.size.width)

                HStack(alignment: .top, spacing: columnSpacing) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: rowSpacing) {
                            ForEach(column) { day in
                                RoundedRectangle(cornerRadius: 3.5)
                                    .fill(color(for: day))
                                    .frame(width: cellSize, height: cellSize)
                                    .contentShape(Rectangle())
                                    .onHover { hovering in
                                        if hovering {
                                            hoveredDay = day
                                        } else if hoveredDay?.id == day.id {
                                            hoveredDay = nil
                                        }
                                    }
                            }
                        }
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: heatmapHeight, maxHeight: heatmapHeight)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var heatmapHeight: CGFloat {
        cellSize * CGFloat(daysPerWeek) + rowSpacing * CGFloat(daysPerWeek - 1) + 20
    }

    private func columnSpacing(for width: CGFloat) -> CGFloat {
        guard weekCount > 1 else { return 0 }
        let remaining = width - cellSize * CGFloat(weekCount)
        return max(3, remaining / CGFloat(weekCount - 1))
    }

    private func color(for day: ActivityDay) -> Color {
        guard day.totals.tokens.total > 0 else {
            return Color.secondary.opacity(0.12)
        }
        let fraction = Double(day.totals.tokens.total) / Double(maxTokens)
        switch fraction {
        case ..<0.25:
            return Color(red: 0.38, green: 0.72, blue: 0.48).opacity(0.45)
        case ..<0.5:
            return Color(red: 0.29, green: 0.65, blue: 0.41).opacity(0.65)
        case ..<0.75:
            return Color(red: 0.20, green: 0.56, blue: 0.34).opacity(0.82)
        default:
            return Color(red: 0.10, green: 0.43, blue: 0.25)
        }
    }

    private func helpText(for day: ActivityDay) -> String {
        UIStrings.activityDetail(
            day: day.day,
            tokens: day.totals.tokens.total.compactString,
            cost: day.totals.costUSD.usdString
        )
    }

    private static func activityByDay(from daily: [DailyUsageSummary]) -> [String: UsageTotals] {
        var accumulators: [String: ActivityAccumulator] = [:]
        for row in daily {
            accumulators[row.day, default: ActivityAccumulator()].add(tokens: row.tokens, cost: row.costUSD)
        }
        return accumulators.mapValues(\.totals)
    }

    private static func lastDays(endingAt date: Date, count: Int) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        return (0..<count).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map(dayFormatter.string)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct ActivityDay: Identifiable {
    let day: String
    let totals: UsageTotals

    var id: String { day }
}

struct ActivityAccumulator {
    var tokens: TokenCounts = .zero
    var costUSD: Decimal = 0

    var totals: UsageTotals {
        UsageTotals(tokens: tokens, costUSD: costUSD)
    }

    mutating func add(tokens: TokenCounts, cost: Decimal) {
        self.tokens = self.tokens + tokens
        costUSD += cost
    }
}
