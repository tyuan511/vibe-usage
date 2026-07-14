import AppKit
import SwiftUI
import VibeUsageAdapter
import VibeUsageAggregation
import VibeUsageCore
import VibeUsagePricing
import VibeUsageQuota
import VibeUsageStorage
import VibeUsageSync
import VibeUsageUI
import VibeUsageWatching

struct VibeUsageApp: App {
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var updateController = SparkleUpdateController()
    @StateObject private var loginItemController = LoginItemController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(viewModel: viewModel, updateController: updateController)
        } label: {
            MenuBarStatusLabel(metrics: viewModel.menuBarMetrics)
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let syncController = viewModel.syncController {
                SettingsContentView(
                    viewModel: viewModel,
                    syncController: syncController,
                    updateController: updateController,
                    loginItemController: loginItemController
                )
            } else {
                StartupFailureView(
                    message: viewModel.startupError ?? "Sync storage is unavailable.",
                    onQuit: { NSApp.terminate(nil) }
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                loginItemController.refresh()
            }
        }
    }
}

private struct SettingsContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var syncController: AppSyncController
    @ObservedObject var updateController: SparkleUpdateController
    @ObservedObject var loginItemController: LoginItemController

    var body: some View {
        VibeUsageSettingsView(
            configurableAgentSources: viewModel.configurableAgentSources,
            launchesAtLogin: Binding(
                get: { loginItemController.isEnabled },
                set: { loginItemController.setEnabled($0) }
            ),
            menuBarMetricMode: $viewModel.menuBarMetricMode,
            hiddenAgentSourceIDs: $viewModel.hiddenAgentSourceIDs,
            enablesLimitMonitoring: $viewModel.enablesLimitMonitoring,
            hiddenQuotaSourceIDs: $viewModel.hiddenQuotaSourceIDs,
            sync: Binding(
                get: { syncController.settingsPresentation },
                set: { syncController.apply($0) }
            ),
            syncActions: SyncSettingsActions(
                testAndSave: { await syncController.testAndSaveConfiguration() },
                syncNow: { syncController.syncNow() },
                deleteRemoteDevice: { syncController.deleteRemoteDevice($0) },
                removeConfiguration: { syncController.removeLocalConfiguration() }
            ),
            pricingLastUpdatedAt: viewModel.pricingLastUpdatedAt,
            pricingUpdateError: viewModel.pricingUpdateError,
            isUpdatingPricing: viewModel.isUpdatingPricing,
            onUpdatePricing: { viewModel.updatePricing() },
            loginItemRequiresApproval: loginItemController.requiresApproval,
            loginItemError: loginItemController.errorDescription,
            onOpenLoginItemSettings: { loginItemController.openSystemSettings() },
            currentVersion: updateController.currentVersion,
            canCheckForUpdates: updateController.canCheckForUpdates,
            onCheckForUpdates: { updateController.checkForUpdates() }
        )
    }
}

struct MenuBarStatusLabel: View {
    let metrics: MenuBarMetricValues?

    var body: some View {
        if let metrics {
            Image(nsImage: MenuBarStatusImageRenderer.image(for: metrics))
                .accessibilityLabel("\(metrics.spend), \(metrics.tokens)")
        } else {
            Image(systemName: "chart.bar.xaxis")
        }
    }
}

