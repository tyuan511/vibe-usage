public struct SyncDirtyDay: Sendable, Equatable {
    public let day: String
    public let revision: Int

    public init(day: String, revision: Int) {
        self.day = day
        self.revision = revision
    }
}
