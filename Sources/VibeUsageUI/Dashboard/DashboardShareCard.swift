import Charts
import SwiftUI
import VibeUsageAggregation
import VibeUsageCore

/// A fixed-size (720×900) "share poster" for a `UsageInsightsSnapshot`,
/// exported as a PNG (see `DashboardImageExporter`). Modeled after
/// Spotify/GitHub Wrapped-style recap cards rather than the dashboard itself:
/// one dominant hook number, a handful of emotionally punchy derived stats,
/// a decorative (non-analytical) trend sparkline, and strong branding. The
/// design is a single fixed dark-poster aesthetic — independent of system
/// light/dark appearance — so every hardcoded color below is intentional;
/// do not swap in adaptive styles (`.primary`, `.secondary`, dynamic
/// `Color(nsColor:)`) anywhere in this file.
public struct DashboardShareCard: View {
    public static let width: CGFloat = 720
    public static let height: CGFloat = 900

    let snapshot: UsageInsightsSnapshot
    let rangeTitle: String

    private let humanizer = ProjectNameHumanizer()

    public init(snapshot: UsageInsightsSnapshot, rangeTitle: String) {
        self.snapshot = snapshot
        self.rangeTitle = rangeTitle
    }

    // MARK: - Palette (fixed, poster-only)

    private enum Poster {
        static let white100 = Color.white
        static let white90 = Color.white.opacity(0.9)
        static let white55 = Color.white.opacity(0.55)
        static let white45 = Color.white.opacity(0.45)
        static let white12 = Color.white.opacity(0.12)
        static let white8 = Color.white.opacity(0.08)
        static let white6 = Color.white.opacity(0.06)

        static let bgTop = Color(hex: "0B0E1A")
        static let bgBottom = Color(hex: "171B33")

        static let overline = Font.system(size: 13, weight: .semibold, design: .rounded)
        static let heroFont = Font.system(size: 88, weight: .heavy, design: .rounded).monospacedDigit()
        static let caption = Font.system(size: 14, weight: .medium, design: .rounded)
        static let statLabel = Font.system(size: 12, weight: .semibold, design: .rounded)
        static let statValue = Font.system(size: 24, weight: .heavy, design: .rounded).monospacedDigit()
    }

    // MARK: - Derived data

    private var sourceColors: [AgentSourceID: Color] {
        DashboardTheme.colors(for: snapshot.sources.map(\.id))
    }

    private var sortedSources: [SourceUsageSummary] {
        snapshot.sources.sorted { $0.totals.costUSD > $1.totals.costUSD }
    }

    private var topSource: SourceUsageSummary? { sortedSources.first }

    private var topSourceTint: Color {
        guard let topSource else { return Color(hex: "007AFF") }
        return sourceColors[topSource.id] ?? DashboardTheme.color(for: topSource.id)
    }

    private var topSourceShare: Double {
        guard let topSource, snapshot.totals.costUSD > 0 else { return 0 }
        let ratio = NSDecimalNumber(decimal: topSource.totals.costUSD / snapshot.totals.costUSD).doubleValue
        return min(max(ratio, 0), 1)
    }

    private var topModel: ModelUsageSummary? {
        snapshot.models.max { $0.costUSD < $1.costUSD }
    }

    private var mergedProjects: [MergedProjectRow] {
        MergedProjectRow.merge(projects: snapshot.projects, humanizer: humanizer)
    }

    private var topProject: MergedProjectRow? {
        mergedProjects.max { $0.costUSD < $1.costUSD }
    }

    /// Daily spend aggregated across all sources, one point per calendar day
    /// (the trend strip is decorative, so per-source breakdown is dropped).
    private var dailyTotals: [(day: String, costUSD: Decimal)] {
        var totals: [String: Decimal] = [:]
        var order: [String] = []
        for row in snapshot.daily {
            if totals[row.day] == nil { order.append(row.day) }
            totals[row.day, default: 0] += row.costUSD
        }
        return order.sorted().map { ($0, totals[$0] ?? 0) }
    }

    private var busiestDay: (day: String, costUSD: Decimal)? {
        dailyTotals.max { $0.costUSD < $1.costUSD }
    }

