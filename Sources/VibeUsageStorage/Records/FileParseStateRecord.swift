import Foundation
import GRDB
import VibeUsageCore

struct FileParseStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "file_parse_state"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var filePath: String
    var sourceId: String
    var byteOffset: Int64
    var lineIndex: Int
    var fileSizeAtParse: Int64
    var fileMtimeAtParse: Date?
    /// Base64-encoded `ParseCheckpoint.adapterState`, so arbitrary adapter-private
    /// bytes can round-trip through a TEXT column regardless of their content.
    var adapterStateJson: String?
    var updatedAt: Date

    init(
        filePath: String,
        sourceID: AgentSourceID,
        checkpoint: ParseCheckpoint,
        fileSizeAtParse: Int64,
        fileMtimeAtParse: Date?,
        updatedAt: Date = Date()
    ) {
        self.filePath = filePath
        self.sourceId = sourceID.rawValue
        self.byteOffset = checkpoint.byteOffset
        self.lineIndex = checkpoint.lineIndex
        self.fileSizeAtParse = fileSizeAtParse
        self.fileMtimeAtParse = fileMtimeAtParse
        self.adapterStateJson = checkpoint.adapterState?.base64EncodedString()
        self.updatedAt = updatedAt
    }

    func toMetadata() -> FileParseMetadata {
        FileParseMetadata(
            checkpoint: ParseCheckpoint(
                byteOffset: byteOffset,
                lineIndex: lineIndex,
                adapterState: adapterStateJson.flatMap { Data(base64Encoded: $0) }
            ),
            fileSizeAtParse: fileSizeAtParse,
            fileModifiedAtParse: fileMtimeAtParse
        )
    }
}
