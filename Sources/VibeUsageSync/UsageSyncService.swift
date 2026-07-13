import Foundation
import VibeUsageStorage

public struct UsageSyncResult: Sendable, Equatable {
    public let uploadedDays: Int
    public let downloadedDays: Int
    public let discoveredDevices: Int
    public let completedAt: Date
}

public final class UsageSyncService: Sendable {
    private let usageStore: GRDBUsageEventStore
    private let now: @Sendable () -> Date

    public init(
        usageStore: GRDBUsageEventStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.usageStore = usageStore
        self.now = now
    }

    public func synchronize(
        with objectStore: any SyncObjectStore,
        defaultDeviceName: String
    ) async throws -> UsageSyncResult {
        let localDevice = try usageStore.localDevice(defaultName: defaultDeviceName)
        let completedAt = now()
        let uploadedDays = try await publishLocalChanges(
            device: localDevice,
            completedAt: completedAt,
            objectStore: objectStore
        )
        let pullResult = try await pullRemoteChanges(localDeviceID: localDevice.id, objectStore: objectStore)
        try usageStore.markLocalDeviceSynced(at: completedAt)
        return UsageSyncResult(
            uploadedDays: uploadedDays,
            downloadedDays: pullResult.downloadedDays,
            discoveredDevices: pullResult.discoveredDevices,
            completedAt: completedAt
        )
    }

    public func deleteRemoteDevice(
        _ deviceID: String,
        from objectStore: any SyncObjectStore
    ) async throws {
        let prefix = SyncNamespace.devicePrefix(deviceID: deviceID)
        for object in try await objectStore.list(prefix: prefix) {
            try await objectStore.delete(key: object.key)
        }
        try usageStore.deleteRemoteDevice(deviceID)
    }

    private func publishLocalChanges(
        device: SyncedUsageDevice,
        completedAt: Date,
        objectStore: any SyncObjectStore
    ) async throws -> Int {
        var uploadedDays = 0
        for dirtyDay in try usageStore.dirtySyncDaySnapshots() {
            let storageBuckets = try usageStore.localHourlyBuckets(utcDay: dirtyDay.day)
            let key = SyncNamespace.dayKey(deviceID: device.id, day: dirtyDay.day)
            guard !storageBuckets.isEmpty else {
                try await objectStore.delete(key: key)
                try usageStore.removePublishedDay(dirtyDay.day, expectedRevision: dirtyDay.revision)
                continue
            }
            let document = SyncDayDocument(
                deviceID: device.id,
                day: dirtyDay.day,
                generatedAt: completedAt,
                buckets: storageBuckets.map(Self.syncBucket)
            )
            let data = try SyncDocumentCodec.encode(document)
            let checksum = SyncDocumentCodec.checksum(data)
            try await objectStore.write(key: key, data: data)
            try usageStore.markSyncDayPublished(
                dirtyDay.day,
                checksum: checksum,
                expectedRevision: dirtyDay.revision
            )
            uploadedDays += 1
        }

        let references = try usageStore.publishedDayChecksums()
            .map { SyncDayReference(day: $0.key, checksum: $0.value) }
            .sorted { $0.day < $1.day }
        let index = SyncIndexDocument(
            deviceID: device.id,
            updatedAt: completedAt,
            days: references
        )
        try await objectStore.write(
            key: SyncNamespace.indexKey(deviceID: device.id),
            data: SyncDocumentCodec.encode(index)
        )
        let profile = SyncProfileDocument(
            deviceID: device.id,
            name: device.name,
            lastSyncedAt: completedAt
        )
        try await objectStore.write(
            key: SyncNamespace.profileKey(deviceID: device.id),
            data: SyncDocumentCodec.encode(profile)
        )
        return uploadedDays
    }

