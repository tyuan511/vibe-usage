import AppKit
import SwiftUI
import VibeUsageAdapterAdditional
import VibeUsageAdapterClaude
import VibeUsageAdapterCodex
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
            MenuBarUsageView(
                snapshot: viewModel.snapshot,
                isRefreshing: viewModel.isRefreshing,
                lastError: viewModel.lastError,
                configurableAgentSources: viewModel.configurableAgentSources,
                hiddenAgentSourceIDs: viewModel.hiddenAgentSourceIDs,
                selectedDateRange: $viewModel.selectedDateRange,
                onRefresh: { viewModel.refresh() },
                onFilterChange: { viewModel.applyFilters() },
                onAgentVisibilityCommit: { hiddenSourceIDs in
                    viewModel.setHiddenAgentSourceIDs(hiddenSourceIDs)
                },
                onQuit: { NSApp.terminate(nil) }
            )
            .onAppear {
                viewModel.refresh()
            }
        } label: {
            Label(viewModel.menuTitle, systemImage: "chart.bar.xaxis")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var snapshot: UsageDashboardSnapshot
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var selectedDateRange: UsageDateRangePreset = .today
    @Published var configurableAgentSources: [AgentSourceDescriptor] = []
    @Published var hiddenAgentSourceIDs: Set<AgentSourceID>

    private let ingestor: UsageIngestor
    private let aggregation: UsageAggregationService
    private let allSourceDescriptors: [AgentSourceDescriptor]
    private var locallyDiscoveredSourceIDs = Set<AgentSourceID>()

    init() {
        let registry = AdapterRegistry()
        registry.register(ClaudeCodeAdapter())
        registry.register(CodexCLIAdapter())
        for adapter in AdditionalSourceAdapters.all {
            registry.register(adapter)
        }

        let database: UsageDatabase
        let store: GRDBUsageEventStore
        do {
            database = try UsageDatabase(path: UsageDatabase.defaultStorePath())
            store = GRDBUsageEventStore(database: database)
        } catch {
            fatalError("Failed to open VibeUsage database: \(error)")
        }

        let pricing = BundledPricingProvider()
        self.ingestor = UsageIngestor(registry: registry, store: store, pricing: pricing)
        self.aggregation = UsageAggregationService(store: store, registry: registry)
        self.allSourceDescriptors = registry.descriptors
        self.hiddenAgentSourceIDs = Self.loadHiddenAgentSourceIDs()
        self.snapshot = .empty()

        Task { @MainActor in
            refresh()
        }
        Task {
            await GitHubReleaseUpdater.checkForUpdates()
        }
    }

    var menuTitle: String {
        isRefreshing ? VibeUsageStrings.text(zh: "扫描中", en: "Scanning") : snapshot.totals.costUSD.usdString
    }

    func refresh() {
        guard !isRefreshing else { return }
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
                    dateRange: selectedDateRange
                )
                await MainActor.run {
                    locallyDiscoveredSourceIDs = summary.discoveredSourceIDs
                    configurableAgentSources = configurableSources
                    snapshot = next
                    isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    lastError = error.localizedDescription
                    isRefreshing = false
                }
            }
        }
    }

    func applyFilters() {
        do {
            snapshot = try aggregation.dashboardSnapshot(
                visibleSourceFilter: Self.visibleSourceIDs(
                    discovered: locallyDiscoveredSourceIDs,
                    hidden: hiddenAgentSourceIDs
                ),
                dateRange: selectedDateRange
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setHiddenAgentSourceIDs(_ ids: Set<AgentSourceID>) {
        hiddenAgentSourceIDs = ids
        Self.saveHiddenAgentSourceIDs(hiddenAgentSourceIDs)
        applyFilters()
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

    private static func loadHiddenAgentSourceIDs() -> Set<AgentSourceID> {
        let rawValues = UserDefaults.standard.stringArray(forKey: hiddenAgentSourceIDsKey) ?? []
        return Set(rawValues.map { AgentSourceID(rawValue: $0) })
    }

    private static func saveHiddenAgentSourceIDs(_ ids: Set<AgentSourceID>) {
        UserDefaults.standard.set(ids.map(\.rawValue).sorted(), forKey: hiddenAgentSourceIDsKey)
    }

}

private extension Decimal {
    var usdString: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = self < 1 ? 4 : 2
        return formatter.string(from: self as NSDecimalNumber) ?? "$0.00"
    }
}

VibeUsageApp.main()
