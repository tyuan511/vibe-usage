import Foundation
import XCTest
@testable import VibeUsageApp

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testRegistersLoginItemOnFirstLaunch() {
        let service = LoginItemServiceStub(status: .notRegistered)
        let defaults = isolatedUserDefaults()

        let controller = LoginItemController(service: service, defaults: defaults)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: LoginItemController.defaultRegistrationAttemptedKey))
    }

    func testDoesNotRetryDefaultRegistrationAfterFailure() {
        let service = LoginItemServiceStub(status: .notRegistered, registrationError: TestError.registrationFailed)
        let defaults = isolatedUserDefaults()

        let firstController = LoginItemController(service: service, defaults: defaults)
        let secondController = LoginItemController(service: service, defaults: defaults)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(firstController.isEnabled)
        XCTAssertEqual(firstController.errorDescription, "Registration failed")
        XCTAssertEqual(secondController.errorDescription, "Registration failed")
    }

    func testRespectsExistingMigrationMarker() {
        let service = LoginItemServiceStub(status: .notRegistered)
        let defaults = isolatedUserDefaults()
        defaults.set(true, forKey: LoginItemController.defaultRegistrationAttemptedKey)

        let controller = LoginItemController(service: service, defaults: defaults)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(controller.isEnabled)
    }

    func testRefreshesAfterSystemSettingChanges() {
        let service = LoginItemServiceStub(status: .enabled)
        let defaults = isolatedUserDefaults()
        defaults.set(true, forKey: LoginItemController.defaultRegistrationAttemptedKey)
        let controller = LoginItemController(service: service, defaults: defaults)

        service.status = .notRegistered
        controller.refresh()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testUserCanEnableAndDisableLoginItem() {
        let service = LoginItemServiceStub(status: .notRegistered)
        let defaults = isolatedUserDefaults()
        defaults.set(true, forKey: LoginItemController.defaultRegistrationAttemptedKey)
        let controller = LoginItemController(service: service, defaults: defaults)

        controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.registerCallCount, 1)

        controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(service.unregisterCallCount, 1)
    }

    func testApprovalRequiredIsNotReportedAsEnabled() {
        let service = LoginItemServiceStub(status: .requiresApproval)
        let defaults = isolatedUserDefaults()

        let controller = LoginItemController(service: service, defaults: defaults)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testRefreshClearsErrorAfterSystemSettingChanges() {
        let service = LoginItemServiceStub(status: .notRegistered, registrationError: TestError.registrationFailed)
        let controller = LoginItemController(service: service, defaults: isolatedUserDefaults())
        XCTAssertEqual(controller.errorDescription, "Registration failed")

        service.status = .enabled
        controller.refresh()

        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorDescription)
    }

    func testFailedDisableKeepsErrorAndRealEnabledState() {
        let service = LoginItemServiceStub(status: .enabled, unregistrationError: TestError.unregistrationFailed)
        let defaults = isolatedUserDefaults()
        defaults.set(true, forKey: LoginItemController.defaultRegistrationAttemptedKey)
        let controller = LoginItemController(service: service, defaults: defaults)

        controller.setEnabled(false)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.errorDescription, "Unregistration failed")
        XCTAssertEqual(service.unregisterCallCount, 1)
    }

    private func isolatedUserDefaults() -> UserDefaults {
        let suiteName = "LoginItemControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class LoginItemServiceStub: LoginItemService {
    var status: LoginItemStatus
    var registerCallCount = 0
    var unregisterCallCount = 0
    let registrationError: (any Error)?
    let unregistrationError: (any Error)?

    init(
        status: LoginItemStatus,
        registrationError: (any Error)? = nil,
        unregistrationError: (any Error)? = nil
    ) {
        self.status = status
        self.registrationError = registrationError
        self.unregistrationError = unregistrationError
    }

    func register() throws {
        registerCallCount += 1
        if let registrationError {
            throw registrationError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregistrationError {
            throw unregistrationError
        }
        status = .notRegistered
    }
}

private enum TestError: LocalizedError {
    case registrationFailed
    case unregistrationFailed

    var errorDescription: String? {
        switch self {
        case .registrationFailed:
            "Registration failed"
        case .unregistrationFailed:
            "Unregistration failed"
        }
    }
}
