import CryptoKit
import Foundation

public struct S3Configuration: Sendable, Equatable {
    public let endpoint: URL
    public let region: String
    public let bucket: String
    public let prefix: String
    public let accessKey: String
    public let secretKey: String
    public let usesPathStyle: Bool

    public init(
        endpoint: URL,
        region: String,
        bucket: String,
        prefix: String,
        accessKey: String,
        secretKey: String,
        usesPathStyle: Bool
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.usesPathStyle = usesPathStyle
    }
}

public struct S3ObjectStore: SyncObjectStore {
    private let configuration: S3Configuration
    private let httpClient: any SyncHTTPClient
    private let now: @Sendable () -> Date

    public init(
        configuration: S3Configuration,
        httpClient: any SyncHTTPClient = URLSessionSyncHTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard configuration.endpoint.scheme?.lowercased() == "https" else {
            throw SyncObjectStoreError.invalidConfiguration("S3 requires an HTTPS endpoint.")
        }
        guard !configuration.region.isEmpty, !configuration.bucket.isEmpty,
              !configuration.accessKey.isEmpty, !configuration.secretKey.isEmpty else {
            throw SyncObjectStoreError.invalidConfiguration("S3 region, bucket, access key, and secret key are required.")
        }
        self.configuration = configuration
        self.httpClient = httpClient
        self.now = now
    }

    public func validateAccess() async throws {
        let key = "\(SyncNamespace.root)/.probe-\(UUID().uuidString.lowercased())"
        let payload = Data("vibeusage-sync-probe".utf8)
        try await write(key: key, data: payload)
        do {
            let roundTrip = try await read(key: key)
            guard roundTrip.data == payload else {
                throw SyncObjectStoreError.invalidResponse("S3 probe content did not round-trip")
            }
            try await delete(key: key)
        } catch {
            try? await delete(key: key)
            throw error
        }
    }

    public func list(prefix: String) async throws -> [SyncObjectMetadata] {
        var results: [SyncObjectMetadata] = []
        var continuationToken: String?
        repeat {
            var query = [URLQueryItem(name: "list-type", value: "2"), URLQueryItem(name: "prefix", value: objectKey(prefix))]
            if let continuationToken {
                query.append(URLQueryItem(name: "continuation-token", value: continuationToken))
            }
            let url = try bucketURL(queryItems: query)
            let request = signedRequest(url: url, method: "GET", payload: Data())
            let (data, response) = try await httpClient.data(for: request)
            guard response.statusCode == 200 else {
                throw SyncObjectStoreError.httpStatus(response.statusCode, responseDetail(data))
            }
            let page = try S3ListParser.parse(data: data)
            let configuredPrefix = normalizedPrefix
            results.append(contentsOf: page.objects.compactMap { object in
                var key = object.key
                if !configuredPrefix.isEmpty {
                    guard key.hasPrefix(configuredPrefix + "/") else { return nil }
                    key.removeFirst(configuredPrefix.count + 1)
                }
                return SyncObjectMetadata(key: key, etag: object.etag, size: object.size)
            })
            continuationToken = page.nextContinuationToken
        } while continuationToken != nil
        return results
    }

