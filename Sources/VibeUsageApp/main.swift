import AppKit
import SwiftUI
import VibeUsageAdapter
import VibeUsageAggregation
import VibeUsageCore
import VibeUsagePricing
import VibeUsageStorage
import VibeUsageUI
import VibeUsageWatching

struct VibeUsageApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(viewModel: viewModel)
        } label: {
            if let todaySpendMenuText = viewModel.todaySpendMenuText {
                Label(todaySpendMenuText, systemImage: "chart.bar.xaxis")
            } else {
                Image(systemName: "chart.bar.xaxis")
            }
        }
        .menuBarExtraStyle(.window)

        Window(dashboardWindowTitle, id: "dashboard") {
            DashboardWindowView(
                snapshot: viewModel.insights,
                isLoading: viewModel.isLoadingInsights,
                selectedRange: $viewModel.insightsRange,
                onRangeChange: { viewModel.reloadInsights() },
                onRefresh: { viewModel.refresh() }
            )
        }
    }
}

private let dashboardWindowTitle = VibeUsageStrings.text(zh: "用量控制台", en: "Usage Console")

/// Thin wrapper so `\.openWindow` (only available inside scene content, not
/// on the `App` itself) can be read for the "open console" button in the
/// menu bar view.
private struct MenuContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let startupError = viewModel.startupError {
            StartupFailureView(message: startupError, onQuit: { NSApp.terminate(nil) })
        } else {
            MenuBarUsageView(
                snapshot: viewModel.snapshot,
                isRefreshing: viewModel.isRefreshing,
                lastError: viewModel.lastError,
                configurableAgentSources: viewModel.configurableAgentSources,
                hiddenAgentSourceIDs: viewModel.hiddenAgentSourceIDs,
                selectedDateRange: $viewModel.selectedDateRange,
                selectedModelFilter: $viewModel.selectedModelFilter,
                showsSpendInMenuBar: $viewModel.showsSpendInMenuBar,
                onRefresh: { viewModel.refresh() },
                onFilterChange: { viewModel.applyFilters() },
                onAgentDisplayCommit: { hidden in
                    viewModel.setHiddenAgentSourceIDs(hidden)
                },
                onOpenDashboard: {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                },
                onQuit: { NSApp.terminate(nil) }
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
    @Published var hiddenAgentSourceIDs: Set<AgentSourceID>
    @Published var insights: UsageInsightsSnapshot = .empty()
    @Published var insightsRange: UsageInsightsRange = .last30Days
    @Published var isLoadingInsights = false
    @Published var todaySpendMenuText: String?
    @Published var showsSpendInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showsSpendInMenuBar, forKey: Self.showsSpendInMenuBarKey)
            updateTodaySpendMenuText()
        }
    }

    private let ingestor: UsageIngestor?
    private let aggregation: UsageAggregationService?
    private let allSourceDescriptors: [AgentSourceDescriptor]
    private var locallyDiscoveredSourceIDs = Set<AgentSourceID>()
    private var autoRefreshCoordinator: UsageAutoRefreshCoordinator?
    private var pendingRefresh = false
    private var lastTodaySpend: Decimal?

    init() {
        let registry = AdapterRegistry()
        registry.register(ClaudeCodeAdapter())
        registry.register(CodexCLIAdapter())
        for adapter in AdditionalSourceAdapters.all {
            registry.register(adapter)
        }

        self.allSourceDescriptors = registry.descriptors
        self.hiddenAgentSourceIDs = Self.loadHiddenAgentSourceIDs()
        self.showsSpendInMenuBar = Self.loadShowsSpendInMenuBar()
        self.snapshot = .empty()

        do {
            let database = try UsageDatabase(path: UsageDatabase.defaultStorePath())
            let store = GRDBUsageEventStore(database: database)
            let pricing = BundledPricingProvider()
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

        Task {
            await GitHubReleaseUpdater.checkForUpdates()
        }
    }

    deinit {
        autoRefreshCoordinator?.stop()
    }

    func setHiddenAgentSourceIDs(_ hiddenSourceIDs: Set<AgentSourceID>) {
        hiddenAgentSourceIDs = hiddenSourceIDs
        Self.saveHiddenAgentSourceIDs(hiddenAgentSourceIDs)
        applyFilters()
    }

    func refresh() {
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
                    reloadInsights()
                    reloadTodaySpend()
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reloadInsights() {
        guard let aggregation else { return }
        isLoadingInsights = true
        defer { isLoadingInsights = false }
        do {
            insights = try aggregation.insightsSnapshot(
                visibleSourceFilter: Self.visibleSourceIDs(
                    discovered: locallyDiscoveredSourceIDs,
                    hidden: hiddenAgentSourceIDs
                ),
                modelFilter: [],
                range: insightsRange
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func reloadTodaySpend() {
        guard let aggregation else { return }
        do {
            let todaySnapshot = try aggregation.dashboardSnapshot(
                visibleSourceFilter: Self.visibleSourceIDs(
                    discovered: locallyDiscoveredSourceIDs,
                    hidden: hiddenAgentSourceIDs
                ),
                dateRange: .today
            )
            lastTodaySpend = todaySnapshot.totals.costUSD
        } catch {
            lastTodaySpend = nil
        }
        updateTodaySpendMenuText()
    }

    private func updateTodaySpendMenuText() {
        guard showsSpendInMenuBar, let spend = lastTodaySpend, spend > 0 else {
            todaySpendMenuText = nil
            return
        }
        todaySpendMenuText = Self.formatMenuBarSpend(spend)
    }

    private static func formatMenuBarSpend(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = amount < 100 ? 1 : 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0"
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
    private static let showsSpendInMenuBarKey = "showsSpendInMenuBar"

    private static func loadHiddenAgentSourceIDs() -> Set<AgentSourceID> {
        let rawValues = UserDefaults.standard.stringArray(forKey: hiddenAgentSourceIDsKey) ?? []
        return Set(rawValues.map { AgentSourceID(rawValue: $0) })
    }

    private static func loadShowsSpendInMenuBar() -> Bool {
        UserDefaults.standard.object(forKey: showsSpendInMenuBarKey) as? Bool ?? true
    }

    private static func saveHiddenAgentSourceIDs(_ ids: Set<AgentSourceID>) {
        UserDefaults.standard.set(ids.map(\.rawValue).sorted(), forKey: hiddenAgentSourceIDsKey)
    }
}

VibeUsageApp.main()
