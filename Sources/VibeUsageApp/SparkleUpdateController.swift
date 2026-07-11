import Combine
import Foundation
import Sparkle

/// Owns Sparkle for the lifetime of the application and bridges its KVO state
/// into SwiftUI. Update archive and feed authenticity are enforced by the
/// EdDSA settings embedded in the app bundle's Info.plist.
@MainActor
final class SparkleUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates: Bool
    @Published private(set) var availableVersion: String?

    let currentVersion: String

    private lazy var standardController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var canCheckSubscription: AnyCancellable?
    private var updateCheckTimer: Timer?

    override init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        canCheckForUpdates = false
        availableVersion = nil
        super.init()

        canCheckForUpdates = standardController.updater.canCheckForUpdates
        canCheckSubscription = standardController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }

        startBackgroundPolling()
    }

    deinit {
        updateCheckTimer?.invalidate()
    }

    func checkForUpdates() {
        standardController.updater.checkForUpdates()
    }

    private func startBackgroundPolling() {
        DispatchQueue.main.async { [weak self] in
            self?.probeForUpdates()
        }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.probeForUpdates()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateCheckTimer = timer
    }

    private func probeForUpdates() {
        guard canCheckForUpdates else { return }
        standardController.updater.checkForUpdateInformation()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        availableVersion = nil
    }
}
