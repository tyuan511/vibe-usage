import AppKit
import Charts
import SwiftUI
import VibeUsageAggregation
import VibeUsageCore

/// The "console" window: a larger, resizable view of usage trends, project
/// rollups, and recent sessions. Opened separately from the menu bar popover
/// (see `VibeUsageApp`'s `Window` scene) so users can keep it around while
/// working, unlike the transient `MenuBarExtra` content.
public struct DashboardWindowView: View {
    let snapshot: UsageInsightsSnapshot
    let isLoading: Bool
    @Binding var selectedRange: UsageInsightsRange
    let onRangeChange: () -> Void
    let onRefresh: () -> Void

    @State private var chartMetric: DashboardChartMetric = .spend
    @State private var selectedDay: String?
    @State private var showsAllProjects = false
    @State private var showsAllModels = false
    @State private var shareAnchorView: NSView?

    private let humanizer = ProjectNameHumanizer()

    private static let projectsCollapsedLimit = 12
    private static let modelsCollapsedLimit = 8

    public init(
        snapshot: UsageInsightsSnapshot,
        isLoading: Bool,
        selectedRange: Binding<UsageInsightsRange>,
        onRangeChange: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.isLoading = isLoading
        self._selectedRange = selectedRange
        self.onRangeChange = onRangeChange
        self.onRefresh = onRefresh
    }

