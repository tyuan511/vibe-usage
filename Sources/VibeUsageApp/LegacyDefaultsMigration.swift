import Foundation

/// Release builds moved from bundle identifier `me.tangge.vibeusage` to
/// `vibeusage.fastvibe.dev`, and UserDefaults are keyed by bundle identifier.
/// Copies the old domain's settings once so an in-place update keeps them.
enum LegacyDefaultsMigration {
    static let legacyDomain = "me.tangge.vibeusage"
    static let completedKey = "legacyDefaultsMigrationCompleted"

    /// Login-item registration belongs to the old bundle identity, so the new
    /// one must go through default registration again.
    static let excludedKeys: Set<String> = [
        LoginItemController.defaultRegistrationAttemptedKey,
        LoginItemController.defaultRegistrationErrorKey
    ]

    static func run(
        legacyValues: [String: Any]? = UserDefaults.standard.persistentDomain(forName: legacyDomain),
        into defaults: UserDefaults = .standard,
        currentDomain: String? = Bundle.main.bundleIdentifier
    ) {
        guard currentDomain != legacyDomain, !defaults.bool(forKey: completedKey) else { return }
        defaults.set(true, forKey: completedKey)
        for (key, value) in legacyValues ?? [:]
        where !excludedKeys.contains(key) && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
