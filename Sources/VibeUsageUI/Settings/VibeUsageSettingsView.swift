import SwiftUI
import VibeUsageCore

public struct VibeUsageSettingsView: View {
    let configurableAgentSources: [AgentSourceDescriptor]
    @Binding var menuBarMetricMode: MenuBarMetricMode
    @Binding var hiddenMenuBarMetricSourceIDs: Set<AgentSourceID>
    @Binding var hiddenDropdownSourceIDs: Set<AgentSourceID>
    @Binding var enablesLimitMonitoring: Bool
    @Binding var hiddenQuotaSourceIDs: Set<AgentSourceID>
    let canCheckForUpdates: Bool
    let onCheckForUpdates: () -> Void

    public init(
        configurableAgentSources: [AgentSourceDescriptor],
        menuBarMetricMode: Binding<MenuBarMetricMode>,
        hiddenMenuBarMetricSourceIDs: Binding<Set<AgentSourceID>>,
        hiddenDropdownSourceIDs: Binding<Set<AgentSourceID>>,
        enablesLimitMonitoring: Binding<Bool>,
        hiddenQuotaSourceIDs: Binding<Set<AgentSourceID>>,
        canCheckForUpdates: Bool,
        onCheckForUpdates: @escaping () -> Void
    ) {
        self.configurableAgentSources = configurableAgentSources
        self._menuBarMetricMode = menuBarMetricMode
        self._hiddenMenuBarMetricSourceIDs = hiddenMenuBarMetricSourceIDs
        self._hiddenDropdownSourceIDs = hiddenDropdownSourceIDs
        self._enablesLimitMonitoring = enablesLimitMonitoring
        self._hiddenQuotaSourceIDs = hiddenQuotaSourceIDs
        self.canCheckForUpdates = canCheckForUpdates
        self.onCheckForUpdates = onCheckForUpdates
    }

    public var body: some View {
        Form {
            Section {
                Picker(
                    UIStrings.text(zh: "指标", en: "Metric"),
                    selection: $menuBarMetricMode
                ) {
                    Text(UIStrings.text(zh: "不显示", en: "Hidden")).tag(MenuBarMetricMode.hidden)
                    Text(UIStrings.text(zh: "金额", en: "Spend")).tag(MenuBarMetricMode.spend)
                    Text(UIStrings.tokens).tag(MenuBarMetricMode.tokens)
                }
                .pickerStyle(.segmented)

                if menuBarMetricMode != .hidden {
                    agentSelection(
                        title: UIStrings.text(zh: "计入菜单栏统计", en: "Included in menu bar total"),
                        hiddenSourceIDs: $hiddenMenuBarMetricSourceIDs
                    )
                }
            } header: {
                Text(UIStrings.text(zh: "菜单栏", en: "Menu Bar"))
            } footer: {
                Text(UIStrings.text(
                    zh: "金额和 Token 始终统计今天；新发现的 Agent 默认自动加入。",
                    en: "Spend and tokens always cover today. Newly discovered agents are included automatically."
                ))
            }

            Section {
                agentSelection(
                    title: UIStrings.text(zh: "下拉统计 Agent", en: "Agents included in the popover"),
                    hiddenSourceIDs: $hiddenDropdownSourceIDs
                )
            } header: {
                Text(UIStrings.text(zh: "下拉显示", en: "Popover"))
            } footer: {
                Text(UIStrings.text(
                    zh: "该选择会同时影响下拉中的总金额、Token、热力图、Agent 和模型。",
                    en: "This selection affects popover totals, tokens, activity, agents, and models."
                ))
            }

            Section {
                Toggle(
                    UIStrings.text(zh: "监控订阅额度（联网）", en: "Monitor subscription limits (network)"),
                    isOn: $enablesLimitMonitoring
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(UIStrings.text(zh: "下拉显示的额度", en: "Limits shown in the popover"))
                        .font(.callout.weight(.medium))
                    quotaToggle("Claude", sourceID: .claudeQuota)
                    quotaToggle("Codex", sourceID: .codexQuota)
                }
                .disabled(!enablesLimitMonitoring)
            } header: {
                Text(UIStrings.text(zh: "网络与额度", en: "Network & Limits"))
            } footer: {
                if !enablesLimitMonitoring {
                    Text(UIStrings.text(
                        zh: "开启额度监控后可修改显示范围。之前的选择会被保留。",
                        en: "Enable limit monitoring to change visibility. Previous choices are preserved."
                    ))
                }
            }

            Section(UIStrings.text(zh: "更新", en: "Updates")) {
                Button(UIStrings.checkForUpdates, action: onCheckForUpdates)
                    .disabled(!canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }

    private func agentSelection(
        title: String,
        hiddenSourceIDs: Binding<Set<AgentSourceID>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
            if configurableAgentSources.isEmpty {
                Text(UIStrings.text(zh: "尚未发现本地 Agent", en: "No local agents discovered"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(configurableAgentSources) { descriptor in
                    Toggle(isOn: visibilityBinding(for: descriptor.id, hiddenSourceIDs: hiddenSourceIDs)) {
                        AgentSettingLabel(descriptor: descriptor)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func quotaToggle(_ title: String, sourceID: AgentSourceID) -> some View {
        Toggle(isOn: visibilityBinding(for: sourceID, hiddenSourceIDs: $hiddenQuotaSourceIDs)) {
            Text(title)
        }
        .toggleStyle(.checkbox)
    }

    private func visibilityBinding(
        for sourceID: AgentSourceID,
        hiddenSourceIDs: Binding<Set<AgentSourceID>>
    ) -> Binding<Bool> {
        Binding(
            get: { !hiddenSourceIDs.wrappedValue.contains(sourceID) },
            set: { isVisible in
                if isVisible {
                    hiddenSourceIDs.wrappedValue.remove(sourceID)
                } else {
                    hiddenSourceIDs.wrappedValue.insert(sourceID)
                }
            }
        )
    }
}