    private var dailyAverage: Decimal {
        guard snapshot.activeDayCount > 0 else { return 0 }
        return snapshot.totals.costUSD / Decimal(snapshot.activeDayCount)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandRow
                .padding(.bottom, 34)
            heroSection
                .padding(.bottom, 30)
            trendStrip
                .padding(.bottom, 34)
            statGrid
                .padding(.bottom, 18)
            superlativeRow
                .padding(.bottom, 14)
            topProjectRow
            Spacer(minLength: 24)
            footer
        }
        .padding(28)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(posterBackground)
        // Forces the dark-variant agent icon assets (see `AgentSourceIcon`'s
        // `AgentIconStore.image(for:colorScheme:)`) regardless of the
        // ambient/system appearance, since this poster's background is
        // always the same near-black gradient.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Background

    private var posterBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Poster.bgTop, Poster.bgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [topSourceTint.opacity(0.08), .clear],
                center: UnitPoint(x: 0.08, y: 0.05),
                startRadius: 0,
                endRadius: 520
            )
        }
    }

    // MARK: - Brand row

    private var brandRow: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                VibeUsageLogo(size: 24)
                Text("VibeUsage")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Poster.white100)
            }

            Spacer(minLength: 12)

            Text("\(rangeTitle) · \(dateSpanText)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Poster.white90)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Poster.white8, in: Capsule())
        }
    }

    private var dateSpanText: String {
        let start = DashboardDateParsing.displayString(fromDay: snapshot.rangeStartDay)
        let end = DashboardDateParsing.displayString(fromDay: snapshot.rangeEndDay)
        return "\(start) – \(end)"
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UIStrings.text(zh: "总花费", en: "TOTAL SPEND"))
                .font(Poster.overline)
                .tracking(2.2)
                .foregroundStyle(Poster.white55)

            HStack(alignment: .lastTextBaseline, spacing: 14) {
                Text(snapshot.totals.costUSD.usdCompactString)
                    .font(Poster.heroFont)
                    .foregroundStyle(Poster.white100)
                PosterDeltaBadge(current: snapshot.totals.costUSD, previous: snapshot.previousTotals.costUSD)
                    .padding(.bottom, 14)
            }

            Text(heroCaptionText)
                .font(Poster.caption)
                .foregroundStyle(Poster.white55)
        }
    }

    private var heroCaptionText: String {
        let avg = dailyAverage.usdCompactString
        guard let busiestDay else {
            return UIStrings.text(zh: "日均 \(avg)", en: "\(avg) per day on average")
        }
        let dayText = DashboardDateParsing.displayString(fromDay: busiestDay.day)
        let peak = busiestDay.costUSD.usdCompactString
        return UIStrings.text(
            zh: "日均 \(avg) · 最高单日 \(peak) (\(dayText))",
            en: "\(avg)/day avg · peak \(peak) on \(dayText)"
        )
    }

    // MARK: - Trend strip (decorative only)

    @ViewBuilder
    private var trendStrip: some View {
        if dailyTotals.count > 1 {
            Chart(Array(dailyTotals.enumerated()), id: \.offset) { _, point in
                AreaMark(
                    x: .value("day", point.day),
                    y: .value("cost", NSDecimalNumber(decimal: point.costUSD).doubleValue)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [topSourceTint.opacity(0.6), topSourceTint.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("day", point.day),
                    y: .value("cost", NSDecimalNumber(decimal: point.costUSD).doubleValue)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(topSourceTint)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 120)
        }
    }

    // MARK: - Stat grid (2x2)

    private var statGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            PosterStatCard(
                label: UIStrings.tokens,
                value: snapshot.totals.tokens.total.compactString,
                detail: cacheReadDetailText
            )
            PosterStatCard(
                label: UIStrings.text(zh: "请求数", en: "Requests"),
                value: snapshot.totals.eventCount.compactString
            )
            PosterStatCard(
                label: UIStrings.text(zh: "活跃天数", en: "Active days"),
                value: activeDaysValueText
            )
            PosterStatCard(
                label: UIStrings.text(zh: "项目数", en: "Projects"),
                value: "\(mergedProjects.count)"
            )
        }
    }

    private var activeDaysValueText: String {
        UIStrings.text(zh: "\(snapshot.activeDayCount) 天", en: "\(snapshot.activeDayCount)")
    }

    private var cacheReadDetailText: String? {
        guard let ratio = snapshot.totals.tokens.cacheReadRatio else { return nil }
        return "\(UIStrings.cacheRead) \(UIStrings.percentage(ratio))"
    }

    // MARK: - Superlative row ("王者" cards)

    @ViewBuilder
    private var superlativeRow: some View {
        HStack(spacing: 12) {
            if let topSource {
                PosterSuperlativeCard(
                    label: UIStrings.text(zh: "最常用", en: "Top agent"),
                    accent: topSourceTint
                ) {
                    HStack(spacing: 8) {
                        AgentSourceIcon(descriptor: topSource.descriptor, size: 22, imageSize: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(topSource.descriptor.displayName)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Poster.white100)
                                .lineLimit(1)
                            Text(topSourceDetailText)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Poster.white55)
                        }
                    }
                }
            }

            if let topModel {
                PosterSuperlativeCard(
                    label: UIStrings.text(zh: "最烧模型", en: "Top model"),
                    accent: sourceColors[topModel.sourceID] ?? DashboardTheme.color(for: topModel.sourceID)
                ) {
                    HStack(spacing: 8) {
                        if let descriptor = descriptorsByID[topModel.sourceID] {
                            AgentSourceIcon(descriptor: descriptor, size: 22, imageSize: 14)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(topModel.modelFamily)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Poster.white100)
                                .lineLimit(1)
                            Text(topModel.costUSD.usdCompactString)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Poster.white55)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var descriptorsByID: [AgentSourceID: AgentSourceDescriptor] {
        Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0.descriptor) })
    }

    private var topSourceShareText: String {
        let percent = Int((topSourceShare * 100).rounded())
        return UIStrings.text(zh: "占比 \(percent)%", en: "\(percent)% of spend")
    }

    private var topSourceDetailText: String {
        guard let ratio = topSource?.totals.tokens.cacheReadRatio else {
            return topSourceShareText
        }
        return "\(topSourceShareText) · \(UIStrings.cacheRead) \(UIStrings.percentage(ratio))"
    }

    // MARK: - Top project (slim full-width row)

    @ViewBuilder
    private var topProjectRow: some View {
        if let topProject {
            HStack(spacing: 10) {
                Image(systemName: topProject.isUngrouped ? "folder.badge.questionmark" : "folder.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Poster.white55)
                Text(UIStrings.text(zh: "最烧项目", en: "Top project"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Poster.white55)
                Text(topProject.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Poster.white90)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                Text(topProject.costUSD.usdCompactString)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Poster.white100)
                    .layoutPriority(1)
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Poster.white6, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(Poster.white12)
                .frame(height: 1)

            HStack(alignment: .center) {
                Text(UIStrings.text(zh: "VibeUsage — 本机 AI 编程用量统计", en: "VibeUsage — Local AI coding usage tracker"))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Poster.white45)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(generatedAtText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Poster.white45)
                    .lineLimit(1)
            }
        }
    }

    private var generatedAtText: String {
        let date = snapshot.generatedAt.formatted(date: .numeric, time: .omitted)
        return UIStrings.text(zh: "生成于 \(date)", en: "Generated \(date)")
    }
}

