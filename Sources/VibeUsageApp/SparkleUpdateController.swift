import Combine
import Foundation
import Sparkle

/// Owns Sparkle for the lifetime of the application and bridges its KVO state
/// into SwiftUI. Update archive and feed authenticity are enforced by the
/// EdDSA settings embedded in the app bundle's Info.plist.
@MainActor
final class SparkleUpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool

    private let standardController: SPUStandardUpdaterController
    private var canCheckSubscription: AnyCancellable?

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        standardController = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckSubscription = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
    }

    func checkForUpdates() {
        standardController.updater.checkForUpdates()
    }
}
