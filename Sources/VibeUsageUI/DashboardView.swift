import AppKit
import SwiftUI
import VibeUsageAggregation
import VibeUsageCore

public struct DashboardView: View {
    let snapshot: UsageDashboardSnapshot
    let isRefreshing: Bool
    let lastError: String?
    let onRefresh: () -> Void

    public init(
        snapshot: UsageDashboardSnapshot,
        isRefreshing: Bool,
        lastError: String?,
        onRefresh: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        self.lastError = lastError
        self.onRefresh = onRefresh
    }

    public var body: some View {
        NavigationSplitView {
            List {
                Section(L.text(zh: "来源", en: "Sources")) {
                    ForEach(snapshot.sources) { source in
                        SourceRow(source: source)
                    }
                }
            }
            .navigationTitle("VibeUsage")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    totalsGrid
                    if let lastError {
                        Text(lastError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    dailySection
                    modelSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.text(zh: "用量", en: "Usage"))
                    .font(.largeTitle.weight(.semibold))
                Text(L.range(snapshot.rangeStartDay, snapshot.rangeEndDay))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRefresh) {
                Label(isRefreshing ? L.scanning : L.refresh, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glassProminent)
            .disabled(isRefreshing)
        }
    }

    private var totalsGrid: some View {
        GlassEffectContainer {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    MetricTile(title: L.cost, value: snapshot.totals.costUSD.usdString)
                    MetricTile(title: L.tokens, value: snapshot.totals.tokens.total.compactString)
                    MetricTile(title: L.events, value: snapshot.totals.eventCount.compactString)
                }
                GridRow {
                    MetricTile(title: L.input, value: snapshot.totals.tokens.input.compactString)
                    MetricTile(title: L.output, value: snapshot.totals.tokens.output.compactString)
                    MetricTile(title: L.cacheRead, value: snapshot.totals.tokens.cacheRead.compactString)
                }
            }
        }
    }

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.text(zh: "每日", en: "Daily"))
                .font(.title2.weight(.semibold))
            if snapshot.daily.isEmpty {
                EmptyState(text: L.text(zh: "还没有发现本地用量。", en: "No local usage found yet."))
            } else {
                Table(snapshot.daily.suffix(14)) {
                    TableColumn(L.text(zh: "日期", en: "Day"), value: \.day)
                    TableColumn(L.text(zh: "来源", en: "Source")) { row in
                        Text(row.sourceID.rawValue)
                    }
                    TableColumn(L.tokens) { row in
                        Text(row.tokens.total.compactString)
                    }
                    TableColumn(L.cost) { row in
                        Text(row.costUSD.usdString)
                    }
                }
                .frame(minHeight: 260)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.models)
                .font(.title2.weight(.semibold))
            if snapshot.models.isEmpty {
                EmptyState(text: L.text(zh: "首次扫描后会显示模型明细。", en: "Model breakdown appears after the first scan."))
            } else {
                Table(snapshot.models.prefix(20).map { $0 }) {
                    TableColumn(L.text(zh: "模型", en: "Model"), value: \.modelFamily)
                    TableColumn(L.text(zh: "来源", en: "Source")) { row in
                        Text(row.sourceID.rawValue)
                    }
                    TableColumn(L.events) { row in
                        Text(row.eventCount.compactString)
                    }
                    TableColumn(L.tokens) { row in
                        Text(row.tokens.total.compactString)
                    }
                    TableColumn(L.cost) { row in
                        Text(row.costUSD.usdString)
                    }
                }
                .frame(minHeight: 300)
            }
        }
    }
}

public struct MenuBarUsageView: View {
    let snapshot: UsageDashboardSnapshot
    let isRefreshing: Bool
    let lastError: String?
    let configurableAgentSources: [AgentSourceDescriptor]
    let hiddenAgentSourceIDs: Set<AgentSourceID>
    @Binding var selectedDateRange: UsageDateRangePreset
    let onRefresh: () -> Void
    let onFilterChange: () -> Void
    let onAgentVisibilityCommit: (Set<AgentSourceID>) -> Void
    let onQuit: () -> Void
    @State private var showsAgentSettings = false
    @State private var draftHiddenAgentSourceIDs = Set<AgentSourceID>()

