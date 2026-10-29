import Foundation
import Sparkle

class UpdateChecker: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateChecker()
    static let updateAvailableNotification = Notification.Name("UpdateAvailable")

    private var updaterController: SPUStandardUpdaterController!
    private(set) var availableVersion: String?
    /// Set once Sparkle has downloaded an update and staged it to install on quit.
    /// Calling it installs immediately and relaunches the app, with no Sparkle UI.
    private var immediateInstall: (() -> Void)?

    var updateAvailable: Bool {
        availableVersion != nil
    }

    /// True when the update is downloaded and can be installed with one click.
    var isReadyToInstall: Bool {
        immediateInstall != nil
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

    /// Install and relaunch now if the update is already downloaded; otherwise fall back to
    /// Sparkle's standard flow (e.g. when the user turned off automatic downloads).
    func installUpdate() {
        if let install = immediateInstall {
            install()
        } else {
            updater.checkForUpdates()
        }
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        NotificationCenter.default.post(name: Self.updateAvailableNotification, object: self)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        availableVersion = nil
        immediateInstall = nil
    }

    /// Sparkle downloaded the update and will install it on quit. Returning true takes over
    /// from Sparkle's "ready to install" reminder dialog: the menu shows "Restart to Update"
    /// instead, and clicking it calls the handler. If never clicked, it still installs on quit.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        availableVersion = item.displayVersionString
        immediateInstall = immediateInstallHandler
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.updateAvailableNotification, object: self)
        }
        return true
    }
}
