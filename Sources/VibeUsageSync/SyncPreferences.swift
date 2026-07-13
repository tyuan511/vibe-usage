import Foundation

public final class SyncPreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    private let configurationKey = "usageSyncConfiguration"
    private let enabledKey = "usageSyncEnabled"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    public func loadConfiguration() -> SyncConfiguration? {
        guard let data = defaults.data(forKey: configurationKey) else { return nil }
        return try? JSONDecoder().decode(SyncConfiguration.self, from: data)
    }

    public func saveConfiguration(_ configuration: SyncConfiguration) throws {
        defaults.set(try JSONEncoder().encode(configuration), forKey: configurationKey)
    }

    public func clear() {
        defaults.removeObject(forKey: configurationKey)
        defaults.removeObject(forKey: enabledKey)
    }
}
