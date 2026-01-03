import Foundation
import Sparkle

class UpdateChecker: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateChecker()
    static let updateAvailableNotification = Notification.Name("UpdateAvailable")

    private var updaterController: SPUStandardUpdaterController!
    private(set) var availableVersion: String?

    var updateAvailable: Bool {
        availableVersion != nil
    }

    var updater: SPUUpdater {
        updaterController.updater
    }

    private override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        NotificationCenter.default.post(name: Self.updateAvailableNotification, object: self)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        availableVersion = nil
    }
}
