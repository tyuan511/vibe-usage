import SwiftUI
import VibeUsageCore

public struct VibeUsageSettingsView: View {
    let configurableAgentSources: [AgentSourceDescriptor]
    @Binding var menuBarMetricMode: MenuBarMetricMode
    @Binding var hiddenAgentSourceIDs: Set<AgentSourceID>
    @Binding var enablesLimitMonitoring: Bool
    @Binding var hiddenQuotaSourceIDs: Set<AgentSourceID>
    let currentVersion: String
    let canCheckForUpdates: Bool
    let onCheckForUpdates: () -> Void

    public init(
        configurableAgentSources: [AgentSourceDescriptor],
        menuBarMetricMode: Binding<MenuBarMetricMode>,
        hiddenAgentSourceIDs: Binding<Set<AgentSourceID>>,
        enablesLimitMonitoring: Binding<Bool>,
        hiddenQuotaSourceIDs: Binding<Set<AgentSourceID>>,
        currentVersion: String,
        canCheckForUpdates: Bool,
        onCheckForUpdates: @escaping () -> Void
    ) {
        self.configurableAgentSources = configurableAgentSources
        self._menuBarMetricMode = menuBarMetricMode
        self._hiddenAgentSourceIDs = hiddenAgentSourceIDs
        self._enablesLimitMonitoring = enablesLimitMonitoring
        self._hiddenQuotaSourceIDs = hiddenQuotaSourceIDs
        self.currentVersion = currentVersion
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
            } header: {
                Text(UIStrings.text(zh: "菜单栏", en: "Menu Bar"))
            } footer: {
                Text(UIStrings.text(
                    zh: "金额和 Token 始终统计今天，并使用下方的 Agent 统计范围。",
                    en: "Spend and tokens always cover today and use the agent selection below."
                ))
            }

            Section {
                agentSelection(
                    title: UIStrings.text(zh: "统计 Agent", en: "Included agents"),
                    hiddenSourceIDs: $hiddenAgentSourceIDs
                )
            } header: {
                Text(UIStrings.text(zh: "Agent 统计", en: "Agent Usage"))
            } footer: {
                Text(UIStrings.text(
                    zh: "该选择同时影响菜单栏指标，以及下拉中的总金额、Token、热力图、Agent 和模型。新发现的 Agent 默认自动加入。",
                    en: "This selection affects the menu bar metric and all popover usage. Newly discovered agents are included automatically."
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
                LabeledContent(
                    UIStrings.text(zh: "当前版本", en: "Current Version"),
                    value: currentVersion
                )
                HStack {
                    Text(UIStrings.checkForUpdates)
                    Spacer()
                    Button(UIStrings.text(zh: "检查", en: "Check"), action: onCheckForUpdates)
                        .disabled(!canCheckForUpdates)
                }
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
