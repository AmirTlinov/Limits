import Sparkle

@MainActor
final class SoftwareUpdateController {
    static let shared = SoftwareUpdateController()

    private var updaterController: SPUStandardUpdaterController?

    func start() {
        guard updaterController == nil else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        start()
        updaterController?.checkForUpdates(nil)
    }
}
