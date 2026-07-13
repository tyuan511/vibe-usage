public enum SyncBackendKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case webDAV
    case s3

    public var id: String { rawValue }
    public var displayName: String { self == .webDAV ? "WebDAV" : "S3" }
}
