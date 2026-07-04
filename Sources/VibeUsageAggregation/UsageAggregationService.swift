import Foundation
import VibeUsageCore
import VibeUsageStorage

public struct UsageTotals: Sendable, Equatable {
    public let tokens: TokenCounts
    public let costUSD: Decimal
    public let eventCount: Int

    public init(tokens: TokenCounts = .zero, costUSD: Decimal = 0, eventCount: Int = 0) {
        self.tokens = tokens
        self.costUSD = costUSD
        self.eventCount = eventCount
    }
}

public struct SourceUsageSummary: Identifiable, Sendable, Equatable {
    public var id: AgentSourceID { descriptor.id }
    public let descriptor: AgentSourceDescriptor
    public let totals: UsageTotals
    public let hasEstimatedCost: Bool

    public init(descriptor: AgentSourceDescriptor, totals: UsageTotals, hasEstimatedCost: Bool = false) {
        self.descriptor = descriptor
        self.totals = totals
        self.hasEstimatedCost = hasEstimatedCost
    }
}

public struct DailyUsageSummary: Identifiable, Sendable, Equatable {
    public var id: String { "\(day)-\(sourceID.rawValue)" }
    public let day: String
    public let sourceID: AgentSourceID
    public let tokens: TokenCounts
    public let costUSD: Decimal

    public init(day: String, sourceID: AgentSourceID, tokens: TokenCounts, costUSD: Decimal) {
        self.day = day
        self.sourceID = sourceID
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

public struct ModelUsageSummary: Identifiable, Sendable, Equatable {
    public var id: String { "\(sourceID.rawValue)-\(modelFamily)" }
    public let modelFamily: String
    public let sourceID: AgentSourceID
    public let tokens: TokenCounts
    public let costUSD: Decimal
    public let eventCount: Int
    public let hasEstimatedCost: Bool

    public init(
        modelFamily: String,
        sourceID: AgentSourceID,
        tokens: TokenCounts,
        costUSD: Decimal,
        eventCount: Int,
        hasEstimatedCost: Bool = false
    ) {
        self.modelFamily = modelFamily
        self.sourceID = sourceID
        self.tokens = tokens
        self.costUSD = costUSD
        self.eventCount = eventCount
        self.hasEstimatedCost = hasEstimatedCost
    }
}

public enum UsageDateRangePreset: String, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case thisWeek
    case thisMonth

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .today: VibeUsageStrings.text(zh: "今天", en: "Today")
        case .yesterday: VibeUsageStrings.text(zh: "昨天", en: "Yesterday")
        case .thisWeek: VibeUsageStrings.text(zh: "本周", en: "This Week")
        case .thisMonth: VibeUsageStrings.text(zh: "本月", en: "This Month")
        }
    }
}

public struct UsageDashboardSnapshot: Sendable, Equatable {
    public let generatedAt: Date
    public let rangeStartDay: String
    public let rangeEndDay: String
    public let totals: UsageTotals
    public let sources: [SourceUsageSummary]
    public let daily: [DailyUsageSummary]
    public let activity: [DailyUsageSummary]
    public let models: [ModelUsageSummary]
    public let availableModels: [ModelUsageSummary]
    public let discoveredSources: [AgentSourceDescriptor]

    public init(
        generatedAt: Date,
        rangeStartDay: String,
        rangeEndDay: String,
        totals: UsageTotals,
        sources: [SourceUsageSummary],
        daily: [DailyUsageSummary],
        activity: [DailyUsageSummary],
        models: [ModelUsageSummary],
        availableModels: [ModelUsageSummary],
        discoveredSources: [AgentSourceDescriptor]
    ) {
        self.generatedAt = generatedAt
        self.rangeStartDay = rangeStartDay
        self.rangeEndDay = rangeEndDay
        self.totals = totals
        self.sources = sources
        self.daily = daily
        self.activity = activity
        self.models = models
        self.availableModels = availableModels
        self.discoveredSources = discoveredSources
    }

    public static func empty(descriptors: [AgentSourceDescriptor] = []) -> UsageDashboardSnapshot {
        let today = Date.vibeUsageDayString(Date())
        return UsageDashboardSnapshot(
            generatedAt: Date(),
            rangeStartDay: today,
            rangeEndDay: today,
            totals: UsageTotals(),
            sources: descriptors.map { SourceUsageSummary(descriptor: $0, totals: UsageTotals()) },
            daily: [],
            activity: [],
            models: [],
            availableModels: [],
            discoveredSources: descriptors
        )
    }
}

public final class UsageAggregationService: Sendable {
    private let store: GRDBUsageEventStore
    private let registry: AdapterRegistry

    public init(store: GRDBUsageEventStore, registry: AdapterRegistry = .shared) {
        self.store = store
        self.registry = registry
    }

