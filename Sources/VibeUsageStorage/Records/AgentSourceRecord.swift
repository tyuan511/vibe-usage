import Foundation
import GRDB

struct AgentSourceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agent_source"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var displayName: String
    var firstSeenAt: Date
}
