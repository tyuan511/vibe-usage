import Foundation

public enum SyncDocumentError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case invalidDocument(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported sync schema version: \(version)"
        case .invalidDocument(let reason):
            return "Invalid sync document: \(reason)"
        }
    }
}
