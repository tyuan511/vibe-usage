import Foundation

public struct SyncConfiguration: Codable, Sendable, Equatable {
    public struct WebDAV: Codable, Sendable, Equatable {
        public let baseURL: String
        public let username: String
    }

    public struct S3: Codable, Sendable, Equatable {
        public let endpoint: String
        public let region: String
        public let bucket: String
        public let prefix: String
        public let accessKey: String
        public let usesPathStyle: Bool
    }

    public let backend: SyncBackendKind
    public let webDAV: WebDAV?
    public let s3: S3?

    public var targetIdentity: String {
        switch backend {
        case .webDAV:
            return "webdav:\(webDAV?.baseURL ?? "")"
        case .s3:
            return "s3:\(s3?.endpoint ?? ""):\(s3?.bucket ?? ""):\(s3?.prefix ?? "")"
        }
    }

    public var summary: String {
        switch backend {
        case .webDAV:
            return webDAV?.baseURL ?? "WebDAV"
        case .s3:
            guard let s3 else { return "S3" }
            return s3.prefix.isEmpty
                ? "\(s3.bucket) · \(s3.endpoint)"
                : "\(s3.bucket)/\(s3.prefix) · \(s3.endpoint)"
        }
    }

    public func makeObjectStore(
        credentials: SyncCredentials,
        httpClient: any SyncHTTPClient = URLSessionSyncHTTPClient()
    ) throws -> any SyncObjectStore {
        switch backend {
        case .webDAV:
            guard let webDAV, let url = URL(string: webDAV.baseURL),
                  let password = credentials.webDAVPassword else {
                throw SyncObjectStoreError.invalidConfiguration("Incomplete WebDAV configuration.")
            }
            return try WebDAVObjectStore(
                configuration: WebDAVConfiguration(
                    baseURL: url,
                    username: webDAV.username,
                    password: password
                ),
                httpClient: httpClient
            )
        case .s3:
            guard let s3, let endpoint = URL(string: s3.endpoint),
                  let secretKey = credentials.s3SecretKey else {
                throw SyncObjectStoreError.invalidConfiguration("Incomplete S3 configuration.")
            }
            return try S3ObjectStore(
                configuration: S3Configuration(
                    endpoint: endpoint,
                    region: s3.region,
                    bucket: s3.bucket,
                    prefix: s3.prefix,
                    accessKey: s3.accessKey,
                    secretKey: secretKey,
                    usesPathStyle: s3.usesPathStyle
                ),
                httpClient: httpClient
            )
        }
    }
}
