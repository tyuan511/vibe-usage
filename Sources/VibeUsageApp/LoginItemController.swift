import Combine
import Foundation
import ServiceManagement

enum LoginItemStatus {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var isEnabled: Bool {
        self == .enabled
    }

    var requiresApproval: Bool {
        self == .requiresApproval
    }
}

protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class LoginItemController: ObservableObject {
    static let defaultRegistrationAttemptedKey = "loginItemDefaultRegistrationAttempted"
    static let defaultRegistrationErrorKey = "loginItemDefaultRegistrationError"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var requiresApproval: Bool
    @Published private(set) var errorDescription: String?

    private let service: LoginItemService
    private let defaults: UserDefaults

    init(
        service: LoginItemService = SystemLoginItemService(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
        let status = service.status
        self.isEnabled = status.isEnabled
        self.requiresApproval = status.requiresApproval
        self.errorDescription = defaults.string(forKey: Self.defaultRegistrationErrorKey)

        guard !defaults.bool(forKey: Self.defaultRegistrationAttemptedKey) else { return }
        defaults.set(true, forKey: Self.defaultRegistrationAttemptedKey)
        guard service.status == .notRegistered || service.status == .notFound else { return }
        do {
            try service.register()
            defaults.removeObject(forKey: Self.defaultRegistrationErrorKey)
        } catch {
            errorDescription = error.localizedDescription
            defaults.set(errorDescription, forKey: Self.defaultRegistrationErrorKey)
        }
        synchronizeStatus(clearingResolvedError: false)
    }

    func setEnabled(_ shouldEnable: Bool) {
        errorDescription = nil
        defaults.removeObject(forKey: Self.defaultRegistrationErrorKey)
        do {
            if shouldEnable {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorDescription = error.localizedDescription
        }
        synchronizeStatus(clearingResolvedError: false)
    }

    func refresh() {
        synchronizeStatus(clearingResolvedError: true)
    }

    private func synchronizeStatus(clearingResolvedError: Bool) {
        let status = service.status
        isEnabled = status.isEnabled
        requiresApproval = status.requiresApproval
        if clearingResolvedError && (isEnabled || requiresApproval) {
            errorDescription = nil
            defaults.removeObject(forKey: Self.defaultRegistrationErrorKey)
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

private final class SystemLoginItemService: LoginItemService {
    private let service = SMAppService.mainApp

    var status: LoginItemStatus {
        switch service.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}
