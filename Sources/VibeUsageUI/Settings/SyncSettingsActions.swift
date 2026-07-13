public struct SyncSettingsActions {
    public let testAndSave: () -> Void
    public let syncNow: () -> Void
    public let deleteRemoteDevice: (String) -> Void
    public let removeConfiguration: () -> Void

    public init(
        testAndSave: @escaping () -> Void,
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
