import Foundation
import XCTest
@testable import VibeUsageSync

final class ObjectStoreTests: XCTestCase {
    func testWebDAVMapsObjectOperationsToAuthenticatedRequests() async throws {
        let http = RecordingHTTPClient(responses: [
            .success(status: 201),
            .success(status: 201),
            .success(status: 201),
            .success(status: 201),
            .success(status: 200, data: Data("payload".utf8), headers: ["ETag": "etag-1"]),
            .success(status: 204),
        ])
        let store = try WebDAVObjectStore(
            configuration: WebDAVConfiguration(
                baseURL: URL(string: "https://dav.example/team")!,
                username: "alice",
                password: "app-password"
            ),
            httpClient: http
        )

        try await store.write(key: "vibeusage/sync/v1/test.json", data: Data("payload".utf8))
        let object = try await store.read(key: "vibeusage/sync/v1/test.json")
        try await store.delete(key: "vibeusage/sync/v1/test.json")

        XCTAssertEqual(object.data, Data("payload".utf8))
        XCTAssertEqual(object.etag, "etag-1")
        let requests = http.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["MKCOL", "MKCOL", "MKCOL", "PUT", "GET", "DELETE"])
        XCTAssertEqual(requests[3].url?.absoluteString, "https://dav.example/team/vibeusage/sync/v1/test.json")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Basic YWxpY2U6YXBwLXBhc3N3b3Jk")
    }

    func testS3PathStyleWriteUsesConfiguredEndpointAndSignatureScope() async throws {
        let http = RecordingHTTPClient(responses: [.success(status: 200)])
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-13T08:15:00Z"))
        let store = try S3ObjectStore(
            configuration: S3Configuration(
                endpoint: URL(string: "https://objects.example")!,
                region: "us-east-1",
                bucket: "usage",
                prefix: "team-a",
                accessKey: "AKID",
                secretKey: "SECRET",
                usesPathStyle: true
            ),
            httpClient: http,
            now: { now }
        )

        try await store.write(key: "vibeusage/sync/v1/test.json", data: Data("payload".utf8))

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://objects.example/usage/team-a/vibeusage/sync/v1/test.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "20260713T081500Z")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization")?.contains(
            "Credential=AKID/20260713/us-east-1/s3/aws4_request"
        ), true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization")?.hasSuffix(
            "Signature=018ee74b551ea39f11dacb70392624663b2ca9200bee04748d51263072838584"
        ), true)
    }

    func testWebDAVListsObjectsRelativeToConfiguredBase() async throws {
        let xml = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/team/vibeusage/sync/v1/devices/device-a/profile.json</d:href>
                <d:propstat><d:prop><d:getetag>etag-a</d:getetag><d:getcontentlength>42</d:getcontentlength></d:prop></d:propstat>
              </d:response>
            </d:multistatus>
            """.utf8)
        let http = RecordingHTTPClient(responses: [.success(status: 207, data: xml)])
        let store = try WebDAVObjectStore(
            configuration: WebDAVConfiguration(
                baseURL: URL(string: "https://dav.example/team")!,
                username: "alice",
                password: "password"
            ),
            httpClient: http
        )

        let objects = try await store.list(prefix: "vibeusage/sync/v1/devices")

        XCTAssertEqual(objects, [SyncObjectMetadata(
            key: "vibeusage/sync/v1/devices/device-a/profile.json",
            etag: "etag-a",
            size: 42
        )])
        XCTAssertEqual(http.requests.first?.httpMethod, "PROPFIND")
        XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Depth"), "1")
    }

    func testWebDAVRecursivelyListsDepthOneCollections() async throws {
        let firstPage = Data("""
            <d:multistatus xmlns:d="DAV:">
              <d:response><d:href>/team/vibeusage/sync/v1/devices/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
              <d:response><d:href>/team/vibeusage/sync/v1/devices/device-a/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
            </d:multistatus>
            """.utf8)
        let secondPage = Data("""
            <d:multistatus xmlns:d="DAV:">
              <d:response><d:href>/team/vibeusage/sync/v1/devices/device-a/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
              <d:response><d:href>/team/vibeusage/sync/v1/devices/device-a/profile.json</d:href><d:propstat><d:prop><d:getcontentlength>10</d:getcontentlength></d:prop></d:propstat></d:response>
            </d:multistatus>
            """.utf8)
        let http = RecordingHTTPClient(responses: [
            .success(status: 207, data: firstPage),
            .success(status: 207, data: secondPage),
        ])
        let store = try WebDAVObjectStore(
            configuration: WebDAVConfiguration(
                baseURL: URL(string: "https://dav.example/team")!,
                username: "alice",
                password: "password"
            ),
            httpClient: http
        )

        let objects = try await store.list(prefix: "vibeusage/sync/v1/devices")

        XCTAssertEqual(objects.map(\.key), ["vibeusage/sync/v1/devices/device-a/profile.json"])
        XCTAssertEqual(http.requests.count, 2)
    }

    func testS3ListsReadsAndDeletesRelativeObjects() async throws {
        let xml = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult>
              <Contents><Key>team-a/vibeusage/sync/v1/test.json</Key><ETag>\"etag-a\"</ETag><Size>7</Size></Contents>
            </ListBucketResult>
            """.utf8)
        let http = RecordingHTTPClient(responses: [
            .success(status: 200, data: xml),
            .success(status: 200, data: Data("payload".utf8), headers: ["ETag": "etag-a"]),
            .success(status: 204),
        ])
        let store = try S3ObjectStore(
            configuration: S3Configuration(
                endpoint: URL(string: "https://objects.example")!,
                region: "auto",
                bucket: "usage",
                prefix: "team-a",
                accessKey: "AKID",
                secretKey: "SECRET",
                usesPathStyle: true
            ),
            httpClient: http
        )

        let objects = try await store.list(prefix: "vibeusage/sync/v1")
        let object = try await store.read(key: "vibeusage/sync/v1/test.json")
        try await store.delete(key: "vibeusage/sync/v1/test.json")

        XCTAssertEqual(objects, [SyncObjectMetadata(key: "vibeusage/sync/v1/test.json", etag: "etag-a", size: 7)])
        XCTAssertEqual(object.data, Data("payload".utf8))
        XCTAssertEqual(http.requests.map(\.httpMethod), ["GET", "GET", "DELETE"])
    }
}

private final class RecordingHTTPClient: SyncHTTPClient, @unchecked Sendable {
    struct Response {
        let status: Int
        let data: Data
        let headers: [String: String]

        static func success(status: Int, data: Data = Data(), headers: [String: String] = [:]) -> Response {
            Response(status: status, data: data, headers: headers)
        }
    }

    private let lock = NSLock()
    private var queued: [Response]
    private var recorded: [URLRequest] = []

    init(responses: [Response]) {
        queued = responses
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try lock.withLock {
            recorded.append(request)
            guard !queued.isEmpty else { throw URLError(.badServerResponse) }
            let response = queued.removeFirst()
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: nil,
                headerFields: response.headers
            )!
            return (response.data, httpResponse)
        }
    }
}
