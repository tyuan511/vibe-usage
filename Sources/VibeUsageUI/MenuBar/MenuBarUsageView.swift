import AppKit
import SwiftUI
import VibeUsageAggregation
import VibeUsageCore
import VibeUsageQuota

public struct MenuBarUsageView: View {
    let snapshot: UsageDashboardSnapshot
    let isRefreshing: Bool
    let lastError: String?
    let configurableAgentSources: [AgentSourceDescriptor]
    let hiddenAgentSourceIDs: Set<AgentSourceID>
    let quota: QuotaSnapshot
    let quotaConnectUIStates: [AgentSourceID: QuotaConnectUIState]
    @Binding var selectedDateRange: UsageDateRangePreset
    @Binding var selectedModelFilter: Set<String>
    @Binding var showsSpendInMenuBar: Bool
    @Binding var enablesLimitMonitoring: Bool
    let onRefresh: () -> Void
    let onFilterChange: () -> Void
    let onAgentDisplayCommit: (_ hiddenSourceIDs: Set<AgentSourceID>) -> Void
    let onOpenDashboard: () -> Void
    let onQuit: () -> Void
    let onQuotaConnect: (AgentSourceID) -> Void
    let onQuotaDisconnect: (AgentSourceID) -> Void
    let onQuotaCancelConnect: (AgentSourceID) -> Void
    @State private var showsAgentSettings = false
    @State private var draftHiddenAgentSourceIDs = Set<AgentSourceID>()

