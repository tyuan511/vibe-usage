import Foundation

public enum VibeUsageError: Error, Sendable, CustomStringConvertible {
    case fileNotReadable(path: String, underlying: String)
    case invalidCheckpoint(path: String, reason: String)
    case pricingDataUnavailable(reason: String)
    case databaseError(underlying: String)

    public var description: String {
        switch self {
        case let .fileNotReadable(path, underlying):
            return "Could not read file at \(path): \(underlying)"
        case let .invalidCheckpoint(path, reason):
            return "Invalid parse checkpoint for \(path): \(reason)"
        case let .pricingDataUnavailable(reason):
            return "Pricing data unavailable: \(reason)"
        case let .databaseError(underlying):
            return "Database error: \(underlying)"
        }
    }
}
