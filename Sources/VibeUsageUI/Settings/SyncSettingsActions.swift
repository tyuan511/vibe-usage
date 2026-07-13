public struct SyncSettingsActions {
    public let testAndSave: () async -> Bool
    public let syncNow: () -> Void
    public let deleteRemoteDevice: (String) -> Void
    public let removeConfiguration: () -> Void

    public init(
        testAndSave: @escaping () async -> Bool,
        syncNow: @escaping () -> Void,
        deleteRemoteDevice: @escaping (String) -> Void,
        removeConfiguration: @escaping () -> Void
    ) {
        self.testAndSave = testAndSave
        self.syncNow = syncNow
        self.deleteRemoteDevice = deleteRemoteDevice
        self.removeConfiguration = removeConfiguration
    }
}
