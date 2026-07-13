import SwiftUI
import VibeUsageCore

public struct VibeUsageSettingsView: View {
    let configurableAgentSources: [AgentSourceDescriptor]
    @Binding var launchesAtLogin: Bool
    @Binding var menuBarMetricMode: MenuBarMetricMode
    @Binding var hiddenAgentSourceIDs: Set<AgentSourceID>
    @Binding var enablesLimitMonitoring: Bool
    @Binding var hiddenQuotaSourceIDs: Set<AgentSourceID>
    @Binding var sync: SyncSettingsPresentation
    let syncActions: SyncSettingsActions
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
    @State private var showsSyncConfiguration = false
    @State private var confirmsTargetSwitch = false
    @State private var confirmsRemoveSyncConfiguration = false
    @State private var pendingDeviceDeletion: SyncSettingsPresentation.Device?

    public init(
        configurableAgentSources: [AgentSourceDescriptor],
        launchesAtLogin: Binding<Bool>,
        menuBarMetricMode: Binding<MenuBarMetricMode>,
        hiddenAgentSourceIDs: Binding<Set<AgentSourceID>>,
        enablesLimitMonitoring: Binding<Bool>,
        hiddenQuotaSourceIDs: Binding<Set<AgentSourceID>>,
        sync: Binding<SyncSettingsPresentation>,
        syncActions: SyncSettingsActions,
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
        self._sync = sync
        self.syncActions = syncActions
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

            syncSection

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
        .frame(width: 540, height: 720)
        .sheet(isPresented: $showsSyncConfiguration) {
            SyncConfigurationView(
                draft: $sync.form,
                isTesting: sync.isTestingConnection,
                error: sync.error,
                onSave: requestSyncConfigurationSave
            )
        }
        .confirmationDialog(
            UIStrings.text(zh: "切换同步目标？", en: "Switch sync target?"),
            isPresented: $confirmsTargetSwitch
        ) {
            Button(UIStrings.text(zh: "测试并切换", en: "Test and Switch")) {
                saveSyncConfiguration()
            }
            Button(UIStrings.text(zh: "取消", en: "Cancel"), role: .cancel) {}
        } message: {
            Text(UIStrings.text(
                zh: "旧数据不会自动迁移，其他设备也需要改为相同配置并重新发布。",
                en: "Existing data is not migrated. Other devices must use the same target and publish again."
            ))
        }
        .confirmationDialog(
            UIStrings.text(zh: "移除同步配置？", en: "Remove sync configuration?"),
            isPresented: $confirmsRemoveSyncConfiguration
        ) {
            Button(UIStrings.text(zh: "移除配置与缓存", en: "Remove Configuration and Cache"), role: .destructive) {
                syncActions.removeConfiguration()
            }
            Button(UIStrings.text(zh: "取消", en: "Cancel"), role: .cancel) {}
        } message: {
            Text(UIStrings.text(
                zh: "只清除这台 Mac 的配置、凭据和远端缓存，不删除服务器文件。",
                en: "This clears configuration, credentials, and remote cache on this Mac without deleting server files."
            ))
        }
        .confirmationDialog(
            UIStrings.text(zh: "删除设备远端历史？", en: "Delete remote device history?"),
            isPresented: Binding(
                get: { pendingDeviceDeletion != nil },
                set: { if !$0 { pendingDeviceDeletion = nil } }
            ),
            presenting: pendingDeviceDeletion
        ) { device in
            Button(UIStrings.text(zh: "删除 \(device.name)", en: "Delete \(device.name)"), role: .destructive) {
                syncActions.deleteRemoteDevice(device.id)
                pendingDeviceDeletion = nil
            }
            Button(UIStrings.text(zh: "取消", en: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text(UIStrings.text(
                zh: "该设备再次上线时可以重新发布并恢复显示。",
                en: "The device can publish again and reappear when it comes online."
            ))
        }
    }

    private var syncSection: some View {
        Section {
            Toggle(UIStrings.text(zh: "启用同步", en: "Enable Sync"), isOn: $sync.isEnabled)
                .toggleStyle(.switch)
                .disabled(!sync.hasConfiguration)

            LabeledContent(UIStrings.text(zh: "当前设备", en: "This Device")) {
                TextField("", text: $sync.deviceName)
                    .accessibilityLabel(UIStrings.text(zh: "设备名称", en: "Device Name"))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 220)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sync.configuredBackendName ?? UIStrings.text(zh: "未配置", en: "Not Configured"))
                    if let summary = sync.configurationSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Button {
                    showsSyncConfiguration = true
                } label: {
                    Label(UIStrings.text(zh: "配置", en: "Configure"), systemImage: "externaldrive.badge.wifi")
                }
            }

            if sync.hasConfiguration {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(syncStatusTitle)
                        if let lastSuccessfulAt = sync.lastSuccessfulAt {
                            Text(UIStrings.updated(lastSuccessfulAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(action: syncActions.syncNow) {
                        if sync.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(UIStrings.text(zh: "立即同步", en: "Sync Now"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(!sync.isEnabled || sync.isSyncing)
                }
            }

            if !sync.devices.isEmpty {
                ForEach(sync.devices) { device in
                    HStack(spacing: 8) {
                        if device.isLocal {
                            Image(systemName: "checkmark.square.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            syncDeviceLabel(device)
                        } else {
                            Toggle(isOn: syncDeviceVisibilityBinding(device.id)) {
                                syncDeviceLabel(device)
                            }
                            .toggleStyle(.checkbox)
                        }
                        if device.isLocal {
                            Spacer()
                            Text(UIStrings.text(zh: "此 Mac", en: "This Mac"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button {
                                pendingDeviceDeletion = device
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(UIStrings.text(zh: "删除远端历史", en: "Delete Remote History"))
                        }
                    }
                }
            }

            if let error = sync.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if sync.hasConfiguration {
                Button(role: .destructive) {
                    confirmsRemoveSyncConfiguration = true
                } label: {
                    Label(UIStrings.text(zh: "移除配置与缓存", en: "Remove Configuration and Cache"), systemImage: "xmark.circle")
                }
            }
        } header: {
            Text(UIStrings.text(zh: "多端同步", en: "Multi-Device Sync"))
        }
    }

    @ViewBuilder
    private func syncDeviceLabel(_ device: SyncSettingsPresentation.Device) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(device.name)
            if let lastSyncedAt = device.lastSyncedAt {
                Text(UIStrings.updated(lastSyncedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var syncStatusTitle: String {
        if sync.isSyncing { return UIStrings.text(zh: "同步中", en: "Syncing") }
        return UIStrings.text(zh: "同步状态", en: "Sync Status")
    }

    private func requestSyncConfigurationSave() {
        if let configuredTargetIdentity = sync.configuredTargetIdentity,
           configuredTargetIdentity != sync.form.targetIdentity {
            confirmsTargetSwitch = true
        } else {
            saveSyncConfiguration()
        }
    }

    private func saveSyncConfiguration() {
        Task {
            if await syncActions.testAndSave() {
                showsSyncConfiguration = false
            }
        }
    }

    private func syncDeviceVisibilityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !sync.hiddenDeviceIDs.contains(id) },
            set: { visible in
                if visible { sync.hiddenDeviceIDs.remove(id) }
                else { sync.hiddenDeviceIDs.insert(id) }
            }
        )
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
