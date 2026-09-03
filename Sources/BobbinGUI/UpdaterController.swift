import AppKit
import Sparkle

/// Owns Bobbin's Sparkle updater for both scheduled and user-initiated checks.
///
/// The feed and EdDSA public key live in the packaged Info.plist. Release ZIPs
/// are signed by `scripts/make-appcast.sh`, so Sparkle rejects any update that
/// was not produced with Combinatrix's existing update-signing key.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