    private var descriptorsByID: [AgentSourceID: AgentSourceDescriptor] {
        Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0.descriptor) })
    }

    /// Collision-resolved color per source, computed once over every source
    /// visible anywhere in this snapshot so the same source always gets the
    /// same color across the agent tiles, chart, and project/session rows.
    private var sourceColors: [AgentSourceID: Color] {
        DashboardTheme.colors(for: snapshot.sources.map(\.id))
    }

    private var mergedProjects: [MergedProjectRow] {
        MergedProjectRow.merge(projects: snapshot.projects, humanizer: humanizer)
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: DashboardTheme.sectionSpacing) {
                header
                heroRow
                agentTilesSection
                trendSection
                projectsSection
                modelsSection
            }
            .padding(24)
            .frame(maxWidth: DashboardTheme.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 860, minHeight: 680)
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VibeUsageLogo(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(UIStrings.text(zh: "用量控制台", en: "Usage Console"))
                    .font(.title2.weight(.semibold))
                if isLoading {
                    Text(UIStrings.scanning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(UIStrings.updated(snapshot.generatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            rangePicker

            GlassEffectContainer {
                HStack(spacing: 8) {
                    shareMenu
                        .background(ShareAnchorCapture(anchorView: $shareAnchorView))

                    Button(action: onRefresh) {
                        Image(systemName: isLoading ? "hourglass" : "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .disabled(isLoading)
                    .help(UIStrings.refresh)
                }
            }
        }
    }

    private var shareMenu: some View {
        Menu {
            Button(UIStrings.text(zh: "保存图片…", en: "Save Image…")) {
                saveImage()
            }
            Button(UIStrings.text(zh: "拷贝图片", en: "Copy Image")) {
                copyImage()
            }
            Button(UIStrings.text(zh: "分享…", en: "Share…")) {
                shareImage()
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: 18, height: 18)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .controlSize(.small)
        .frame(width: 28, height: 28)
        .disabled(snapshot.totals.eventCount == 0)
        .help(UIStrings.text(zh: "导出图片", en: "Export image"))
    }

    // MARK: - Export

    private func exportPNGData() -> Data? {
        // The share card is a single fixed dark-poster design regardless of
        // system appearance; `darkMode` no longer affects the rendered
        // output (see `DashboardImageExporter`), so the value passed here is
        // arbitrary.
        DashboardImageExporter.renderPNGData(
            snapshot: snapshot,
            rangeTitle: selectedRange.displayName,
            darkMode: true
        )
    }

    private func saveImage() {
        guard let data = exportPNGData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "VibeUsage-\(snapshot.rangeEndDay).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private func copyImage() {
        guard let data = exportPNGData() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        if let image = NSImage(data: data), let tiffData = image.tiffRepresentation {
            pasteboard.setData(tiffData, forType: .tiff)
        }
    }

    private func shareImage() {
        guard let data = exportPNGData(), let image = NSImage(data: data) else { return }
        let picker = NSSharingServicePicker(items: [image])
        if let anchorView = shareAnchorView {
            picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        } else if let contentView = NSApp.keyWindow?.contentView {
            let topRight = NSRect(x: contentView.bounds.maxX - 1, y: contentView.bounds.maxY - 1, width: 1, height: 1)
            picker.show(relativeTo: topRight, of: contentView, preferredEdge: .minY)
        }
    }

    private var rangePicker: some View {
        Picker(UIStrings.text(zh: "时间范围", en: "Range"), selection: rangeSelection) {
            ForEach(UsageInsightsRange.allCases) { range in
                Text(range.displayName).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .frame(width: 384)
    }

    private var rangeSelection: Binding<UsageInsightsRange> {
        Binding(
            get: { selectedRange },
            set: { value in
                selectedRange = value
                onRangeChange()
            }
        )
    }

    // MARK: - Hero row

    private var heroRow: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(UIStrings.spend)
                    .font(DashboardTheme.sectionTitleFont)
                    .foregroundStyle(.secondary)
                Text(snapshot.totals.costUSD.usdCompactString)
                    .font(DashboardTheme.heroNumberFont)
                DeltaBadge(current: snapshot.totals.costUSD, previous: snapshot.previousTotals.costUSD)
            }
            .frame(width: 220, alignment: .leading)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                HeroStatTile(title: UIStrings.tokens, value: snapshot.totals.tokens.total.compactString)
                HeroStatTile(title: UIStrings.text(zh: "请求数", en: "Requests"), value: snapshot.totals.eventCount.compactString)
                HeroStatTile(title: UIStrings.text(zh: "活跃天数", en: "Active days"), value: activeDaysText)
                HeroStatTile(title: UIStrings.text(zh: "日均花费", en: "Daily avg"), value: dailyAverageText)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var activeDaysText: String {
        let total = max(1, rangeDayCount)
        return "\(snapshot.activeDayCount) / \(total) \(UIStrings.text(zh: "天", en: "d"))"
    }

    private var dailyAverageText: String {
        let days = Decimal(max(1, snapshot.activeDayCount))
        return (snapshot.totals.costUSD / days).usdCompactString
    }

    private var rangeDayCount: Int {
        switch selectedRange {
        case .today: 1
        case .last7Days: 7
        case .last30Days: 30
        case .last90Days: 90
        case .thisMonth: Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30
        }
    }

    // MARK: - Agent tiles

    private var sortedSources: [SourceUsageSummary] {
        snapshot.sources.sorted { $0.totals.costUSD > $1.totals.costUSD }
    }

    @ViewBuilder
    private var agentTilesSection: some View {
        if !sortedSources.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                MenuSectionTitle(UIStrings.agents)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    ForEach(sortedSources) { source in
                        AgentSpendTile(
                            descriptor: source.descriptor,
                            costUSD: source.totals.costUSD,
                            share: shareOfTotal(source.totals.costUSD),
                            tint: sourceColors[source.id] ?? DashboardTheme.color(for: source.id)
                        )
                    }
                }
            }
        }
    }

    /// Share is computed against the sum of the tiles themselves (not a
    /// separately-derived grand total) so percentages always foot to ~100%
    /// even if a caller's `totals` field was aggregated from a slightly
    /// different row set, and is clamped defensively either way.
    private var tilesCostSum: Decimal {
        sortedSources.reduce(Decimal(0)) { $0 + $1.totals.costUSD }
    }

    private func shareOfTotal(_ costUSD: Decimal) -> Double {
        guard tilesCostSum > 0 else { return 0 }
        let ratio = NSDecimalNumber(decimal: costUSD / tilesCostSum).doubleValue
        return min(max(ratio, 0), 1)
    }

    // MARK: - Trend chart

    private var sourceNamesByCostDesc: [String] {
        sortedSources.map { $0.descriptor.displayName }
    }

    private var colorScaleRange: [Color] {
        let colors = sourceColors
        return sortedSources.map { colors[$0.id] ?? DashboardTheme.color(for: $0.id) }
    }

    @ViewBuilder
    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                MenuSectionTitle(UIStrings.text(zh: "趋势", en: "Trend"))
                Spacer()
                Picker(UIStrings.text(zh: "指标", en: "Metric"), selection: $chartMetric) {
                    Text(UIStrings.spend).tag(DashboardChartMetric.spend)
                    Text(UIStrings.tokens).tag(DashboardChartMetric.tokens)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 140)
            }

            if snapshot.daily.isEmpty {
                MenuEmptyState(text: UIStrings.text(zh: "暂无趋势数据", en: "No trend data"))
                    .frame(height: 240)
            } else {
                chart
                    .frame(height: 240)
                    .padding(16)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))

                if let selectedDay, let breakdown = dayBreakdown(for: selectedDay) {
                    SelectedDayBreakdownCard(day: selectedDay, rows: breakdown, colors: sourceColors)
                }
            }
        }
    }

    private var chart: some View {
        Chart(snapshot.daily) { row in
            BarMark(
                x: .value(UIStrings.text(zh: "日期", en: "Date"), DashboardDateParsing.date(fromDay: row.day), unit: .day),
                y: .value(chartMetric.label, chartMetric.value(for: row))
            )
            .foregroundStyle(by: .value(UIStrings.text(zh: "来源", en: "Source"), sourceDisplayName(for: row.sourceID)))
            .cornerRadius(3)

            if let selectedDay, row.day == selectedDay {
                RuleMark(x: .value(UIStrings.text(zh: "日期", en: "Date"), DashboardDateParsing.date(fromDay: selectedDay), unit: .day))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(domain: sourceNamesByCostDesc, range: colorScaleRange)
        .chartLegend(position: .bottom, spacing: 10)
        .chartXSelection(value: selectedDateBinding)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(axisLabel(for: doubleValue))
                    }
                }
            }
        }
    }

    private var selectedDateBinding: Binding<Date?> {
        Binding(
            get: { selectedDay.map(DashboardDateParsing.date(fromDay:)) },
            set: { newValue in
                guard let newValue else {
                    selectedDay = nil
                    return
                }
                selectedDay = DashboardDateParsing.dayString(from: newValue)
            }
        )
    }

    /// Axis labels always show whole dollars (never cents, even for small
    /// values) so the y-axis stays compact regardless of `usdCompactString`'s
    /// sub-$1 precision, which is meant for headline numbers, not tick labels.
    private func axisLabel(for value: Double) -> String {
        switch chartMetric {
        case .spend:
            if value >= 10_000 {
                return "$" + String(format: "%.1f", value / 1_000) + "K"
            }
            return "$" + Int(value.rounded()).compactString
        case .tokens:
            return Int(value).compactString
        }
    }

    private func sourceDisplayName(for sourceID: AgentSourceID) -> String {
        descriptorsByID[sourceID]?.displayName ?? sourceID.rawValue
    }

    private func dayBreakdown(for day: String) -> [SelectedDayBreakdownCard.Row]? {
        let rows = snapshot.daily.filter { $0.day == day }
        guard !rows.isEmpty else { return nil }
        return rows
            .sorted { $0.costUSD > $1.costUSD }
            .map { row in
                SelectedDayBreakdownCard.Row(
                    sourceID: row.sourceID,
                    displayName: sourceDisplayName(for: row.sourceID),
                    costUSD: row.costUSD,
                    tokens: row.tokens.total
                )
            }
    }

    // MARK: - Projects

    private var visibleProjects: [MergedProjectRow] {
        let all = mergedProjects
        return showsAllProjects ? all : Array(all.prefix(Self.projectsCollapsedLimit))
    }

    @ViewBuilder
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            MenuSectionTitle(UIStrings.text(zh: "项目", en: "Projects"))

            if mergedProjects.isEmpty {
                MenuEmptyState(text: UIStrings.text(zh: "暂无项目数据", en: "No project activity"))
            } else {
                let maxCost = mergedProjects.first?.costUSD ?? 0
                let colors = sourceColors
                VStack(spacing: 0) {
                    ForEach(Array(visibleProjects.enumerated()), id: \.element.id) { index, project in
                        ProjectRow(project: project, descriptorsByID: descriptorsByID, colors: colors, maxCostUSD: maxCost)
                        if index < visibleProjects.count - 1 {
                            Divider().padding(.leading, 50)
                        }
                    }
                    if mergedProjects.count > Self.projectsCollapsedLimit {
                        Divider().padding(.leading, 10)
                        ShowAllToggle(isExpanded: showsAllProjects, totalCount: mergedProjects.count) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showsAllProjects.toggle()
                            }
                        }
                    }
                }
                .padding(8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Models

    /// Delivered by the DTO as one row per (modelFamily, source) pair, sorted
    /// by cost descending; intentionally NOT merged across sources the way
    /// projects are.
    private var sortedModels: [ModelUsageSummary] {
        snapshot.models.sorted { $0.costUSD > $1.costUSD }
    }

    private var visibleModels: [ModelUsageSummary] {
        showsAllModels ? sortedModels : Array(sortedModels.prefix(Self.modelsCollapsedLimit))
    }

    @ViewBuilder
    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            MenuSectionTitle(UIStrings.text(zh: "模型", en: "Models"))

            if sortedModels.isEmpty {
                MenuEmptyState(text: UIStrings.text(zh: "暂无模型数据", en: "No model activity"))
            } else {
                let maxCost = sortedModels.first?.costUSD ?? 0
                let colors = sourceColors
                let descriptors = descriptorsByID
                VStack(spacing: 0) {
                    ForEach(Array(visibleModels.enumerated()), id: \.element.id) { index, model in
                        ModelRow(
                            model: model,
                            descriptor: descriptors[model.sourceID],
                            tint: colors[model.sourceID] ?? DashboardTheme.color(for: model.sourceID),
                            maxCostUSD: maxCost
                        )
                        if index < visibleModels.count - 1 {
                            Divider().padding(.leading, 50)
                        }
                    }
                    if sortedModels.count > Self.modelsCollapsedLimit {
                        Divider().padding(.leading, 10)
                        ShowAllToggle(isExpanded: showsAllModels, totalCount: sortedModels.count) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showsAllModels.toggle()
                            }
                        }
                    }
                }
                .padding(8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

}