// MARK: - Poster-local components

/// A brighter, dark-background-tuned restatement of `DeltaBadge` for the
/// poster context (the shared `DeltaBadge` in MenuComponents.swift assumes a
/// light/adaptive surface; this pill uses stronger opacities to stay legible
/// on the near-black gradient).
private struct PosterDeltaBadge: View {
    let current: Decimal
    let previous: Decimal

    var body: some View {
        HStack(spacing: 4) {
            if let percent {
                Image(systemName: isIncrease ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                Text(labelText(percent: percent))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            } else {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                Text(UIStrings.text(zh: "无对比数据", en: "No comparison"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.22), in: Capsule())
    }

    private var percent: Int? {
        guard previous > 0 else { return nil }
        let ratio = (current - previous) / previous
        return Int((NSDecimalNumber(decimal: ratio).doubleValue * 100).rounded())
    }

    private var isIncrease: Bool { (percent ?? 0) >= 0 }

    private var color: Color {
        guard let percent else { return .white.opacity(0.55) }
        if percent == 0 { return .white.opacity(0.55) }
        return percent > 0 ? Color(hex: "FF6B6B") : Color(hex: "4ADE80")
    }

    private func labelText(percent: Int) -> String {
        let magnitude = abs(percent)
        return UIStrings.text(zh: "\(magnitude)% 较上期", en: "\(magnitude)% vs prior")
    }
}

private struct PosterStatCard: View {
    let label: String
    let value: String
    let detail: String?

    init(label: String, value: String, detail: String? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct PosterSuperlativeCard<Content: View>: View {
    let label: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                content
            }
            .padding(.leading, 14)
            .padding(.vertical, 16)
            .padding(.trailing, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}
