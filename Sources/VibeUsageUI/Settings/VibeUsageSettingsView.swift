import SwiftUI
import VibeUsageCore

public struct VibeUsageSettingsView: View {
    let configurableAgentSources: [AgentSourceDescriptor]
    @Binding var launchesAtLogin: Bool
    @Binding var menuBarMetricMode: MenuBarMetricMode
    @Binding var hiddenAgentSourceIDs: Set<AgentSourceID>
    @Binding var enablesLimitMonitoring: Bool
    @Binding var hiddenQuotaSourceIDs: Set<AgentSourceID>
    let pricingLastUpdatedAt: Date?
    let pricingUpdateError: String?
    let isUpdatingPricing: Bool
    let onUpdatePricing: () -> Void
    let loginItemRequiresApproval: Bool
    let loginItemError: String?
    let onOpenLoginItemSettings: () -> Void
    let currentVersion: String
    let canCheckForUpdates: Bool
    let onCheckForUpdates: () -> Void

    public init(
        configurableAgentSources: [AgentSourceDescriptor],
        launchesAtLogin: Binding<Bool>,
        menuBarMetricMode: Binding<MenuBarMetricMode>,
        hiddenAgentSourceIDs: Binding<Set<AgentSourceID>>,
        enablesLimitMonitoring: Binding<Bool>,
        hiddenQuotaSourceIDs: Binding<Set<AgentSourceID>>,
        pricingLastUpdatedAt: Date?,
        pricingUpdateError: String?,
        isUpdatingPricing: Bool,
        onUpdatePricing: @escaping () -> Void,
        loginItemRequiresApproval: Bool,
        loginItemError: String?,
        onOpenLoginItemSettings: @escaping () -> Void,
        currentVersion: String,
        canCheckForUpdates: Bool,
        onCheckForUpdates: @escaping () -> Void
    ) {
        self.configurableAgentSources = configurableAgentSources
        self._launchesAtLogin = launchesAtLogin
        self._menuBarMetricMode = menuBarMetricMode
        self._hiddenAgentSourceIDs = hiddenAgentSourceIDs
        self._enablesLimitMonitoring = enablesLimitMonitoring
        self._hiddenQuotaSourceIDs = hiddenQuotaSourceIDs
        self.pricingLastUpdatedAt = pricingLastUpdatedAt
        self.pricingUpdateError = pricingUpdateError
        self.isUpdatingPricing = isUpdatingPricing
        self.onUpdatePricing = onUpdatePricing
        self.loginItemRequiresApproval = loginItemRequiresApproval
        self.loginItemError = loginItemError
        self.onOpenLoginItemSettings = onOpenLoginItemSettings
        self.currentVersion = currentVersion
        self.canCheckForUpdates = canCheckForUpdates
        self.onCheckForUpdates = onCheckForUpdates
    }

    public var body: some View {
        Form {
            Section {
                Toggle(
                    UIStrings.text(zh: "登录时启动", en: "Launch at Login"),
                    isOn: $launchesAtLogin
                )

                if loginItemRequiresApproval || loginItemError != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loginItemMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button(
                            UIStrings.text(zh: "打开系统设置", en: "Open System Settings"),
                            action: onOpenLoginItemSettings
                        )
                    }
                }

                Toggle(
                    UIStrings.text(zh: "菜单栏显示用量", en: "Show usage in menu bar"),
                    isOn: Binding(
                        get: { menuBarMetricMode == .usage },
                        set: { menuBarMetricMode = $0 ? .usage : .hidden }
                    )
                )
            } header: {
                Text(UIStrings.text(zh: "通用", en: "General"))
            }

            Section {
                if configurableAgentSources.isEmpty {
                    Text(UIStrings.text(zh: "尚未发现本地 Agent", en: "No local agents discovered"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(configurableAgentSources) { descriptor in
                        Toggle(
                            isOn: visibilityBinding(
                                for: descriptor.id,
                                hiddenSourceIDs: $hiddenAgentSourceIDs
                            )
                        ) {
                            AgentSettingLabel(descriptor: descriptor)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            } header: {
                Text(UIStrings.text(zh: "数据来源", en: "Data Sources"))
            }

            Section {
                Toggle(
                    UIStrings.text(zh: "联网监控", en: "Online monitoring"),
                    isOn: $enablesLimitMonitoring
                )
                .toggleStyle(.switch)

                if enablesLimitMonitoring {
                    quotaToggle("Claude", sourceID: .claudeQuota)
                    quotaToggle("Codex", sourceID: .codexQuota)
                }
            } header: {
                Text(UIStrings.text(zh: "订阅额度", en: "Subscription Limits"))
            }

            Section(UIStrings.text(zh: "更新", en: "Updates")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VibeUsage")
                        Text(UIStrings.text(
                            zh: "版本 \(currentVersion)",
                            en: "Version \(currentVersion)"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(UIStrings.checkForUpdates, action: onCheckForUpdates)
                        .disabled(!canCheckForUpdates)
                        .frame(minWidth: 100, alignment: .trailing)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UIStrings.text(zh: "模型价格", en: "Model Prices"))
                        if let pricingLastUpdatedAt {
                            Text(UIStrings.updated(pricingLastUpdatedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(UIStrings.text(
                                zh: "正在使用应用内置价格。",
                                en: "Using prices bundled with the app."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(action: onUpdatePricing) {
                        if isUpdatingPricing {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(UIStrings.text(zh: "更新中", en: "Updating"))
                            }
                        } else {
                            Text(UIStrings.text(zh: "更新价格", en: "Update Prices"))
                        }
                    }
                    .disabled(isUpdatingPricing)
                    .frame(minWidth: 100, alignment: .trailing)
                }

                if let pricingUpdateError {
                    Text(pricingUpdateError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }

    private var loginItemMessage: String {
        if let loginItemError {
            return UIStrings.text(
                zh: "无法更新登录项：\(loginItemError)",
                en: "Could not update the login item: \(loginItemError)"
            )
        }
        return UIStrings.text(
            zh: "请在系统设置的“登录项与扩展”中允许 VibeUsage。",
            en: "Allow VibeUsage in Login Items & Extensions in System Settings."
        )
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
