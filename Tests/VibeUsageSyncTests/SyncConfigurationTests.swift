import Foundation
import XCTest
@testable import VibeUsageSync

final class SyncConfigurationTests: XCTestCase {
    func testWebDAVSeparatesPersistedConfigurationFromPassword() throws {
        let draft = SyncConnectionDraft(
            backend: .webDAV,
            webDAVURL: "https://dav.example/team",
            webDAVUsername: "alice",
            webDAVPassword: "top-secret"
        )

        let resolved = try draft.resolve()
        let encoded = try JSONEncoder().encode(resolved.configuration)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(resolved.configuration.backend, .webDAV)
        XCTAssertEqual(resolved.credentials.webDAVPassword, "top-secret")
        XCTAssertFalse(text.contains("top-secret"))
        XCTAssertTrue(text.contains("alice"))
    }

    func testS3SeparatesPersistedConfigurationFromSecretKey() throws {
        let draft = SyncConnectionDraft(
            backend: .s3,
            s3Endpoint: "https://objects.example",
            s3Region: "auto",
            s3Bucket: "usage",
            s3Prefix: "team-a",
            s3AccessKey: "ACCESS",
            s3SecretKey: "SECRET",
            s3UsesPathStyle: true
        )

        let resolved = try draft.resolve()
        let encoded = try JSONEncoder().encode(resolved.configuration)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(resolved.configuration.backend, .s3)
        XCTAssertEqual(resolved.credentials.s3SecretKey, "SECRET")
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertTrue(text.contains("ACCESS"))
    }

    func testRejectsInsecureRemoteURLs() {
        let draft = SyncConnectionDraft(
            backend: .webDAV,
            webDAVURL: "http://nas.local/dav",
            webDAVUsername: "alice",
            webDAVPassword: "password"
        )

        XCTAssertThrowsError(try draft.resolve())
    }
}
