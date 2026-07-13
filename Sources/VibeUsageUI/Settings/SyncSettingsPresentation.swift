import Foundation

public struct SyncSettingsPresentation: Equatable {
    public enum Backend: String, CaseIterable, Identifiable {
        case webDAV
        case s3

        public var id: String { rawValue }
        public var displayName: String { self == .webDAV ? "WebDAV" : "S3" }
    }

    public struct ConnectionForm: Equatable {
        public var backend: Backend = .webDAV
        public var webDAVURL = ""
        public var webDAVUsername = ""
        public var webDAVPassword = ""
        public var s3Endpoint = ""
        public var s3Region = "us-east-1"
        public var s3Bucket = ""
        public var s3Prefix = ""
        public var s3AccessKey = ""
        public var s3SecretKey = ""
        public var s3UsesPathStyle = true

        public var targetIdentity: String {
            switch backend {
            case .webDAV:
                return "webdav:\(webDAVURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
            case .s3:
                return "s3:\(s3Endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))):\(s3Bucket):\(s3Prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
            }
        }

        public init() {}
    }

    public struct Device: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let lastSyncedAt: Date?
        public let isLocal: Bool

        public init(id: String, name: String, lastSyncedAt: Date?, isLocal: Bool) {
            self.id = id
            self.name = name
            self.lastSyncedAt = lastSyncedAt
            self.isLocal = isLocal
        }
    }

    public var isEnabled: Bool
    public var form: ConnectionForm
    public var deviceName: String
    public var hiddenDeviceIDs: Set<String>
    public let configuredBackendName: String?
    public let configuredTargetIdentity: String?
    public let configurationSummary: String?
    public let devices: [Device]
    public let isSyncing: Bool
    public let isTestingConnection: Bool
    public let lastSuccessfulAt: Date?
    public let error: String?

    public init(
        isEnabled: Bool,
        form: ConnectionForm,
        deviceName: String,
        hiddenDeviceIDs: Set<String>,
        configuredBackendName: String?,
        configuredTargetIdentity: String?,
        configurationSummary: String?,
        devices: [Device],
        isSyncing: Bool,
        isTestingConnection: Bool,
        lastSuccessfulAt: Date?,
        error: String?
    ) {
        self.isEnabled = isEnabled
        self.form = form
        self.deviceName = deviceName
        self.hiddenDeviceIDs = hiddenDeviceIDs
        self.configuredBackendName = configuredBackendName
        self.configuredTargetIdentity = configuredTargetIdentity
        self.configurationSummary = configurationSummary
        self.devices = devices
        self.isSyncing = isSyncing
        self.isTestingConnection = isTestingConnection
        self.lastSuccessfulAt = lastSuccessfulAt
        self.error = error
    }

    public var hasConfiguration: Bool { configuredTargetIdentity != nil }
}
