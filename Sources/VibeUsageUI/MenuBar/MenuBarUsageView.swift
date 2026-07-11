import AppKit
import SwiftUI
import VibeUsageAggregation
import VibeUsageCore
import VibeUsageQuota

public struct MenuBarUsageView: View {
    let snapshot: UsageDashboardSnapshot
    let isRefreshing: Bool
    let lastError: String?
    let quota: QuotaSnapshot
    let quotaConnectUIStates: [AgentSourceID: QuotaConnectUIState]
    @Binding var selectedDateRange: UsageDateRangePreset
    @Binding var selectedModelFilter: Set<String>
    let hiddenQuotaSourceIDs: Set<AgentSourceID>
    let onRefresh: () -> Void
    let onFilterChange: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    let availableUpdateVersion: String?
    let canCheckForUpdates: Bool
    let onCheckForUpdates: () -> Void
    let onQuotaConnect: (AgentSourceID) -> Void
    let onQuotaDisconnect: (AgentSourceID) -> Void
    let onQuotaCancelConnect: (AgentSourceID) -> Void
    @State private var shareAnchorView: NSView?

    public init(
        snapshot: UsageDashboardSnapshot,
        isRefreshing: Bool,
        lastError: String?,
        quota: QuotaSnapshot,
        quotaConnectUIStates: [AgentSourceID: QuotaConnectUIState] = [:],
        selectedDateRange: Binding<UsageDateRangePreset>,
        selectedModelFilter: Binding<Set<String>>,
        hiddenQuotaSourceIDs: Set<AgentSourceID>,
        onRefresh: @escaping () -> Void,
        onFilterChange: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        availableUpdateVersion: String? = nil,
        canCheckForUpdates: Bool = false,
        onCheckForUpdates: @escaping () -> Void = {},
        onQuotaConnect: @escaping (AgentSourceID) -> Void = { _ in },
        onQuotaDisconnect: @escaping (AgentSourceID) -> Void = { _ in },
        onQuotaCancelConnect: @escaping (AgentSourceID) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        self.lastError = lastError
        self.quota = quota
        self.quotaConnectUIStates = quotaConnectUIStates
        self._selectedDateRange = selectedDateRange
        self._selectedModelFilter = selectedModelFilter
        self.hiddenQuotaSourceIDs = hiddenQuotaSourceIDs
        self.onRefresh = onRefresh
        self.onFilterChange = onFilterChange
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.availableUpdateVersion = availableUpdateVersion
        self.canCheckForUpdates = canCheckForUpdates
        self.onCheckForUpdates = onCheckForUpdates
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

            if !snapshot.sources.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    MenuSectionTitle(UIStrings.agents)
                    agentsList
                }
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

                    shareMenu
                        .background(ShareAnchorCapture(anchorView: $shareAnchorView))

                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
                    .help(UIStrings.text(zh: "设置", en: "Settings"))

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
                }
            }
        }
    }

    private var shareMenu: some View {
        Menu {
            Button(UIStrings.text(zh: "保存图片…", en: "Save Image…"), action: saveImage)
            Button(UIStrings.text(zh: "拷贝图片", en: "Copy Image"), action: copyImage)
            Button(UIStrings.text(zh: "分享…", en: "Share…"), action: shareImage)
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

    private func exportPNGData() async -> Data? {
        guard let window = shareAnchorView?.window ?? NSApp.keyWindow else { return nil }
        return await MenuBarImageExporter.renderPNGData(window: window)
    }

    private func saveImage() {
        Task {
            guard let data = await exportPNGData() else { return }
            imageSaveAction.run(
                data: data,
                defaultFilename: "VibeUsage-\(snapshot.rangeEndDay).png"
            )
        }
    }

    private var imageSaveAction: MenuBarImageSaveAction {
        MenuBarImageSaveAction(
            activateApplication: { NSApp.activate(ignoringOtherApps: true) },
            presentSavePanel: { defaultFilename, completion in
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = defaultFilename
                panel.begin { response in
                    completion(response == .OK ? panel.url : nil)
                }
            },
            writeData: { data, url in try data.write(to: url) }
        )
    }

    private func copyImage() {
        Task {
            guard let data = await exportPNGData() else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            if let image = NSImage(data: data), let tiffData = image.tiffRepresentation {
                pasteboard.setData(tiffData, forType: .tiff)
            }
        }
    }

    private func shareImage() {
        Task {
            guard let data = await exportPNGData(), let image = NSImage(data: data) else { return }
            let picker = NSSharingServicePicker(items: [image])
            if let anchorView = shareAnchorView {
                picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
            } else if let contentView = NSApp.keyWindow?.contentView {
                let topRight = NSRect(
                    x: contentView.bounds.maxX - 1,
                    y: contentView.bounds.maxY - 1,
                    width: 1,
                    height: 1
                )
                picker.show(relativeTo: topRight, of: contentView, preferredEdge: .minY)
            }
        }
    }

    private var descriptorsByID: [AgentSourceID: AgentSourceDescriptor] {
        Dictionary(uniqueKeysWithValues: snapshot.discoveredSources.map { ($0.id, $0) })
    }

    private var visibleQuotaSources: [QuotaSourceSnapshot] {
        QuotaDisplayFilter.visibleSources(
            from: quota.sources,
            hiddenSourceIDs: hiddenQuotaSourceIDs
        )
    }

    @ViewBuilder
    private var quotaSection: some View {
        if !visibleQuotaSources.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                MenuSectionTitle(QuotaUIStrings.sectionTitle)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(visibleQuotaSources.enumerated()), id: \.element.id) { index, source in
                        QuotaSourceRow(
                            snapshot: source,
                            descriptor: descriptorsByID[source.sourceID],
                            connectUIState: quotaConnectUIStates[source.sourceID],
                            onConnect: onQuotaConnect,
                            onDisconnect: onQuotaDisconnect,
                            onCancelConnect: onQuotaCancelConnect
                        )
                        if index < visibleQuotaSources.count - 1 {
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

    private var agentsList: some View {
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

            Divider()
            HStack(spacing: 10) {
                Button(action: onCheckForUpdates) {
                    Label(updateButtonTitle, systemImage: updateButtonSystemImage)
                        .foregroundStyle(availableUpdateVersion == nil ? Color.primary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .disabled(!canCheckForUpdates)

                Spacer(minLength: 8)

                Button(action: onQuit) {
                    Label(
                        UIStrings.text(zh: "退出", en: "Quit"),
                        systemImage: "power"
                    )
                }
                .buttonStyle(.plain)
                .controlSize(.small)
            }
        }
    }

    private var updateButtonTitle: String {
        guard let availableUpdateVersion else { return UIStrings.checkForUpdates }
        return UIStrings.text(
            zh: "发现新版本 \(availableUpdateVersion)",
            en: "Update \(availableUpdateVersion) Available"
        )
    }

    private var updateButtonSystemImage: String {
        availableUpdateVersion == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill"
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
}

private struct ShareAnchorCapture: NSViewRepresentable {
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { anchorView = view.superview ?? view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if anchorView == nil {
            DispatchQueue.main.async { anchorView = nsView.superview ?? nsView }
        }
    }
}
