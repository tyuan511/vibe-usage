import Foundation
import VibeUsageStorage
import VibeUsageSync
import XCTest
@testable import VibeUsageApp

final class AppSyncControllerTests: XCTestCase {
    @MainActor
    func testInvalidConfigurationReturnsSaveFailure() async throws {
        let suiteName = "AppSyncControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = try AppSyncController(
            usageStore: GRDBUsageEventStore(database: try UsageDatabase()),
            preferences: SyncPreferences(defaults: defaults),
            credentialStore: MemorySyncCredentialStore(),
            defaults: defaults
        )
        controller.draft = SyncConnectionDraft(
            backend: .webDAV,
            webDAVURL: "",
            webDAVUsername: "",
            webDAVPassword: ""
        )

        let succeeded = await controller.testAndSaveConfiguration()

        XCTAssertFalse(succeeded)
        XCTAssertNotNil(controller.lastError)
        XCTAssertFalse(controller.isTestingConnection)
    }

    @MainActor
    func testValidConfigurationReturnsSuccessAndPersistsTarget() async throws {
        let suiteName = "AppSyncControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = MemorySyncCredentialStore()
        let preferences = SyncPreferences(defaults: defaults)
        let controller = try AppSyncController(
            usageStore: GRDBUsageEventStore(database: try UsageDatabase()),
            preferences: preferences,
            credentialStore: credentials,
            httpClient: SuccessfulProbeHTTPClient(),
            defaults: defaults
        )
        controller.draft = SyncConnectionDraft(
            backend: .s3,
            s3Endpoint: "https://objects.example",
            s3Region: "auto",
            s3Bucket: "usage",
            s3AccessKey: "AKID",
            s3SecretKey: "SECRET"
        )

        let succeeded = await controller.testAndSaveConfiguration()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(controller.configuration?.s3?.bucket, "usage")
        XCTAssertEqual(preferences.loadConfiguration()?.s3?.bucket, "usage")
        XCTAssertEqual(try credentials.load()?.s3SecretKey, "SECRET")
        XCTAssertNil(controller.lastError)
        XCTAssertFalse(controller.isTestingConnection)
    }

    @MainActor
    func testApplyKeepsLocalDeviceVisible() throws {
        let suiteName = "AppSyncControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = try AppSyncController(
            usageStore: GRDBUsageEventStore(database: try UsageDatabase()),
            preferences: SyncPreferences(defaults: defaults),
            credentialStore: MemorySyncCredentialStore(),
            defaults: defaults
        )
        let localID = try XCTUnwrap(controller.devices.first(where: \.isLocal)?.id)
        var presentation = controller.settingsPresentation
        presentation.hiddenDeviceIDs.insert(localID)

        controller.apply(presentation)

        XCTAssertFalse(controller.hiddenDeviceIDs.contains(localID))
        XCTAssertTrue(controller.visibleDeviceIDs.contains(localID))
    }
}

private final class MemorySyncCredentialStore: SyncCredentialStoring, @unchecked Sendable {
    private var credentials: SyncCredentials?

    func load() throws -> SyncCredentials? { credentials }
    func save(_ credentials: SyncCredentials) throws { self.credentials = credentials }
    func clear() throws { credentials = nil }
}

private struct SuccessfulProbeHTTPClient: SyncHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let status = request.httpMethod == "DELETE" ? 204 : 200
        let data = request.httpMethod == "GET" ? Data("vibeusage-sync-probe".utf8) : Data()
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        ))
        return (data, response)
    }
}
