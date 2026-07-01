import Foundation

/// Central, data-driven registry of usage source adapters.
///
/// Aggregation and UI code iterate `AdapterRegistry.shared.allAdapters` /
/// `.descriptors` to discover what sources exist — never a hardcoded list.
/// Adding a new agent is exactly one `register(...)` call, typically made
/// once at app startup from the composition root.
public final class AdapterRegistry: @unchecked Sendable {
    public static let shared = AdapterRegistry()

    private var adaptersByID: [AgentSourceID: any UsageSourceAdapter] = [:]
    private let lock = NSLock()

    public init() {}

    public func register(_ adapter: any UsageSourceAdapter) {
        lock.lock()
        defer { lock.unlock() }
        adaptersByID[adapter.descriptor.id] = adapter
    }

    public var allAdapters: [any UsageSourceAdapter] {
        lock.lock()
        defer { lock.unlock() }
        return adaptersByID.values.sorted { $0.descriptor.sortOrder < $1.descriptor.sortOrder }
    }

    public var descriptors: [AgentSourceDescriptor] {
        allAdapters.map(\.descriptor)
    }

    public func adapter(for id: AgentSourceID) -> (any UsageSourceAdapter)? {
        lock.lock()
        defer { lock.unlock() }
        return adaptersByID[id]
    }
}
