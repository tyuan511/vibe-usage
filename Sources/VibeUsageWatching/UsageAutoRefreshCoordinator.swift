import Foundation
import VibeUsageCore

/// Keeps usage data fresh by combining FSEvents directory watching with a
/// periodic rescan fallback. File-change signals are debounced so bursty log
/// writes trigger one ingest pass instead of many.
public final class UsageAutoRefreshCoordinator: @unchecked Sendable {
    public static let defaultRefreshInterval: TimeInterval = 300
    public static let defaultDebounceInterval: TimeInterval = 2

    private let registry: AdapterRegistry
    private let refreshInterval: TimeInterval
    private let debounceInterval: TimeInterval
    private let onRefresh: @Sendable () async -> Void

    private lazy var watcher = UsageDirectoryWatcher { [weak self] in
        self?.scheduleDebouncedRefresh()
    }

    private let timerQueue = DispatchQueue(label: "com.vibeusage.auto-refresh.timer")
    private var timer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceQueue = DispatchQueue(label: "com.vibeusage.auto-refresh.debounce")

    public init(
        registry: AdapterRegistry,
        refreshInterval: TimeInterval = UsageAutoRefreshCoordinator.defaultRefreshInterval,
        debounceInterval: TimeInterval = UsageAutoRefreshCoordinator.defaultDebounceInterval,
        onRefresh: @escaping @Sendable () async -> Void
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
            await onRefresh()
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
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
            await onRefresh()
        }
    }

    private func refreshWatchedPaths() {
        watcher.update(paths: UsageWatchPaths.directories(from: registry))
    }

    private func scheduleDebouncedRefresh() {
        debounceQueue.async { [weak self] in
            guard let self else { return }
            debounceWorkItem?.cancel()
            let work = DispatchWorkItem {
                Task {
                    await self.onRefresh()
                }
            }
            debounceWorkItem = work
            debounceQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }
    }
}
