import AppKit
import SwiftUI
import VibeUsageAggregation
import VibeUsageCore

public struct MenuBarUsageView: View {
    let snapshot: UsageDashboardSnapshot
    let isRefreshing: Bool
    let lastError: String?
    let configurableAgentSources: [AgentSourceDescriptor]
    let hiddenAgentSourceIDs: Set<AgentSourceID>
    @Binding var selectedDateRange: UsageDateRangePreset
    @Binding var selectedModelFilter: Set<String>
    let onRefresh: () -> Void
    let onFilterChange: () -> Void
    let onAgentDisplayCommit: (_ hiddenSourceIDs: Set<AgentSourceID>) -> Void
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
        selectedModelFilter: Binding<Set<String>>,
        onRefresh: @escaping () -> Void,
        onFilterChange: @escaping () -> Void,
        onAgentDisplayCommit: @escaping (Set<AgentSourceID>) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        self.lastError = lastError
        self.configurableAgentSources = configurableAgentSources
        self.hiddenAgentSourceIDs = hiddenAgentSourceIDs
        self._selectedDateRange = selectedDateRange
        self._selectedModelFilter = selectedModelFilter
        self.onRefresh = onRefresh
        self.onFilterChange = onFilterChange
        self.onAgentDisplayCommit = onAgentDisplayCommit
        self.onQuit = onQuit
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
                modelsHeader
                modelsList
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

    private var dateRangeMenu: some View {
        Picker(UIStrings.text(zh: "时间", en: "Time"), selection: dateRangeSelection) {
            ForEach(UsageDateRangePreset.allCases) { range in
                Text(range.displayName).tag(range)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
        .frame(width: 96)
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

    private var modelFilterMenu: some View {
        Picker(UIStrings.allModels, selection: modelFilterSelection) {
            Text(UIStrings.allModels).tag("")
            ForEach(snapshot.availableModels) { model in
                Text(model.modelFamily).tag(model.modelFamily)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .labelsHidden()
        .frame(maxWidth: 140)
    }

    @ViewBuilder
    private var modelsList: some View {
        if snapshot.models.isEmpty {
            MenuEmptyState(text: UIStrings.text(zh: "暂无模型活动", en: "No model activity"))
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.models.enumerated()), id: \.element.id) { index, model in
                        ModelMetricRow(model: model)
                        if index < snapshot.models.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
            .padding(8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        }
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
                selectedModelFilter.count == 1 ? selectedModelFilter.first ?? "" : ""
            },
            set: { value in
                if value.isEmpty {
                    selectedModelFilter = []
                } else {
                    selectedModelFilter = [value]
                }
                onFilterChange()
            }
        )
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