// MARK: - Selected day breakdown card

struct SelectedDayBreakdownCard: View {
    struct Row: Identifiable {
        let sourceID: AgentSourceID
        let displayName: String
        let costUSD: Decimal
        let tokens: Int

        var id: AgentSourceID { sourceID }
    }

    let day: String
    let rows: [Row]
    let colors: [AgentSourceID: Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DashboardDateParsing.displayString(fromDay: day))
                .font(.callout.weight(.semibold))

            VStack(spacing: 4) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(colors[row.sourceID] ?? DashboardTheme.color(for: row.sourceID))
                            .frame(width: 7, height: 7)
                        Text(row.displayName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.costUSD.usdCompactString)
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                        Text(row.tokens.compactString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

enum DashboardChartMetric: Hashable {
    case spend
    case tokens

    var label: String {
        switch self {
        case .spend: UIStrings.spend
        case .tokens: UIStrings.tokens
        }
    }

    func value(for row: DailyUsageSummary) -> Double {
        switch self {
        case .spend: NSDecimalNumber(decimal: row.costUSD).doubleValue
        case .tokens: Double(row.tokens.total)
        }
    }
}

/// Parses the "yyyy-MM-dd" day strings used throughout storage/aggregation
/// into `Date`s for chart x-axes. Shared by dashboard views only; storage and
/// aggregation keep working with the raw strings.
enum DashboardDateParsing {
    static func date(fromDay day: String) -> Date {
        formatter.date(from: day) ?? Date()
    }

    static func dayString(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func displayString(fromDay day: String) -> String {
        guard let date = formatter.date(from: day) else { return day }
        return displayFormatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
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

/// Invisible helper that captures the underlying `NSView` behind the share
/// button so `NSSharingServicePicker` can anchor its popover to it (SwiftUI's
/// `Menu` has no API to expose its own backing view). Reports its `superview`
/// — the actual button-sized view — rather than itself, since this view is
/// zero-sized background content with no frame of its own.
private struct ShareAnchorCapture: NSViewRepresentable {
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            anchorView = view.superview ?? view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if anchorView == nil {
            anchorView = nsView.superview ?? nsView
        }
    }
}
