import Foundation
import VibeUsageCore

/// Keeps usage data fresh by combining FSEvents directory watching with a
/// periodic rescan fallback. File-change signals are debounced so bursty log
/// writes trigger one ingest pass instead of many. When possible, only adapters
/// and files touched by the changed paths are rescanned.
public final class UsageAutoRefreshCoordinator: @unchecked Sendable {
    public static let defaultRefreshInterval: TimeInterval = 300
    public static let defaultDebounceInterval: TimeInterval = 10

    public struct RefreshRequest: Sendable, Equatable {
        /// Empty means scan every registered adapter.
        public let sourceFilter: Set<AgentSourceID>
        /// `nil` means no file-level restriction (full discover for selected sources).
        public let changedPaths: Set<String>?

        public init(sourceFilter: Set<AgentSourceID> = [], changedPaths: Set<String>? = nil) {
            self.sourceFilter = sourceFilter
            self.changedPaths = changedPaths
        }

        public static let full = RefreshRequest(sourceFilter: [], changedPaths: nil)
    }

    private let registry: AdapterRegistry
    private let refreshInterval: TimeInterval
    private let debounceInterval: TimeInterval
    private let onRefresh: @Sendable (RefreshRequest) async -> Void

    private lazy var watcher = UsageDirectoryWatcher { [weak self] paths in
        self?.scheduleDebouncedRefresh(changedPaths: paths)
    }

    private let timerQueue = DispatchQueue(label: "com.vibeusage.auto-refresh.timer")
    private var timer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceQueue = DispatchQueue(label: "com.vibeusage.auto-refresh.debounce")
    /// `nil` while idle.
    private var debouncedRequest: RefreshRequest?

    public init(
        registry: AdapterRegistry,
        refreshInterval: TimeInterval = UsageAutoRefreshCoordinator.defaultRefreshInterval,
        debounceInterval: TimeInterval = UsageAutoRefreshCoordinator.defaultDebounceInterval,
        onRefresh: @escaping @Sendable (RefreshRequest) async -> Void
    ) {
        self.registry = registry
        self.refreshInterval = refreshInterval
        self.debounceInterval = debounceInterval
        self.onRefresh = onRefresh
    }

    deinit {
        stop()
    }

    public func start() {
        refreshWatchedPaths()
        startTimer()
        Task {
            await onRefresh(.full)
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        debouncedRequest = nil
        watcher.stop()
    }

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
        timer.setEventHandler { [weak self] in
            self?.handlePeriodicRefresh()
        }
        timer.resume()
        self.timer = timer
    }

    private func handlePeriodicRefresh() {
        refreshWatchedPaths()
        Task {
            await onRefresh(.full)
        }
    }

    private func refreshWatchedPaths() {
        watcher.update(paths: UsageWatchPaths.directories(from: registry))
    }

    private func scheduleDebouncedRefresh(changedPaths: [String]) {
        debounceQueue.async { [weak self] in
            guard let self else { return }

            let mapped = UsageWatchPaths.sourceIDs(forChangedPaths: changedPaths, registry: registry)
            let normalizedPaths = UsageWatchPaths.normalizedChangedPaths(changedPaths)
            // Unmapped paths fall back to a full scan so we never miss a source.
            let incoming = mapped.isEmpty
                ? RefreshRequest.full
                : RefreshRequest(sourceFilter: mapped, changedPaths: normalizedPaths)
            debouncedRequest = merge(debouncedRequest, with: incoming)

            debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let request = self.debouncedRequest ?? .full
                self.debouncedRequest = nil
                Task {
                    await self.onRefresh(request)
                }
            }
            debounceWorkItem = work
            debounceQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }
    }

    private func merge(_ existing: RefreshRequest?, with incoming: RefreshRequest) -> RefreshRequest {
        guard let existing else { return incoming }
        if existing.changedPaths == nil || incoming.changedPaths == nil {
            let sources: Set<AgentSourceID>
            if existing.sourceFilter.isEmpty || incoming.sourceFilter.isEmpty {
                sources = []
            } else {
                sources = existing.sourceFilter.union(incoming.sourceFilter)
            }
            return RefreshRequest(sourceFilter: sources, changedPaths: nil)
        }
        let sources: Set<AgentSourceID>
        if existing.sourceFilter.isEmpty || incoming.sourceFilter.isEmpty {
            sources = []
        } else {
            sources = existing.sourceFilter.union(incoming.sourceFilter)
        }
        return RefreshRequest(
            sourceFilter: sources,
            changedPaths: existing.changedPaths?.union(incoming.changedPaths ?? [])
        )
    }
}
