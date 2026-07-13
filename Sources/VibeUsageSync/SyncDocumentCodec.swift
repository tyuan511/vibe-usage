import CryptoKit
import Foundation

public enum SyncDocumentCodec {
    public static let schemaVersion = 1

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decodeDay(_ data: Data) throws -> SyncDayDocument {
        let document = try decode(SyncDayDocument.self, from: data)
        guard SyncNamespace.isValidDeviceID(document.deviceID), SyncNamespace.isValidDay(document.day) else {
            throw SyncDocumentError.invalidDocument("invalid device ID or UTC day")
        }
        guard document.buckets.allSatisfy({ bucket in
            bucket.hourUTC.hasPrefix(document.day + "T") && ISO8601DateFormatter().date(from: bucket.hourUTC) != nil
        }) else {
            throw SyncDocumentError.invalidDocument("hour bucket is outside the document day")
        }
        return document
    }

    public static func decodeProfile(_ data: Data) throws -> SyncProfileDocument {
        let document = try decode(SyncProfileDocument.self, from: data)
        guard SyncNamespace.isValidDeviceID(document.deviceID),
              !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              document.name.count <= 200 else {
            throw SyncDocumentError.invalidDocument("invalid device profile")
        }
        return document
    }

    public static func decodeIndex(_ data: Data) throws -> SyncIndexDocument {
        let document = try decode(SyncIndexDocument.self, from: data)
        let daySet = Set(document.days.map(\.day))
        guard SyncNamespace.isValidDeviceID(document.deviceID),
              daySet.count == document.days.count,
              document.days.allSatisfy({ SyncNamespace.isValidDay($0.day) && isSHA256($0.checksum) }) else {
            throw SyncDocumentError.invalidDocument("invalid device index")
        }
        return document
    }

    public static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try validateVersion(in: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func validateVersion(in data: Data) throws {
        struct VersionEnvelope: Decodable { let schemaVersion: Int }
        let envelope = try JSONDecoder().decode(VersionEnvelope.self, from: data)
        guard envelope.schemaVersion == schemaVersion else {
            throw SyncDocumentError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}