    public func dashboardSnapshot(
        sourceFilter: Set<AgentSourceID> = [],
        visibleSourceFilter: Set<AgentSourceID>? = nil,
        modelFilter: Set<String> = [],
        dateRange: UsageDateRangePreset? = nil,
        daysBack: Int = 30,
        now: Date = Date()
    ) throws -> UsageDashboardSnapshot {
        let bounds = Self.dayBounds(dateRange: dateRange, daysBack: daysBack, now: now)
        let start = Date.vibeUsageDayString(bounds.start)
        let end = Date.vibeUsageDayString(bounds.end)
        let effectiveSourceFilter: Set<AgentSourceID>
        if let visibleSourceFilter {
            effectiveSourceFilter = sourceFilter.isEmpty
                ? visibleSourceFilter
                : visibleSourceFilter.intersection(sourceFilter)
            if effectiveSourceFilter.isEmpty {
                return UsageDashboardSnapshot(
                    generatedAt: now,
                    rangeStartDay: start,
                    rangeEndDay: end,
                    totals: UsageTotals(),
                    sources: [],
                    daily: [],
                    activity: [],
                    models: [],
                    availableModels: [],
                    discoveredSources: []
                )
            }
        } else {
            effectiveSourceFilter = sourceFilter
        }

        let dailyRows = try store.dailySummaries(
            sourceFilter: effectiveSourceFilter,
            startDay: start,
            endDay: end,
            modelFamilyFilter: modelFilter
        )
        let modelRows = try store.modelBreakdown(
            sourceFilter: effectiveSourceFilter,
            startDay: start,
            endDay: end,
            modelFamilyFilter: modelFilter
        )
        let availableModelRows = try store.modelBreakdown(
            sourceFilter: effectiveSourceFilter,
            startDay: start,
            endDay: end
        )
        let activityStart = Date.vibeUsageDayString(Self.activityStartDate(now: now))
        let activityEnd = Date.vibeUsageDayString(now)
        let activityRows = try store.dailySummaries(
            sourceFilter: effectiveSourceFilter,
            startDay: activityStart,
            endDay: activityEnd,
            modelFamilyFilter: modelFilter
        )
        let descriptors = registry.descriptors
        let descriptorsByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

        var totalsBySource: [AgentSourceID: UsageTotalsAccumulator] = [:]
        var estimatedBySource: [AgentSourceID: Bool] = [:]
        var grand = UsageTotalsAccumulator()
        for row in dailyRows {
            totalsBySource[row.sourceID, default: UsageTotalsAccumulator()].add(tokens: row.tokens, cost: row.costUSD, events: 0)
            grand.add(tokens: row.tokens, cost: row.costUSD, events: 0)
        }
        for row in modelRows {
            totalsBySource[row.sourceID, default: UsageTotalsAccumulator()].eventCount += row.eventCount
            grand.eventCount += row.eventCount
            if row.estimatedEventCount > 0 {
                estimatedBySource[row.sourceID] = true
            }
        }

        let sourceSummaries = descriptors
            .filter { effectiveSourceFilter.isEmpty || effectiveSourceFilter.contains($0.id) }
            .compactMap { descriptor -> SourceUsageSummary? in
                let totals = totalsBySource[descriptor.id]?.totals ?? UsageTotals()
                guard totals.eventCount > 0 || totals.tokens.total > 0 else { return nil }
                return SourceUsageSummary(
                    descriptor: descriptor,
                    totals: totals,
                    hasEstimatedCost: estimatedBySource[descriptor.id] ?? false
                )
            }

        return UsageDashboardSnapshot(
            generatedAt: now,
            rangeStartDay: start,
            rangeEndDay: end,
            totals: grand.totals,
            sources: sourceSummaries,
            daily: dailyRows.map {
                DailyUsageSummary(day: $0.day, sourceID: $0.sourceID, tokens: $0.tokens, costUSD: $0.costUSD)
            },
            activity: activityRows.map {
                DailyUsageSummary(day: $0.day, sourceID: $0.sourceID, tokens: $0.tokens, costUSD: $0.costUSD)
            },
            models: modelRows.map {
                ModelUsageSummary(
                    modelFamily: $0.modelFamily,
                    sourceID: descriptorsByID[$0.sourceID]?.id ?? $0.sourceID,
                    tokens: $0.tokens,
                    costUSD: $0.costUSD,
                    eventCount: $0.eventCount,
                    hasEstimatedCost: $0.estimatedEventCount > 0
                )
            },
            availableModels: availableModelRows.map {
                ModelUsageSummary(
                    modelFamily: $0.modelFamily,
                    sourceID: descriptorsByID[$0.sourceID]?.id ?? $0.sourceID,
                    tokens: $0.tokens,
                    costUSD: $0.costUSD,
                    eventCount: $0.eventCount,
                    hasEstimatedCost: $0.estimatedEventCount > 0
                )
            },
            discoveredSources: descriptors.filter { effectiveSourceFilter.isEmpty || effectiveSourceFilter.contains($0.id) }
        )
    }

    private static func activityStartDate(now: Date, calendar baseCalendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        var calendar = baseCalendar
        calendar.timeZone = .current
        let todayStart = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -167, to: todayStart) ?? todayStart
    }

    public static func dayBounds(
        dateRange: UsageDateRangePreset?,
        daysBack: Int,
        now: Date,
        calendar baseCalendar: Calendar = Calendar(identifier: .gregorian)
    ) -> (start: Date, end: Date) {
        var calendar = baseCalendar
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        let todayStart = calendar.startOfDay(for: now)

        switch dateRange {
        case .today:
            return (todayStart, todayStart)
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
            return (yesterday, yesterday)
        case .thisWeek:
            let weekday = calendar.component(.weekday, from: todayStart)
            let offset = (weekday - calendar.firstWeekday + 7) % 7
            let start = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
            return (start, todayStart)
        case .thisMonth:
            let components = calendar.dateComponents([.year, .month], from: todayStart)
            let start = calendar.date(from: components) ?? todayStart
            return (start, todayStart)
        case .none:
            let start = calendar.date(byAdding: .day, value: -max(0, daysBack - 1), to: todayStart) ?? todayStart
            return (start, todayStart)
        }
    }
}

private struct UsageTotalsAccumulator {
    var tokens: TokenCounts = .zero
    var costUSD: Decimal = 0
    var eventCount: Int = 0

    var totals: UsageTotals {
        UsageTotals(tokens: tokens, costUSD: costUSD, eventCount: eventCount)
    }

    mutating func add(tokens: TokenCounts, cost: Decimal, events: Int) {
        self.tokens = self.tokens + tokens
        self.costUSD += cost
        self.eventCount += events
    }
}

private extension Date {
    static func vibeUsageDayString(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