    public init(
        snapshot: UsageDashboardSnapshot,
        isRefreshing: Bool,
        lastError: String?,
        configurableAgentSources: [AgentSourceDescriptor],
        hiddenAgentSourceIDs: Set<AgentSourceID>,
        selectedDateRange: Binding<UsageDateRangePreset>,
        onRefresh: @escaping () -> Void,
        onFilterChange: @escaping () -> Void,
        onAgentVisibilityCommit: @escaping (Set<AgentSourceID>) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        self.lastError = lastError
        self.configurableAgentSources = configurableAgentSources
        self.hiddenAgentSourceIDs = hiddenAgentSourceIDs
        self._selectedDateRange = selectedDateRange
        self.onRefresh = onRefresh
        self.onFilterChange = onFilterChange
        self.onAgentVisibilityCommit = onAgentVisibilityCommit
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            menuHeader

            GlassEffectContainer {
                HStack(spacing: 8) {
                    MenuMetricCard(
                        title: L.spend,
                        value: snapshot.totals.costUSD.usdString,
                        systemImage: "creditcard"
                    )
                    MenuMetricCard(
                        title: L.tokens,
                        value: snapshot.totals.tokens.total.compactString,
                        systemImage: "number.circle"
                    )
                }
            }

            ActivityHeatmap(
                daily: snapshot.activity,
                generatedAt: snapshot.generatedAt
            )

            VStack(alignment: .leading, spacing: 7) {
                agentsHeader
                agentsList
            }

            VStack(alignment: .leading, spacing: 7) {
                MenuSectionTitle(L.models)
                if snapshot.models.isEmpty {
                    MenuEmptyState(text: L.text(zh: "暂无模型活动", en: "No model activity"))
                } else {
                    let models = Array(snapshot.models.prefix(6))
                    VStack(spacing: 0) {
                        ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                            ModelMetricRow(model: model)
                            if index < models.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(8)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                }
            }

            menuFooter
        }
        .padding(14)
        .frame(width: 388)
    }

