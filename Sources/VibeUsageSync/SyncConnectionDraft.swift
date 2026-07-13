import Foundation

public struct SyncConnectionDraft: Sendable, Equatable {
    public struct Resolved: Sendable, Equatable {
        public let configuration: SyncConfiguration
        public let credentials: SyncCredentials
    }

    public var backend: SyncBackendKind
    public var webDAVURL: String
    public var webDAVUsername: String
    public var webDAVPassword: String
    public var s3Endpoint: String
    public var s3Region: String
    public var s3Bucket: String
    public var s3Prefix: String
    public var s3AccessKey: String
    public var s3SecretKey: String
    public var s3UsesPathStyle: Bool

    public init(
        backend: SyncBackendKind = .webDAV,
        webDAVURL: String = "",
        webDAVUsername: String = "",
        webDAVPassword: String = "",
        s3Endpoint: String = "",
        s3Region: String = "us-east-1",
        s3Bucket: String = "",
        s3Prefix: String = "",
        s3AccessKey: String = "",
        s3SecretKey: String = "",
        s3UsesPathStyle: Bool = true
    ) {
        self.backend = backend
        self.webDAVURL = webDAVURL
        self.webDAVUsername = webDAVUsername
        self.webDAVPassword = webDAVPassword
        self.s3Endpoint = s3Endpoint
        self.s3Region = s3Region
        self.s3Bucket = s3Bucket
        self.s3Prefix = s3Prefix
        self.s3AccessKey = s3AccessKey
        self.s3SecretKey = s3SecretKey
        self.s3UsesPathStyle = s3UsesPathStyle
    }

    public init(configuration: SyncConfiguration?, credentials: SyncCredentials?) {
        let credentials = credentials ?? SyncCredentials()
        self.init(
            backend: configuration?.backend ?? .webDAV,
            webDAVURL: configuration?.webDAV?.baseURL ?? "",
            webDAVUsername: configuration?.webDAV?.username ?? "",
            webDAVPassword: credentials.webDAVPassword ?? "",
            s3Endpoint: configuration?.s3?.endpoint ?? "",
            s3Region: configuration?.s3?.region ?? "us-east-1",
            s3Bucket: configuration?.s3?.bucket ?? "",
            s3Prefix: configuration?.s3?.prefix ?? "",
            s3AccessKey: configuration?.s3?.accessKey ?? "",
            s3SecretKey: credentials.s3SecretKey ?? "",
            s3UsesPathStyle: configuration?.s3?.usesPathStyle ?? true
        )
    }

    public func resolve() throws -> Resolved {
        switch backend {
        case .webDAV:
            let url = try secureURL(webDAVURL, field: "WebDAV URL")
            guard !webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !webDAVPassword.isEmpty else {
                throw SyncObjectStoreError.invalidConfiguration("WebDAV username and password are required.")
            }
            return Resolved(
                configuration: SyncConfiguration(
                    backend: .webDAV,
                    webDAV: SyncConfiguration.WebDAV(
                        baseURL: normalized(url),
                        username: webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    s3: nil
                ),
                credentials: SyncCredentials(webDAVPassword: webDAVPassword)
            )
        case .s3:
            let endpoint = try secureURL(s3Endpoint, field: "S3 endpoint")
            let region = s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
            let bucket = s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            let accessKey = s3AccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !region.isEmpty, !bucket.isEmpty, !accessKey.isEmpty, !s3SecretKey.isEmpty else {
                throw SyncObjectStoreError.invalidConfiguration("S3 region, bucket, access key, and secret key are required.")
            }
            return Resolved(
                configuration: SyncConfiguration(
                    backend: .s3,
                    webDAV: nil,
                    s3: SyncConfiguration.S3(
                        endpoint: normalized(endpoint),
                        region: region,
                        bucket: bucket,
                        prefix: s3Prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        accessKey: accessKey,
                        usesPathStyle: s3UsesPathStyle
                    )
                ),
                credentials: SyncCredentials(s3SecretKey: s3SecretKey)
            )
        }
    }

    public var targetIdentity: String {
        switch backend {
        case .webDAV:
            return "webdav:\(webDAVURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        case .s3:
            return "s3:\(s3Endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))):\(s3Bucket):\(s3Prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        }
    }

    private func secureURL(_ value: String, field: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else {
            throw SyncObjectStoreError.invalidConfiguration("\(field) must be a valid HTTPS URL.")
        }
        return url
    }

    private func normalized(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
