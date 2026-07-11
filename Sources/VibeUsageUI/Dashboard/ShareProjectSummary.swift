import Foundation
import VibeUsageAggregation
import VibeUsageCore

/// Project totals merged across agents for the share poster.
struct MergedProjectRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let isUngrouped: Bool
    let costUSD: Decimal
    let totalTokens: Int
    let sessionCount: Int
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
                } else {
                    accumulator.title = UIStrings.text(zh: "未分组", en: "Ungrouped")
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
            return MergedProjectRow(
                id: key,
                title: accumulator.title,
                subtitle: accumulator.subtitle,
                isUngrouped: accumulator.isUngrouped,
                costUSD: accumulator.costUSD,
                totalTokens: accumulator.totalTokens,
                sessionCount: accumulator.sessionCount,
                sourceIDs: accumulator.costBySource.sorted { $0.value > $1.value }.map(\.key)
            )
        }

        return rows.sorted { $0.costUSD > $1.costUSD }
    }
}

enum DashboardDateParsing {
    static func displayString(fromDay day: String) -> String {
        guard let date = dayFormatter.date(from: day) else { return day }
        return displayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
}