    private var menuHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VibeUsageLogo(size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("VibeUsage")
                    .font(.headline)
                Text(L.updated(snapshot.generatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            GlassEffectContainer {
                HStack(spacing: 7) {
                    dateRangeMenu

                    Button(action: onRefresh) {
                        Image(systemName: isRefreshing ? "hourglass" : "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .disabled(isRefreshing)
                    .help(L.refresh)

                    Button(action: onQuit) {
                        Image(systemName: "power")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .help(L.text(zh: "退出 VibeUsage", en: "Quit VibeUsage"))
                }
            }
        }
    }

    private var dateRangeMenu: some View {
        Picker(L.text(zh: "时间", en: "Time"), selection: dateRangeSelection) {
            ForEach(UsageDateRangePreset.allCases) { range in
                Text(range.displayName).tag(range)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
        .frame(width: 96)
    }

    private var agentsHeader: some View {
        HStack(alignment: .center) {
            MenuSectionTitle(L.agents)
            Spacer()
            Button {
                toggleAgentSettings()
            } label: {
                if showsAgentSettings {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(showsAgentSettings ? L.done : L.text(zh: "Agent 设置", en: "Agent Settings"))
        }
    }

    @ViewBuilder
    private var agentsList: some View {
        if showsAgentSettings {
            if configurableAgentSources.isEmpty {
                MenuEmptyState(text: L.text(zh: "没有本地 Agent", en: "No local agents"))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(configurableAgentSources.enumerated()), id: \.element.id) { index, descriptor in
                        Toggle(isOn: draftAgentVisibilityBinding(for: descriptor.id)) {
                            AgentSettingLabel(descriptor: descriptor)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .padding(.vertical, 6)

                        if index < configurableAgentSources.count - 1 {
                            Divider().padding(.leading, 26)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            }
        } else if snapshot.sources.isEmpty {
            MenuEmptyState(text: L.text(zh: "暂无 Agent 数据", en: "No agent data"))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.sources.enumerated()), id: \.element.id) { index, source in
                    SourceMetricRow(source: source)
                    if index < snapshot.sources.count - 1 {
                        Divider().padding(.leading, 26)
                    }
                }
            }
            .padding(8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var menuFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lastError {
                Divider()
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private var dateRangeSelection: Binding<UsageDateRangePreset> {
        Binding(
            get: { selectedDateRange },
            set: { value in
                selectedDateRange = value
                onFilterChange()
            }
        )
    }

    private func draftAgentVisibilityBinding(for sourceID: AgentSourceID) -> Binding<Bool> {
        Binding(
            get: { !draftHiddenAgentSourceIDs.contains(sourceID) },
            set: { isVisible in
                if isVisible {
                    draftHiddenAgentSourceIDs.remove(sourceID)
                } else {
                    draftHiddenAgentSourceIDs.insert(sourceID)
                }
            }
        )
    }

    private func toggleAgentSettings() {
        if showsAgentSettings {
            showsAgentSettings = false
            onAgentVisibilityCommit(draftHiddenAgentSourceIDs)
        } else {
            draftHiddenAgentSourceIDs = hiddenAgentSourceIDs
            showsAgentSettings = true
        }
    }
}

private struct MenuMetricCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MenuSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct MenuEmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 42)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ActivityHeatmap: View {
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
                MenuSectionTitle(L.text(zh: "活跃", en: "Activity"))
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
        L.activityDetail(day: day.day, tokens: day.totals.tokens.total.compactString, cost: day.totals.costUSD.usdString)
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

private struct VibeUsageLogo: View {
    private let size: CGFloat

    init(size: CGFloat) {
        self.size = size
    }

    var body: some View {
        Image(nsImage: Self.logoImage)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private static var logoImage: NSImage {
        guard let url = VibeUsageUIResources.bundle.url(forResource: "logo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSApp.applicationIconImage
        }
        return image
    }
}

private struct ActivityDay: Identifiable {
    let day: String
    let totals: UsageTotals

    var id: String { day }
}

private struct ActivityAccumulator {
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

private struct AgentSourceIcon: View {
    let descriptor: AgentSourceDescriptor
    let size: CGFloat
    let imageSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(descriptor: AgentSourceDescriptor, size: CGFloat, imageSize: CGFloat = 14) {
        self.descriptor = descriptor
        self.size = size
        self.imageSize = imageSize
    }

    var body: some View {
        Group {
            if let image = AgentIconStore.image(for: descriptor.id, colorScheme: colorScheme) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: imageSize, height: imageSize)
            } else {
                Image(systemName: descriptor.iconSystemName)
                    .font(.system(size: imageSize * 0.75, weight: .medium))
                    .foregroundStyle(Color(hex: descriptor.tintColorHex))
                    .frame(width: imageSize, height: imageSize)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private enum AgentIconStore {
    static func image(for sourceID: AgentSourceID, colorScheme: ColorScheme) -> NSImage? {
        let appearance = colorScheme == .dark ? "dark" : "light"
        guard let url = VibeUsageUIResources.bundle.url(
            forResource: sourceID.rawValue,
            withExtension: "png",
            subdirectory: "AgentIcons/\(appearance)"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

private enum VibeUsageUIResources {
    static var bundle: Bundle {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("VibeUsage_VibeUsageUI.bundle"),
           let bundle = Bundle(url: resourceURL) {
            return bundle
        }
        return .module
    }
}

private struct AgentSettingLabel: View {
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

private struct SourceMetricRow: View {
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

private struct ModelMetricRow: View {
    let model: ModelUsageSummary

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.modelFamily)
                    .font(.callout)
                    .lineLimit(1)
                Text(L.modelTokenLine(sourceID: model.sourceID.rawValue, tokens: model.tokens.total.compactString))
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

private struct SourceRow: View {
    let source: SourceUsageSummary

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.descriptor.displayName)
                Text(source.totals.costUSD.usdString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            AgentSourceIcon(descriptor: source.descriptor, size: 18)
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct EmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}

private enum L {
    static func text(zh: String, en: String) -> String {
        VibeUsageStrings.text(zh: zh, en: en)
    }

    static let scanning = text(zh: "扫描中", en: "Scanning")
    static let refresh = text(zh: "刷新", en: "Refresh")
    static let spend = text(zh: "花费", en: "Spend")
    static let cost = text(zh: "费用", en: "Cost")
    static let tokens = text(zh: "Tokens", en: "Tokens")
    static let events = text(zh: "事件", en: "Events")
    static let input = text(zh: "输入", en: "Input")
    static let output = text(zh: "输出", en: "Output")
    static let cacheRead = text(zh: "缓存读取", en: "Cache Read")
    static let agents = text(zh: "Agents", en: "Agents")
    static let models = text(zh: "模型", en: "Models")
    static let done = text(zh: "完成", en: "Done")

    static func updated(_ date: Date) -> String {
        text(
            zh: "更新于 \(date.formatted(date: .omitted, time: .shortened))",
            en: "Updated \(date.formatted(date: .omitted, time: .shortened))"
        )
    }

    static func range(_ start: String, _ end: String) -> String {
        text(zh: "\(start) 至 \(end)", en: "\(start) to \(end)")
    }

    static func activityDetail(day: String, tokens: String, cost: String) -> String {
        text(zh: "\(day): \(tokens) tokens, \(cost)", en: "\(day): \(tokens) tokens, \(cost)")
    }

    static func modelTokenLine(sourceID: String, tokens: String) -> String {
        text(zh: "\(sourceID) · \(tokens) tokens", en: "\(sourceID) · \(tokens) tokens")
    }
}

private extension Decimal {
    var usdString: String {
        let number = self as NSDecimalNumber
        return numberFormatter.string(from: number) ?? "$0.00"
    }

    func fraction(of maxValue: Decimal) -> Double {
        guard maxValue > 0 else { return 0 }
        let value = (self as NSDecimalNumber).doubleValue
        let maximum = (maxValue as NSDecimalNumber).doubleValue
        guard maximum > 0 else { return 0 }
        return min(1, Swift.max(0, value / maximum))
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = self < 1 ? 4 : 2
        return formatter
    }
}

private extension Int {
    var compactString: String {
        let absolute = abs(self)
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
        if absolute >= 1_000 {
            return String(format: "%.1fK", Double(self) / 1_000).replacingOccurrences(of: ".0K", with: "K")
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(hex, radix: 16) ?? 0
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
