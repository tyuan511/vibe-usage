import AppKit
import Foundation
import VibeUsageStorage
import VibeUsageSync
import VibeUsageUI

@MainActor
final class AppSyncController: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            guard !isInitializing else { return }
            preferences.isEnabled = isEnabled
            if isEnabled {
                startTimer()
                syncNow()
            } else {
                stopTimer()
                debounceTask?.cancel()
                retryTask?.cancel()
            }
        }
    }
    @Published var draft: SyncConnectionDraft
    @Published private(set) var configuration: SyncConfiguration?
    @Published private(set) var devices: [SyncedUsageDevice]
    @Published var deviceName: String {
        didSet {
            guard !isInitializing else { return }
            let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            do {
                try usageStore.renameLocalDevice(trimmed)
                reloadDevices()
                scheduleSync()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
    @Published var hiddenDeviceIDs: Set<String> {
        didSet {
            guard !isInitializing else { return }
            defaults.set(Array(hiddenDeviceIDs).sorted(), forKey: Self.hiddenDeviceIDsKey)
            onDataChanged?()
        }
    }
    @Published private(set) var isSyncing = false
    @Published private(set) var isTestingConnection = false
    @Published private(set) var lastSuccessfulSyncAt: Date?
    @Published private(set) var lastError: String?

    var onDataChanged: (() -> Void)?

    var visibleDeviceIDs: Set<String> {
        Set(devices.map(\.id)).subtracting(hiddenDeviceIDs)
    }

    var hasConfiguredTarget: Bool { configuration != nil }

    var settingsPresentation: SyncSettingsPresentation {
        SyncSettingsPresentation(
            isEnabled: isEnabled,
            form: Self.presentationForm(draft),
            deviceName: deviceName,
            hiddenDeviceIDs: hiddenDeviceIDs,
            configuredBackendName: configuration?.backend.displayName,
            configuredTargetIdentity: configuration?.targetIdentity,
            configurationSummary: configuration?.summary,
            devices: devices.map {
                SyncSettingsPresentation.Device(
                    id: $0.id,
                    name: $0.name,
                    lastSyncedAt: $0.lastSyncedAt,
                    isLocal: $0.isLocal
                )
            },
            isSyncing: isSyncing,
            isTestingConnection: isTestingConnection,
            lastSuccessfulAt: lastSuccessfulSyncAt,
            error: lastError
        )
    }

    func apply(_ presentation: SyncSettingsPresentation) {
        draft = Self.syncDraft(presentation.form)
        if deviceName != presentation.deviceName { deviceName = presentation.deviceName }
        if hiddenDeviceIDs != presentation.hiddenDeviceIDs { hiddenDeviceIDs = presentation.hiddenDeviceIDs }
        if isEnabled != presentation.isEnabled { isEnabled = presentation.isEnabled }
    }

    private let usageStore: GRDBUsageEventStore
    private let service: UsageSyncService
    private let preferences: SyncPreferences
    private let credentialStore: any SyncCredentialStoring
    private let httpClient: any SyncHTTPClient
    private let defaults: UserDefaults
    private var timer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var isInitializing = true

    init(
        usageStore: GRDBUsageEventStore,
        preferences: SyncPreferences = SyncPreferences(),
        credentialStore: any SyncCredentialStoring = KeychainSyncCredentialStore(),
        httpClient: any SyncHTTPClient = URLSessionSyncHTTPClient(),
        defaults: UserDefaults = .standard
    ) throws {
        self.usageStore = usageStore
        self.service = UsageSyncService(usageStore: usageStore)
        self.preferences = preferences
        self.credentialStore = credentialStore
        self.httpClient = httpClient
        self.defaults = defaults
        let configuration = preferences.loadConfiguration()
        self.configuration = configuration
        self.draft = SyncConnectionDraft(configuration: configuration, credentials: nil)
        self.hiddenDeviceIDs = Set(defaults.stringArray(forKey: Self.hiddenDeviceIDsKey) ?? [])
        let defaultName = Host.current().localizedName ?? "Mac"
        let localDevice = try usageStore.localDevice(defaultName: defaultName)
        self.deviceName = localDevice.name
        self.devices = try usageStore.allUsageDevices()
        self.lastSuccessfulSyncAt = localDevice.lastSyncedAt
        self.isEnabled = preferences.isEnabled && configuration != nil
        isInitializing = false
        if isEnabled { startTimer() }
    }

    deinit {
        timer?.invalidate()
        debounceTask?.cancel()
        retryTask?.cancel()
    }

    func testAndSaveConfiguration() async -> Bool {
        guard !isTestingConnection else { return false }
        isTestingConnection = true
        lastError = nil
        defer { isTestingConnection = false }
        do {
            var candidate = draft
            if let stored = try credentialStore.load() {
                if candidate.backend == .webDAV, candidate.webDAVPassword.isEmpty {
                    candidate.webDAVPassword = stored.webDAVPassword ?? ""
                }
                if candidate.backend == .s3, candidate.s3SecretKey.isEmpty {
                    candidate.s3SecretKey = stored.s3SecretKey ?? ""
                }
            }
            let resolved = try candidate.resolve()
            let objectStore = try resolved.configuration.makeObjectStore(
                credentials: resolved.credentials,
                httpClient: httpClient
            )
            try await objectStore.validateAccess()
            let targetChanged = configuration?.targetIdentity != resolved.configuration.targetIdentity
            if targetChanged {
                try usageStore.resetPublishedSyncState()
            }
            try credentialStore.save(resolved.credentials)
            try preferences.saveConfiguration(resolved.configuration)
            configuration = resolved.configuration
            draft = SyncConnectionDraft(configuration: resolved.configuration, credentials: nil)
            lastError = nil
            if isEnabled {
                _ = try await synchronizeIfEnabled()
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func syncNow() {
        Task {
            do {
                _ = try await synchronizeIfEnabled()
            } catch {
                // synchronizeIfEnabled already stores the error for settings.
            }
        }
    }

    @discardableResult
    func synchronizeIfEnabled() async throws -> UsageSyncResult? {
        guard isEnabled, !isSyncing else { return nil }
        guard let configuration else {
            let error = SyncObjectStoreError.invalidConfiguration("Configure a sync target before enabling sync.")
            lastError = error.localizedDescription
            throw error
        }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }
        do {
            guard let credentials = try credentialStore.load() else {
                throw SyncObjectStoreError.invalidConfiguration("Sync credentials are missing from Keychain.")
            }
            let objectStore = try configuration.makeObjectStore(credentials: credentials, httpClient: httpClient)
            let result = try await service.synchronize(with: objectStore, defaultDeviceName: deviceName)
            retryAttempt = 0
            retryTask?.cancel()
            lastSuccessfulSyncAt = result.completedAt
            reloadDevices()
            onDataChanged?()
            return result
        } catch {
            lastError = error.localizedDescription
            scheduleRetry()
            throw error
        }
    }

    func scheduleSync() {
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    func deleteRemoteDevice(_ deviceID: String) {
        guard devices.first(where: { $0.id == deviceID })?.isLocal == false else { return }
        Task {
            do {
                guard let configuration, let credentials = try credentialStore.load() else {
                    throw SyncObjectStoreError.invalidConfiguration("Sync is not configured.")
                }
                let objectStore = try configuration.makeObjectStore(credentials: credentials, httpClient: httpClient)
                try await service.deleteRemoteDevice(deviceID, from: objectStore)
                hiddenDeviceIDs.remove(deviceID)
                reloadDevices()
                onDataChanged?()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeLocalConfiguration() {
        isEnabled = false
        do {
            preferences.clear()
            try credentialStore.clear()
            try usageStore.resetPublishedSyncState()
            try usageStore.clearRemoteUsageCache()
            configuration = nil
            draft = SyncConnectionDraft()
            hiddenDeviceIDs = []
            lastSuccessfulSyncAt = nil
            lastError = nil
            reloadDevices()
            onDataChanged?()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func reloadDevices() {
        do {
            devices = try usageStore.allUsageDevices()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleRetry() {
        guard isEnabled else { return }
        retryTask?.cancel()
        let delays: [Duration] = [.seconds(30), .seconds(120), .seconds(300), .seconds(900)]
        let delay = delays[min(retryAttempt, delays.count - 1)]
        retryAttempt = min(retryAttempt + 1, delays.count - 1)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    private static let hiddenDeviceIDsKey = "hiddenSyncDeviceIDs"

    private static func presentationForm(_ draft: SyncConnectionDraft) -> SyncSettingsPresentation.ConnectionForm {
        var form = SyncSettingsPresentation.ConnectionForm()
        form.backend = draft.backend == .webDAV ? .webDAV : .s3
        form.webDAVURL = draft.webDAVURL
        form.webDAVUsername = draft.webDAVUsername
        form.webDAVPassword = draft.webDAVPassword
        form.s3Endpoint = draft.s3Endpoint
        form.s3Region = draft.s3Region
        form.s3Bucket = draft.s3Bucket
        form.s3Prefix = draft.s3Prefix
        form.s3AccessKey = draft.s3AccessKey
        form.s3SecretKey = draft.s3SecretKey
        form.s3UsesPathStyle = draft.s3UsesPathStyle
        return form
    }

    private static func syncDraft(_ form: SyncSettingsPresentation.ConnectionForm) -> SyncConnectionDraft {
        SyncConnectionDraft(
            backend: form.backend == .webDAV ? .webDAV : .s3,
            webDAVURL: form.webDAVURL,
            webDAVUsername: form.webDAVUsername,
            webDAVPassword: form.webDAVPassword,
            s3Endpoint: form.s3Endpoint,
            s3Region: form.s3Region,
            s3Bucket: form.s3Bucket,
            s3Prefix: form.s3Prefix,
            s3AccessKey: form.s3AccessKey,
            s3SecretKey: form.s3SecretKey,
            s3UsesPathStyle: form.s3UsesPathStyle
        )
    }
}
