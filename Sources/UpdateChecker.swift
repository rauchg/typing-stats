import Foundation
#if !DEV_BUILD
import Sparkle
#endif

class UpdateChecker: NSObject {
    static let shared = UpdateChecker()
    static let updateAvailableNotification = Notification.Name("UpdateAvailable")

    private(set) var availableVersion: String?

    var updateAvailable: Bool {
        availableVersion != nil
    }

    #if !DEV_BUILD
    private var updaterController: SPUStandardUpdaterController!

    var updater: SPUUpdater {
        updaterController.updater
    }
    #endif

    private override init() {
        super.init()
        #if !DEV_BUILD
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        #endif
    }

    func checkForUpdates() {
        #if !DEV_BUILD
        updater.checkForUpdates()
        #endif
    }

    func installUpdate() {
        #if !DEV_BUILD
        updater.checkForUpdatesInBackground()
        #endif
    }
}

#if !DEV_BUILD
extension UpdateChecker: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        NotificationCenter.default.post(name: Self.updateAvailableNotification, object: self)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        availableVersion = nil
    }
}
#endif