    private func pullRemoteChanges(
        localDeviceID: String,
        objectStore: any SyncObjectStore
    ) async throws -> (downloadedDays: Int, discoveredDevices: Int) {
        let objects = try await objectStore.list(prefix: "\(SyncNamespace.root)/devices")
        let remoteDeviceIDs = Set(objects.compactMap(Self.profileDeviceID))
            .subtracting([localDeviceID])
        let cachedRemoteIDs = Set(
            try usageStore.allUsageDevices().filter { !$0.isLocal }.map(\.id)
        )
        for missingID in cachedRemoteIDs.subtracting(remoteDeviceIDs) {
            try usageStore.deleteRemoteDevice(missingID)
        }

        var downloadedDays = 0
        for deviceID in remoteDeviceIDs.sorted() {
            let profileData = try await objectStore.read(
                key: SyncNamespace.profileKey(deviceID: deviceID)
            ).data
            let indexData = try await objectStore.read(
                key: SyncNamespace.indexKey(deviceID: deviceID)
            ).data
            let profile = try SyncDocumentCodec.decodeProfile(profileData)
            let index = try SyncDocumentCodec.decodeIndex(indexData)
            guard profile.deviceID == deviceID, index.deviceID == deviceID else {
                throw SyncDocumentError.invalidDocument("device directory does not match document identity")
            }
            let device = SyncedUsageDevice(
                id: deviceID,
                name: profile.name,
                lastSyncedAt: profile.lastSyncedAt,
                isLocal: false
            )
            try usageStore.updateRemoteDevice(device)
            let existing = try usageStore.remoteDayChecksums(deviceID: deviceID)
            for reference in index.days where existing[reference.day] != reference.checksum {
                let data = try await objectStore.read(
                    key: SyncNamespace.dayKey(deviceID: deviceID, day: reference.day)
                ).data
                guard SyncDocumentCodec.checksum(data) == reference.checksum else {
                    throw SyncDocumentError.invalidDocument("day checksum does not match index")
                }
                let day = try SyncDocumentCodec.decodeDay(data)
                guard day.deviceID == deviceID, day.day == reference.day else {
                    throw SyncDocumentError.invalidDocument("day path does not match document identity")
                }
                try usageStore.replaceRemoteDay(
                    device: device,
                    utcDay: day.day,
                    checksum: reference.checksum,
                    buckets: day.buckets.map { Self.storageBucket($0, deviceID: deviceID) }
                )
                downloadedDays += 1
            }
            try usageStore.removeRemoteDays(
                deviceID: deviceID,
                notIn: Set(index.days.map(\.day))
            )
        }
        return (downloadedDays, remoteDeviceIDs.count)
    }

    private static func profileDeviceID(from object: SyncObjectMetadata) -> String? {
        let prefix = "\(SyncNamespace.root)/devices/"
        guard object.key.hasPrefix(prefix), object.key.hasSuffix("/profile.json") else { return nil }
        let remainder = object.key.dropFirst(prefix.count)
        guard let slash = remainder.firstIndex(of: "/") else { return nil }
        let deviceID = String(remainder[..<slash])
        return SyncNamespace.isValidDeviceID(deviceID) ? deviceID : nil
    }

    private static func syncBucket(_ bucket: SyncedUsageBucket) -> SyncUsageBucket {
        SyncUsageBucket(
            hourUTC: bucket.hourUTC,
            sourceID: bucket.sourceID,
            modelFamily: bucket.modelFamily,
            tokens: bucket.tokens,
            costUSD: bucket.costUSD,
            eventCount: bucket.eventCount,
            estimatedEventCount: bucket.estimatedEventCount
        )
    }

    private static func storageBucket(_ bucket: SyncUsageBucket, deviceID: String) -> SyncedUsageBucket {
        SyncedUsageBucket(
            deviceID: deviceID,
            hourUTC: bucket.hourUTC,
            sourceID: bucket.sourceID,
            modelFamily: bucket.modelFamily,
            tokens: bucket.tokens,
            costUSD: bucket.costUSD,
            eventCount: bucket.eventCount,
            estimatedEventCount: bucket.estimatedEventCount
        )
    }
}
