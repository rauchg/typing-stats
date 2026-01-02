import Foundation
import Sparkle

class UpdateChecker: NSObject {
    static let shared = UpdateChecker()

    private var updaterController: SPUStandardUpdaterController!

    var updater: SPUUpdater {
        updaterController.updater
    }

    private override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
