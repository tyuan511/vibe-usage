public struct SyncDayReference: Sendable, Codable, Equatable {
    public let day: String
    public let checksum: String

    public init(day: String, checksum: String) {
        self.day = day
        self.checksum = checksum
    }
}