enum MenuBarStatusImageRenderer {
    @MainActor
    static func image(for metrics: MenuBarMetricValues) -> NSImage {
        let content = HStack(spacing: 5) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 13, weight: .medium))
            VStack(alignment: .trailing, spacing: 0) {
                Text(metrics.spend)
                Text(metrics.tokens)
            }
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
        }
        .foregroundStyle(.black)
        .fixedSize()

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct MenuContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var updateController: SparkleUpdateController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let startupError = viewModel.startupError {
            StartupFailureView(message: startupError, onQuit: { NSApp.terminate(nil) })
        } else {
            MenuBarUsageView(
                snapshot: viewModel.snapshot,
                isRefreshing: viewModel.isRefreshing,
                lastError: viewModel.lastError,
                quota: viewModel.enablesLimitMonitoring ? viewModel.quota : .empty,
                quotaConnectUIStates: viewModel.quotaConnectUIStates,
                selectedDateRange: $viewModel.selectedDateRange,
                selectedModelFilter: $viewModel.selectedModelFilter,
                hiddenQuotaSourceIDs: viewModel.hiddenQuotaSourceIDs,
                onRefresh: { viewModel.refresh(syncAfterScan: true) },
                onFilterChange: { viewModel.applyFilters() },
                onOpenSettings: {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                },
                onQuit: { NSApp.terminate(nil) },
                availableUpdateVersion: updateController.availableVersion,
                canCheckForUpdates: updateController.canCheckForUpdates,
                onCheckForUpdates: { updateController.checkForUpdates() },
                onQuotaConnect: { viewModel.connectQuota($0) },
                onQuotaDisconnect: { viewModel.disconnectQuota($0) },
                onQuotaCancelConnect: { viewModel.cancelQuotaConnect($0) }
            )
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var snapshot: UsageDashboardSnapshot
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var startupError: String?
    @Published var selectedDateRange: UsageDateRangePreset = .today
    @Published var selectedModelFilter: Set<String> = []
    @Published var configurableAgentSources: [AgentSourceDescriptor] = []
    @Published var hiddenAgentSourceIDs: Set<AgentSourceID> {
        didSet {
            Self.saveSourceIDs(hiddenAgentSourceIDs, key: Self.hiddenAgentSourceIDsKey)
            guard !isInitializing else { return }
            applyFilters()
            reloadMenuBarMetric()
        }
    }
    @Published var menuBarMetricMode: MenuBarMetricMode {
        didSet {
            UserDefaults.standard.set(menuBarMetricMode.rawValue, forKey: Self.menuBarMetricModeKey)
            guard !isInitializing else { return }
            reloadMenuBarMetric()
        }
    }
    @Published var menuBarMetrics: MenuBarMetricValues?
    @Published var quota: QuotaSnapshot = .empty
    @Published var quotaConnectUIStates: [AgentSourceID: QuotaConnectUIState] = [:]
    @Published var isUpdatingPricing = false
    @Published var pricingLastUpdatedAt: Date?
    @Published var pricingUpdateError: String?
    @Published var hiddenQuotaSourceIDs: Set<AgentSourceID> {
        didSet {
            Self.saveHiddenQuotaSourceIDs(hiddenQuotaSourceIDs)
        }
    }
    @Published var enablesLimitMonitoring: Bool {
        didSet {
            UserDefaults.standard.set(enablesLimitMonitoring, forKey: Self.enablesLimitMonitoringKey)
            guard !isInitializing else { return }
            refreshQuota()
        }
    }

    private let ingestor: UsageIngestor?
    private let eventStore: (any UsageEventStore)?
    private let pricing: CurrentPricingProvider?
    private let pricingSnapshotStore: PricingSnapshotStore
    private let pricingUpdateService: PricingUpdateService
    private let aggregation: UsageAggregationService?
    private let concreteEventStore: GRDBUsageEventStore?
    let syncController: AppSyncController?
    private let allSourceDescriptors: [AgentSourceDescriptor]
    private let quotaService: QuotaService
    private let quotaConnectionManager = QuotaConnectionManager()
    private var locallyDiscoveredSourceIDs = Set<AgentSourceID>()
    private var autoRefreshCoordinator: UsageAutoRefreshCoordinator?
    private var pendingRefresh = false
    private var pendingRefreshIncludesSync = false
    /// `nil` while idle; empty set means full scan; non-empty means filtered.
    private var pendingRefreshSourceFilter: Set<AgentSourceID>?
    /// `nil` while idle or unrestricted; non-nil restricts the pending scan to these paths.
    private var pendingRefreshChangedPaths: Set<String>?
    private var pendingPricingUpdate = false
    private var isPricingUpdateInProgress = false
    private var pricingUpdateReportsErrors = false
    private var quotaRefreshTimer: Timer?
    private var pricingRefreshTimer: Timer?
    private var isInitializing = true

    init() {
        let registry = AdapterRegistry()
        registry.register(ClaudeCodeAdapter())
        registry.register(CodexCLIAdapter())
        for adapter in AdditionalSourceAdapters.all {
            registry.register(adapter)
        }

        self.allSourceDescriptors = registry.descriptors
        self.hiddenAgentSourceIDs = Self.loadHiddenAgentSourceIDs()
        self.hiddenQuotaSourceIDs = Self.loadHiddenQuotaSourceIDs()
        self.menuBarMetricMode = Self.loadMenuBarMetricMode()
        self.enablesLimitMonitoring = Self.loadEnablesLimitMonitoring()
        self.snapshot = .empty()
        self.menuBarMetrics = nil
        let pricingSnapshotStore = PricingSnapshotStore()
        self.pricingSnapshotStore = pricingSnapshotStore
        self.pricingUpdateService = PricingUpdateService(store: pricingSnapshotStore)
        self.pricingLastUpdatedAt = pricingSnapshotStore.lastUpdatedAt

        let enablesLimitMonitoringKey = Self.enablesLimitMonitoringKey
        let capturedEnablesLimitMonitoring: @Sendable () -> Bool = {
            UserDefaults.standard.object(forKey: enablesLimitMonitoringKey) as? Bool ?? true
        }
        self.quotaService = QuotaService(
            connectionManager: quotaConnectionManager,
            isEnabled: capturedEnablesLimitMonitoring
        )

        do {
            let database = try UsageDatabase(path: UsageDatabase.defaultStorePath())
            let store = GRDBUsageEventStore(database: database)
            let pricing = CurrentPricingProvider(BundledPricingProvider())
            _ = try store.repriceEstimatedEvents(using: pricing)
            let syncController = try AppSyncController(usageStore: store)
            self.eventStore = store
            self.concreteEventStore = store
            self.pricing = pricing
            self.ingestor = UsageIngestor(registry: registry, store: store, pricing: pricing)
            self.aggregation = UsageAggregationService(store: store, registry: registry)
            self.syncController = syncController

            autoRefreshCoordinator = UsageAutoRefreshCoordinator(registry: registry) { [weak self] request in
                await self?.refresh(
                    sourceFilter: request.sourceFilter,
                    changedPaths: request.changedPaths
                )
            }
            autoRefreshCoordinator?.start()
        } catch {
            self.ingestor = nil
            self.aggregation = nil
            self.concreteEventStore = nil
            self.eventStore = nil
            self.syncController = nil
            self.pricing = nil
            self.startupError = error.localizedDescription
        }

        refreshQuota()
        startQuotaRefreshTimer()
        isInitializing = false
        syncController?.onDataChanged = { [weak self] in
            self?.applySyncedData()
        }
        syncController?.syncNow()
        startPricingRefreshTimer()
        refreshPricingSilentlyIfNeeded()
    }

    deinit {
        autoRefreshCoordinator?.stop()
        quotaRefreshTimer?.invalidate()
        pricingRefreshTimer?.invalidate()
    }

    /// Refreshes quota state independently of the local-cost scan pipeline —
    /// not tied to FSEvents/ingestor churn, just called on launch, popover
    /// open, manual refresh, and the timer below.
    func refreshQuota() {
        Task { [quotaService] in
            let next = await quotaService.snapshot()
            await MainActor.run {
                quota = next
            }
        }
    }

    /// Connects a quota source. Codex runs the loopback browser OAuth flow
    /// (spinner shown meanwhile); Claude imports Claude Code's existing token
    /// and either succeeds immediately or fails with "sign in to Claude Code
    /// first". Both surface failures inline via `quotaConnectUIStates`.
    func connectQuota(_ provider: AgentSourceID) {
        if provider == .codexQuota {
            quotaConnectUIStates[provider] = .waitingForBrowser
        }
        Task { [quotaConnectionManager] in
            do {
                try await quotaConnectionManager.connect(provider)
                await MainActor.run {
                    quotaConnectUIStates[provider] = nil
                    refreshQuota()
                }
            } catch {
                await MainActor.run {
                    quotaConnectUIStates[provider] = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Dismisses an inline connect error (user tapped "取消/Cancel").
    func cancelQuotaConnect(_ provider: AgentSourceID) {
        quotaConnectUIStates[provider] = nil
    }

    func disconnectQuota(_ provider: AgentSourceID) {
        quotaConnectionManager.disconnect(provider)
        quotaConnectUIStates[provider] = nil
        refreshQuota()
    }

    /// Simple ~5-minute cadence; deliberately not adaptive/backing-off beyond
    /// "the timer interval is generous enough not to hammer a failing
    /// endpoint" per the v1 scope.
    private func startQuotaRefreshTimer() {
        quotaRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshQuota()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        quotaRefreshTimer = timer
    }

    /// Checks hourly so a snapshot that was nearly one day old on launch does
    /// not wait another full day. Network activity still occurs at most daily.
    private func startPricingRefreshTimer() {
        pricingRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPricingSilentlyIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pricingRefreshTimer = timer
    }

    func refresh(
        syncAfterScan: Bool = false,
        sourceFilter: Set<AgentSourceID> = [],
        changedPaths: Set<String>? = nil
    ) {
        refreshQuota()
        guard ingestor != nil else { return }
        guard !isPricingUpdateInProgress else {
            enqueuePendingRefresh(
                syncAfterScan: syncAfterScan,
                sourceFilter: sourceFilter,
                changedPaths: changedPaths
            )
            return
        }
        guard !isRefreshing else {
            enqueuePendingRefresh(
                syncAfterScan: syncAfterScan,
                sourceFilter: sourceFilter,
                changedPaths: changedPaths
            )
            return
        }
        performRefresh(
            syncAfterScan: syncAfterScan,
            sourceFilter: sourceFilter,
            changedPaths: changedPaths
        )
    }

    private func performRefresh(
        syncAfterScan: Bool = false,
        sourceFilter: Set<AgentSourceID> = [],
        changedPaths: Set<String>? = nil
    ) {
        guard let ingestor, let aggregation else { return }
        guard !isPricingUpdateInProgress else {
            enqueuePendingRefresh(
                syncAfterScan: syncAfterScan,
                sourceFilter: sourceFilter,
                changedPaths: changedPaths
            )
            return
        }
        guard !isRefreshing else {
            enqueuePendingRefresh(
                syncAfterScan: syncAfterScan,
                sourceFilter: sourceFilter,
                changedPaths: changedPaths
            )
            return
        }
        isRefreshing = true
        lastError = nil

        Task {
            do {
                let summary = try await ingestor.scanOnce(
                    sourceFilter: sourceFilter,
                    changedPaths: changedPaths
                )
                var syncError: String?
                if syncAfterScan {
                    do {
                        _ = try await syncController?.synchronizeIfEnabled()
                    } catch {
                        syncError = error.localizedDescription
                    }
                }
                let discoveredSourceIDs = summary.discoveredSourceIDs.union(
                    (try? concreteEventStore?.knownUsageSourceIDs()) ?? []
                ).union(locallyDiscoveredSourceIDs)
                let configurableSources = Self.descriptors(
                    from: allSourceDescriptors,
                    matching: discoveredSourceIDs
                )
                let shouldReaggregate = summary.insertedEvents > 0 || syncAfterScan
                let next: UsageDashboardSnapshot?
                if shouldReaggregate {
                    let visibleSourceIDs = Self.visibleSourceIDs(
                        discovered: discoveredSourceIDs,
                        hidden: hiddenAgentSourceIDs
                    )
                    next = try aggregation.dashboardSnapshot(
                        visibleSourceFilter: visibleSourceIDs,
                        visibleDeviceFilter: syncController?.visibleDeviceIDs,
                        modelFilter: selectedModelFilter,
                        dateRange: selectedDateRange
                    )
                } else {
                    next = nil
                }
                await MainActor.run {
                    locallyDiscoveredSourceIDs = discoveredSourceIDs
                    configurableAgentSources = configurableSources
                    if let next {
                        snapshot = next
                        reloadMenuBarMetric()
                    }
                    lastError = syncError
                    finishRefreshCycle()
                }
            } catch {
                await MainActor.run {
                    lastError = error.localizedDescription
                    finishRefreshCycle()
                }
            }
        }
    }

    private func enqueuePendingRefresh(
        syncAfterScan: Bool,
        sourceFilter: Set<AgentSourceID>,
        changedPaths: Set<String>?
    ) {
        let wasPending = pendingRefresh
        pendingRefresh = true
        pendingRefreshIncludesSync = pendingRefreshIncludesSync || syncAfterScan

        if let existing = pendingRefreshSourceFilter {
            if existing.isEmpty || sourceFilter.isEmpty {
                pendingRefreshSourceFilter = []
            } else {
                pendingRefreshSourceFilter = existing.union(sourceFilter)
            }
        } else {
            pendingRefreshSourceFilter = sourceFilter
        }

        // nil changedPaths means unrestricted file scan. Once unrestricted, stay unrestricted.
        if changedPaths == nil || pendingRefreshSourceFilter?.isEmpty == true {
            pendingRefreshChangedPaths = nil
        } else if let changedPaths {
            if !wasPending {
                pendingRefreshChangedPaths = changedPaths
            } else if let existing = pendingRefreshChangedPaths {
                pendingRefreshChangedPaths = existing.union(changedPaths)
            } else {
                // Already pending as an unrestricted scan.
                pendingRefreshChangedPaths = nil
            }
        }
    }

    private func finishRefreshCycle() {
        isRefreshing = false
        if pendingPricingUpdate {
            pendingPricingUpdate = false
            performPricingUpdate()
            return
        }
        if pendingRefresh {
            pendingRefresh = false
            let includesSync = pendingRefreshIncludesSync
            pendingRefreshIncludesSync = false
            let sourceFilter = pendingRefreshSourceFilter ?? []
            pendingRefreshSourceFilter = nil
            let changedPaths = pendingRefreshChangedPaths
            pendingRefreshChangedPaths = nil
            performRefresh(
                syncAfterScan: includesSync,
                sourceFilter: sourceFilter,
                changedPaths: changedPaths
            )
        }
    }

    func updatePricing() {
        requestPricingUpdate(reportingProgress: true)
    }

    private func refreshPricingSilentlyIfNeeded() {
        let now = Date()
        let lastAttempt = UserDefaults.standard.object(
            forKey: Self.lastAutomaticPricingRefreshAttemptKey
        ) as? Date
        guard pricingSnapshotStore.shouldAttemptAutomaticRefresh(
            lastAttemptAt: lastAttempt,
            at: now
        ) else { return }
        UserDefaults.standard.set(now, forKey: Self.lastAutomaticPricingRefreshAttemptKey)
        requestPricingUpdate(reportingProgress: false)
    }

    private func requestPricingUpdate(reportingProgress: Bool) {
        if isPricingUpdateInProgress {
            if reportingProgress {
                isUpdatingPricing = true
                pricingUpdateReportsErrors = true
                pricingUpdateError = nil
            }
            return
        }

        isPricingUpdateInProgress = true
        isUpdatingPricing = reportingProgress
        pricingUpdateReportsErrors = reportingProgress
        if reportingProgress {
            pricingUpdateError = nil
        }

        if isRefreshing {
            pendingPricingUpdate = true
            return
        }
        performPricingUpdate()
    }

    private func performPricingUpdate() {
        guard let eventStore, let pricing else {
            let reportsErrors = pricingUpdateReportsErrors
            isPricingUpdateInProgress = false
            isUpdatingPricing = false
            pricingUpdateReportsErrors = false
            if reportsErrors {
                pricingUpdateError = VibeUsageStrings.text(
                    zh: "价格更新不可用：本地数据库尚未准备好。",
                    en: "Price updates are unavailable because the local database is not ready."
                )
            }
            return
        }

        Task.detached { [weak self, pricingUpdateService, pricingSnapshotStore, pricing, eventStore] in
            do {
                let result = try await pricingUpdateService.update()
                let updatedPricing = BundledPricingProvider(
                    localSnapshotURL: pricingSnapshotStore.snapshotURL
                )
                pricing.replace(with: updatedPricing)
                _ = try eventStore.repriceEstimatedEvents(using: pricing)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    pricingLastUpdatedAt = result.updatedAt
                    pricingUpdateError = nil
                    applyFilters()
                    reloadMenuBarMetric()
                    finishPricingUpdate()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if pricingUpdateReportsErrors {
                        pricingUpdateError = error.localizedDescription
                    }
                    finishPricingUpdate()
                }
            }
        }
    }

    private func finishPricingUpdate() {
        isPricingUpdateInProgress = false
        isUpdatingPricing = false
        pricingUpdateReportsErrors = false
        if pendingRefresh {
            pendingRefresh = false
            performRefresh()
        }
    }

    func applyFilters() {
        guard let aggregation else { return }
        do {
            snapshot = try aggregation.dashboardSnapshot(
                visibleSourceFilter: Self.visibleSourceIDs(
                    discovered: locallyDiscoveredSourceIDs,
                    hidden: hiddenAgentSourceIDs
                ),
                visibleDeviceFilter: syncController?.visibleDeviceIDs,
                modelFilter: selectedModelFilter,
                dateRange: selectedDateRange
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func reloadMenuBarMetric() {
        guard menuBarMetricMode != .hidden else {
            menuBarMetrics = nil
            return
        }
        guard let aggregation else { return }
        do {
            let todaySnapshot = try aggregation.dashboardSnapshot(
                visibleSourceFilter: Self.visibleSourceIDs(
                    discovered: locallyDiscoveredSourceIDs,
                    hidden: hiddenAgentSourceIDs
                ),
                visibleDeviceFilter: syncController?.visibleDeviceIDs,
                dateRange: .today
            )
            menuBarMetrics = MenuBarMetricFormatter.values(
                for: menuBarMetricMode,
                totals: todaySnapshot.totals
            )
        } catch {
            menuBarMetrics = MenuBarMetricFormatter.values(
                for: menuBarMetricMode,
                totals: UsageTotals()
            )
        }
    }

    private static func visibleSourceIDs(
        discovered: Set<AgentSourceID>,
        hidden: Set<AgentSourceID>
    ) -> Set<AgentSourceID> {
        discovered.subtracting(hidden)
    }

    private static func descriptors(
        from descriptors: [AgentSourceDescriptor],
        matching ids: Set<AgentSourceID>
    ) -> [AgentSourceDescriptor] {
        descriptors.filter { ids.contains($0.id) }
    }

    private func applySyncedData() {
        guard !isRefreshing else { return }
        if let known = try? concreteEventStore?.knownUsageSourceIDs() {
            locallyDiscoveredSourceIDs.formUnion(known)
            configurableAgentSources = Self.descriptors(
                from: allSourceDescriptors,
                matching: locallyDiscoveredSourceIDs
            )
        }
        applyFilters()
        reloadMenuBarMetric()
    }

    private static let hiddenAgentSourceIDsKey = "hiddenAgentSourceIDs"
    private static let hiddenQuotaSourceIDsKey = "hiddenQuotaSourceIDs"
    private static let menuBarMetricModeKey = "menuBarMetricMode"
    private static let showsSpendInMenuBarKey = "showsSpendInMenuBar"
    private static let enablesLimitMonitoringKey = "enablesLimitMonitoring"
    private static let lastAutomaticPricingRefreshAttemptKey = "lastAutomaticPricingRefreshAttempt"

    private static func loadHiddenAgentSourceIDs() -> Set<AgentSourceID> {
        loadSourceIDs(key: hiddenAgentSourceIDsKey)
    }

    private static func loadMenuBarMetricMode() -> MenuBarMetricMode {
        MenuBarMetricMode.resolve(
            storedRawValue: UserDefaults.standard.string(forKey: menuBarMetricModeKey),
            legacyShowsSpend: UserDefaults.standard.object(forKey: showsSpendInMenuBarKey) as? Bool
        )
    }

    private static func loadHiddenQuotaSourceIDs() -> Set<AgentSourceID> {
        loadSourceIDs(key: hiddenQuotaSourceIDsKey)
    }

    private static func loadEnablesLimitMonitoring() -> Bool {
        UserDefaults.standard.object(forKey: enablesLimitMonitoringKey) as? Bool ?? true
    }

    private static func saveHiddenQuotaSourceIDs(_ ids: Set<AgentSourceID>) {
        saveSourceIDs(ids, key: hiddenQuotaSourceIDsKey)
    }

    private static func loadSourceIDs(key: String) -> Set<AgentSourceID> {
        let rawValues = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(rawValues.map { AgentSourceID(rawValue: $0) })
    }

    private static func saveSourceIDs(_ ids: Set<AgentSourceID>, key: String) {
        UserDefaults.standard.set(ids.map(\.rawValue).sorted(), forKey: key)
    }
}

VibeUsageApp.main()
