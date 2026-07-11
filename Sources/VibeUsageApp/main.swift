import AppKit
import SwiftUI
import VibeUsageAdapter
import VibeUsageAggregation
import VibeUsageCore
import VibeUsagePricing
import VibeUsageQuota
import VibeUsageStorage
import VibeUsageUI
import VibeUsageWatching

struct VibeUsageApp: App {
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var updateController = SparkleUpdateController()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(viewModel: viewModel, updateController: updateController)
        } label: {
            if let menuBarMetricText = viewModel.menuBarMetricText {
                Label(menuBarMetricText, systemImage: "chart.bar.xaxis")
            } else {
                Image(systemName: "chart.bar.xaxis")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            VibeUsageSettingsView(
                configurableAgentSources: viewModel.configurableAgentSources,
                menuBarMetricMode: $viewModel.menuBarMetricMode,
                hiddenMenuBarMetricSourceIDs: $viewModel.hiddenMenuBarMetricSourceIDs,
                hiddenDropdownSourceIDs: $viewModel.hiddenAgentSourceIDs,
                enablesLimitMonitoring: $viewModel.enablesLimitMonitoring,
                hiddenQuotaSourceIDs: $viewModel.hiddenQuotaSourceIDs,
                canCheckForUpdates: updateController.canCheckForUpdates,
                onCheckForUpdates: { updateController.checkForUpdates() }
            )
        }
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
                shareSnapshot: viewModel.shareSnapshot,
                isRefreshing: viewModel.isRefreshing,
                lastError: viewModel.lastError,
                quota: viewModel.enablesLimitMonitoring ? viewModel.quota : .empty,
                quotaConnectUIStates: viewModel.quotaConnectUIStates,
                selectedDateRange: $viewModel.selectedDateRange,
                selectedModelFilter: $viewModel.selectedModelFilter,
                hiddenQuotaSourceIDs: viewModel.hiddenQuotaSourceIDs,
                onRefresh: { viewModel.refresh() },
                onFilterChange: { viewModel.applyFilters() },
                onOpenSettings: {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                },
                onQuit: { NSApp.terminate(nil) },
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
        }
    }
    @Published var menuBarMetricMode: MenuBarMetricMode {
        didSet {
            UserDefaults.standard.set(menuBarMetricMode.rawValue, forKey: Self.menuBarMetricModeKey)
            guard !isInitializing else { return }
            reloadMenuBarMetric()
        }
    }
    @Published var hiddenMenuBarMetricSourceIDs: Set<AgentSourceID> {
        didSet {
            Self.saveSourceIDs(hiddenMenuBarMetricSourceIDs, key: Self.hiddenMenuBarMetricSourceIDsKey)
            guard !isInitializing else { return }
            reloadMenuBarMetric()
        }
    }
    @Published var menuBarMetricText: String?
    @Published var shareSnapshot: UsageInsightsSnapshot
    @Published var quota: QuotaSnapshot = .empty
    @Published var quotaConnectUIStates: [AgentSourceID: QuotaConnectUIState] = [:]
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
    private let aggregation: UsageAggregationService?
    private let allSourceDescriptors: [AgentSourceDescriptor]
    private let quotaService: QuotaService
    private let quotaConnectionManager = QuotaConnectionManager()
    private var locallyDiscoveredSourceIDs = Set<AgentSourceID>()
    private var autoRefreshCoordinator: UsageAutoRefreshCoordinator?
    private var pendingRefresh = false
    private var quotaRefreshTimer: Timer?
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
        self.hiddenMenuBarMetricSourceIDs = Self.loadSourceIDs(key: Self.hiddenMenuBarMetricSourceIDsKey)
        self.hiddenQuotaSourceIDs = Self.loadHiddenQuotaSourceIDs()
        self.menuBarMetricMode = Self.loadMenuBarMetricMode()
        self.enablesLimitMonitoring = Self.loadEnablesLimitMonitoring()
        self.snapshot = .empty()
        self.shareSnapshot = .empty()
        self.menuBarMetricText = nil

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
            let pricing = BundledPricingProvider()
            _ = try store.repriceEstimatedEvents(using: pricing)
            self.ingestor = UsageIngestor(registry: registry, store: store, pricing: pricing)
            self.aggregation = UsageAggregationService(store: store, registry: registry)

            autoRefreshCoordinator = UsageAutoRefreshCoordinator(registry: registry) { [weak self] in
                await self?.performRefresh()
            }
            autoRefreshCoordinator?.start()
        } catch {
            self.ingestor = nil
            self.aggregation = nil
            self.startupError = error.localizedDescription
        }

        refreshQuota()
        startQuotaRefreshTimer()
        isInitializing = false
    }

    deinit {
        autoRefreshCoordinator?.stop()
        quotaRefreshTimer?.invalidate()
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

    func refresh() {
        refreshQuota()
        guard ingestor != nil else { return }
        guard !isRefreshing else {
            pendingRefresh = true
            return
        }
        performRefresh()
    }

    private func performRefresh() {
        guard let ingestor, let aggregation else { return }
        isRefreshing = true
        lastError = nil

        Task {
            do {
                let summary = try await ingestor.scanOnce()
                let configurableSources = Self.descriptors(
                    from: allSourceDescriptors,
                    matching: summary.discoveredSourceIDs
                )
                let visibleSourceIDs = Self.visibleSourceIDs(
                    discovered: summary.discoveredSourceIDs,
                    hidden: hiddenAgentSourceIDs
                )
                let next = try aggregation.dashboardSnapshot(
                    visibleSourceFilter: visibleSourceIDs,
                    modelFilter: selectedModelFilter,
                    dateRange: selectedDateRange
                )
                await MainActor.run {
                    locallyDiscoveredSourceIDs = summary.discoveredSourceIDs
                    configurableAgentSources = configurableSources
                    snapshot = next
                    reloadShareSnapshot()
                    reloadMenuBarMetric()
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

    private func finishRefreshCycle() {
        isRefreshing = false
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
                modelFilter: selectedModelFilter,
                dateRange: selectedDateRange
            )
            lastError = nil
            reloadShareSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func reloadShareSnapshot() {
        guard let aggregation else { return }
        do {
            shareSnapshot = try aggregation.insightsSnapshot(
                visibleSourceFilter: Self.visibleSourceIDs(
                    discovered: locallyDiscoveredSourceIDs,
                    hidden: hiddenAgentSourceIDs
                ),
                modelFilter: selectedModelFilter,
                dateRange: selectedDateRange
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func reloadMenuBarMetric() {
        guard menuBarMetricMode != .hidden else {
            menuBarMetricText = nil
            return
        }
        guard let aggregation else { return }
        do {
            let todaySnapshot = try aggregation.dashboardSnapshot(
                visibleSourceFilter: Self.visibleSourceIDs(
                    discovered: locallyDiscoveredSourceIDs,
                    hidden: hiddenMenuBarMetricSourceIDs
                ),
                dateRange: .today
            )
            menuBarMetricText = MenuBarMetricFormatter.text(
                for: menuBarMetricMode,
                totals: todaySnapshot.totals
            )
        } catch {
            menuBarMetricText = MenuBarMetricFormatter.text(
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

    private static let hiddenAgentSourceIDsKey = "hiddenAgentSourceIDs"
    private static let hiddenMenuBarMetricSourceIDsKey = "hiddenMenuBarMetricSourceIDs"
    private static let hiddenQuotaSourceIDsKey = "hiddenQuotaSourceIDs"
    private static let menuBarMetricModeKey = "menuBarMetricMode"
    private static let showsSpendInMenuBarKey = "showsSpendInMenuBar"
    private static let enablesLimitMonitoringKey = "enablesLimitMonitoring"

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