    public init(
        snapshot: UsageDashboardSnapshot,
        isRefreshing: Bool,
        lastError: String?,
        configurableAgentSources: [AgentSourceDescriptor],
        hiddenAgentSourceIDs: Set<AgentSourceID>,
        quota: QuotaSnapshot,
        quotaConnectUIStates: [AgentSourceID: QuotaConnectUIState] = [:],
        selectedDateRange: Binding<UsageDateRangePreset>,
        selectedModelFilter: Binding<Set<String>>,
        showsSpendInMenuBar: Binding<Bool>,
        enablesLimitMonitoring: Binding<Bool>,
        onRefresh: @escaping () -> Void,
        onFilterChange: @escaping () -> Void,
        onAgentDisplayCommit: @escaping (Set<AgentSourceID>) -> Void,
        onOpenDashboard: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onQuotaConnect: @escaping (AgentSourceID) -> Void = { _ in },
        onQuotaDisconnect: @escaping (AgentSourceID) -> Void = { _ in },
        onQuotaCancelConnect: @escaping (AgentSourceID) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        self.lastError = lastError
        self.configurableAgentSources = configurableAgentSources
        self.hiddenAgentSourceIDs = hiddenAgentSourceIDs
        self.quota = quota
        self.quotaConnectUIStates = quotaConnectUIStates
        self._selectedDateRange = selectedDateRange
        self._selectedModelFilter = selectedModelFilter
        self._showsSpendInMenuBar = showsSpendInMenuBar
        self._enablesLimitMonitoring = enablesLimitMonitoring
        self.onRefresh = onRefresh
        self.onFilterChange = onFilterChange
        self.onAgentDisplayCommit = onAgentDisplayCommit
        self.onOpenDashboard = onOpenDashboard
        self.onQuit = onQuit
        self.onQuotaConnect = onQuotaConnect
        self.onQuotaDisconnect = onQuotaDisconnect
        self.onQuotaCancelConnect = onQuotaCancelConnect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            menuHeader

            GlassEffectContainer {
                HStack(spacing: 8) {
                    MenuMetricCard(
                        title: UIStrings.spend,
                        value: snapshot.totals.costUSD.usdString,
                        systemImage: "creditcard"
                    )
                    MenuMetricCard(
                        title: UIStrings.tokens,
                        value: snapshot.totals.tokens.total.compactString,
                        systemImage: "number.circle",
                        detail: cacheReadDetailText
                    )
                }
            }

            quotaSection

            ActivityHeatmap(
                daily: snapshot.activity,
                generatedAt: snapshot.generatedAt
            )

            VStack(alignment: .leading, spacing: 7) {
                agentsHeader
                agentsList
            }

            VStack(alignment: .leading, spacing: 7) {
                modelsHeader
                modelsList
            }

            menuFooter
        }
        .padding(14)
        .frame(width: 388)
    }

    private var cacheReadDetailText: String? {
        guard let ratio = snapshot.totals.tokens.cacheReadRatio else { return nil }
        return "\(UIStrings.cacheRead) \(UIStrings.percentage(ratio))"
    }

    private var menuHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VibeUsageLogo(size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("VibeUsage")
                    .font(.headline)
                if isRefreshing {
                    Text(UIStrings.scanning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(UIStrings.updated(snapshot.generatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            GlassEffectContainer {
                HStack(spacing: 7) {
                    dateRangeMenu

                    Button(action: onOpenDashboard) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .help(UIStrings.text(zh: "打开控制台", en: "Open Console"))

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
                    .help(UIStrings.refresh)

                    Button(action: onQuit) {
                        Image(systemName: "power")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .help(UIStrings.text(zh: "退出 VibeUsage", en: "Quit VibeUsage"))
                }
            }
        }
    }

    private var descriptorsByID: [AgentSourceID: AgentSourceDescriptor] {
        Dictionary(uniqueKeysWithValues: snapshot.discoveredSources.map { ($0.id, $0) })
    }

    @ViewBuilder
    private var quotaSection: some View {
        if !quota.sources.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                MenuSectionTitle(QuotaUIStrings.sectionTitle)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(quota.sources.enumerated()), id: \.element.id) { index, source in
                        QuotaSourceRow(
                            snapshot: source,
                            descriptor: descriptorsByID[source.sourceID],
                            connectUIState: quotaConnectUIStates[source.sourceID],
                            onConnect: onQuotaConnect,
                            onDisconnect: onQuotaDisconnect,
                            onCancelConnect: onQuotaCancelConnect
                        )
                        if index < quota.sources.count - 1 {
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dateRangeMenu: some View {
        Picker(UIStrings.text(zh: "时间", en: "Time"), selection: dateRangeSelection) {
            ForEach(UsageDateRangePreset.allCases) { range in
                Text(range.displayName).tag(range)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
        .frame(width: 112)
    }

    private var modelsHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            MenuSectionTitle(UIStrings.models)
            Spacer()
            if !snapshot.availableModels.isEmpty {
                modelFilterMenu
            }
        }
    }

    private static let allModelsTag = "__all__"

    private var modelFilterMenu: some View {
        Picker(UIStrings.allModels, selection: modelFilterSelection) {
            Text(UIStrings.allModels).tag(Self.allModelsTag)
            ForEach(snapshot.availableModels) { model in
                Text(modelPickerLabel(model)).tag(model.id)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
        .frame(maxWidth: 140)
    }

    private func modelPickerLabel(_ model: ModelUsageSummary) -> String {
        let sameFamilyCount = snapshot.availableModels.filter { $0.modelFamily == model.modelFamily }.count
        if sameFamilyCount > 1 {
            return "\(model.modelFamily) · \(model.sourceID.rawValue)"
        }
        return model.modelFamily
    }

    private static let modelsMaxScrollHeight: CGFloat = 180
    private static let modelsRowHeight: CGFloat = 40

    private var modelsListContentHeight: CGFloat {
        let count = snapshot.models.count
        let dividers = CGFloat(max(0, count - 1))
        return CGFloat(count) * Self.modelsRowHeight + dividers + 16
    }

    private var modelsListNeedsScroll: Bool {
        modelsListContentHeight > Self.modelsMaxScrollHeight
    }

    @ViewBuilder
    private var modelsList: some View {
        if snapshot.models.isEmpty {
            MenuEmptyState(text: UIStrings.text(zh: "暂无模型活动", en: "No model activity"))
        } else if modelsListNeedsScroll {
            MenuScrollList(height: Self.modelsMaxScrollHeight) {
                modelsListContent
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        } else {
            modelsListContent
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var modelsListContent: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshot.models.enumerated()), id: \.element.id) { index, model in
                ModelMetricRow(model: model)
                if index < snapshot.models.count - 1 {
                    Divider()
                }
            }
        }
        .padding(8)
    }

    private var agentsHeader: some View {
        HStack(alignment: .center) {
            MenuSectionTitle(UIStrings.agents)
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
            .help(showsAgentSettings ? UIStrings.done : UIStrings.text(zh: "显示设置", en: "Display Settings"))
        }
    }

    @ViewBuilder
    private var agentsList: some View {
        if showsAgentSettings {
            VStack(alignment: .leading, spacing: 7) {
                showsSpendInMenuBarRow
                enablesLimitMonitoringRow

                if configurableAgentSources.isEmpty {
                    MenuEmptyState(text: UIStrings.text(zh: "没有本地 Agent", en: "No local agents"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(configurableAgentSources.enumerated()), id: \.element.id) { index, descriptor in
                            agentSettingsRow(for: descriptor)
                            if index < configurableAgentSources.count - 1 {
                                Divider().padding(.leading, 26)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        } else if snapshot.sources.isEmpty {
            MenuEmptyState(text: UIStrings.text(zh: "暂无 Agent 数据", en: "No agent data"))
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
                HStack(alignment: .top, spacing: 8) {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    Button(UIStrings.refresh, action: onRefresh)
                        .controlSize(.small)
                }
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

    private var modelFilterSelection: Binding<String> {
        Binding(
            get: {
                guard selectedModelFilter.count == 1, let family = selectedModelFilter.first else {
                    return Self.allModelsTag
                }
                return snapshot.availableModels.first(where: { $0.modelFamily == family })?.id ?? Self.allModelsTag
            },
            set: { value in
                if value == Self.allModelsTag {
                    selectedModelFilter = []
                } else if let model = snapshot.availableModels.first(where: { $0.id == value }) {
                    selectedModelFilter = [model.modelFamily]
                } else {
                    selectedModelFilter = []
                }
                onFilterChange()
            }
        )
    }

    private var showsSpendInMenuBarRow: some View {
        HStack(spacing: 8) {
            Text(UIStrings.text(zh: "菜单栏显示今日花费", en: "Show today's spend in menu bar"))
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle(isOn: $showsSpendInMenuBar) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var enablesLimitMonitoringRow: some View {
        HStack(spacing: 8) {
            Text(UIStrings.text(zh: "监控订阅额度（联网）", en: "Monitor subscription limits (network)"))
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle(isOn: $enablesLimitMonitoring) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private func agentSettingsRow(for descriptor: AgentSourceDescriptor) -> some View {
        HStack(spacing: 8) {
            AgentSettingLabel(descriptor: descriptor)
            Spacer(minLength: 0)
            Toggle(isOn: draftAgentVisibilityBinding(for: descriptor.id)) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.vertical, 6)
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
            onAgentDisplayCommit(draftHiddenAgentSourceIDs)
        } else {
            draftHiddenAgentSourceIDs = hiddenAgentSourceIDs
            showsAgentSettings = true
        }
    }
}
