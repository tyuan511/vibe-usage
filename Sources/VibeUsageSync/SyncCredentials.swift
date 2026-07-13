public struct SyncCredentials: Codable, Sendable, Equatable {
    public let webDAVPassword: String?
    public let s3SecretKey: String?

    public init(webDAVPassword: String? = nil, s3SecretKey: String? = nil) {
        self.webDAVPassword = webDAVPassword
        self.s3SecretKey = s3SecretKey
    }
}