    public func read(key: String) async throws -> SyncObject {
        let url = try objectURL(key: key)
        let request = signedRequest(url: url, method: "GET", payload: Data())
        let (data, response) = try await httpClient.data(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 404 { throw SyncObjectStoreError.notFound(key) }
            throw SyncObjectStoreError.httpStatus(response.statusCode, responseDetail(data))
        }
        return SyncObject(data: data, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    public func write(key: String, data: Data) async throws {
        let url = try objectURL(key: key)
        var request = signedRequest(url: url, method: "PUT", payload: data)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await httpClient.data(for: request)
        guard [200, 201, 204].contains(response.statusCode) else {
            throw SyncObjectStoreError.httpStatus(response.statusCode, responseDetail(responseData))
        }
    }

    public func delete(key: String) async throws {
        let url = try objectURL(key: key)
        let request = signedRequest(url: url, method: "DELETE", payload: Data())
        let (data, response) = try await httpClient.data(for: request)
        guard [200, 204, 404].contains(response.statusCode) else {
            throw SyncObjectStoreError.httpStatus(response.statusCode, responseDetail(data))
        }
    }

    private var normalizedPrefix: String {
        configuration.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func objectKey(_ key: String) -> String {
        normalizedPrefix.isEmpty ? key : "\(normalizedPrefix)/\(key)"
    }

    private func objectURL(key: String) throws -> URL {
        var url = configuration.endpoint
        if configuration.usesPathStyle {
            url.appendPathComponent(configuration.bucket, isDirectory: true)
        } else {
            var components = try validEndpointComponents()
            components.host = "\(configuration.bucket).\(components.host!)"
            guard let virtualURL = components.url else {
                throw SyncObjectStoreError.invalidConfiguration("Invalid virtual-hosted S3 endpoint.")
            }
            url = virtualURL
        }
        for component in objectKey(key).split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }

    private func bucketURL(queryItems: [URLQueryItem]) throws -> URL {
        let base: URL
        if configuration.usesPathStyle {
            base = configuration.endpoint.appendingPathComponent(configuration.bucket, isDirectory: true)
        } else {
            var components = try validEndpointComponents()
            components.host = "\(configuration.bucket).\(components.host!)"
            guard let url = components.url else {
                throw SyncObjectStoreError.invalidConfiguration("Invalid virtual-hosted S3 endpoint.")
            }
            base = url
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        guard let url = components.url else {
            throw SyncObjectStoreError.invalidConfiguration("Invalid S3 list URL.")
        }
        return url
    }

    private func validEndpointComponents() throws -> URLComponents {
        guard let components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false),
              components.host != nil else {
            throw SyncObjectStoreError.invalidConfiguration("Invalid S3 endpoint.")
        }
        return components
    }

    private func signedRequest(url: URL, method: String, payload: Data) -> URLRequest {
        S3SignatureV4.request(
            url: url,
            method: method,
            payload: payload,
            region: configuration.region,
            accessKey: configuration.accessKey,
            secretKey: configuration.secretKey,
            date: now()
        )
    }
}

enum S3SignatureV4 {
    static func request(
        url: URL,
        method: String,
        payload: Data,
        region: String,
        accessKey: String,
        secretKey: String,
        date: Date
    ) -> URLRequest {
        let timestamp = timestampFormatter.string(from: date)
        let day = dayFormatter.string(from: date)
        let payloadHash = sha256Hex(payload)
        let host = url.port.map { "\(url.host!):\($0)" } ?? url.host!
        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(timestamp)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [
            method,
            url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath,
            canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
        let dateKey = hmac(key: Data(("AWS4" + secretKey).utf8), value: day)
        let regionKey = hmac(key: dateKey, value: region)
        let serviceKey = hmac(key: regionKey, value: "s3")
        let signingKey = hmac(key: serviceKey, value: "aws4_request")
        let signature = hmac(key: signingKey, data: Data(stringToSign.utf8)).hexString

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let encoded: [(String, String)] = items.map { item in
            (awsEncode(item.name), awsEncode(item.value ?? ""))
        }
        let sorted = encoded.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        return sorted.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
    }

    private static func awsEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }

    private static func hmac(key: Data, value: String) -> Data {
        hmac(key: key, data: Data(value.utf8))
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}

private struct S3ListPage {
    let objects: [(key: String, etag: String?, size: Int64?)]
    let nextContinuationToken: String?
}

private final class S3ListParser: NSObject, XMLParserDelegate {
    private var currentText = ""
    private var currentKey: String?
    private var currentETag: String?
    private var currentSize: Int64?
    private var isInsideContents = false
    private var objects: [(key: String, etag: String?, size: Int64?)] = []
    private var nextContinuationToken: String?

    static func parse(data: Data) throws -> S3ListPage {
        let delegate = S3ListParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SyncObjectStoreError.invalidResponse("malformed S3 ListObjectsV2 XML")
        }
        return S3ListPage(objects: delegate.objects, nextContinuationToken: delegate.nextContinuationToken)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        currentText = ""
        if elementName == "Contents" {
            isInsideContents = true
            currentKey = nil
            currentETag = nil
            currentSize = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isInsideContents, elementName == "Key" { currentKey = value }
        if isInsideContents, elementName == "ETag" { currentETag = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        if isInsideContents, elementName == "Size" { currentSize = Int64(value) }
        if elementName == "NextContinuationToken" { nextContinuationToken = value.isEmpty ? nil : value }
        if elementName == "Contents" {
            if let currentKey { objects.append((currentKey, currentETag, currentSize)) }
            isInsideContents = false
        }
        currentText = ""
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension URL {
    var percentEncodedPath: String {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? path
    }
}
