import AppKit
import Sparkle

/// Sparkle auto-update. Feed URL, EdDSA public key and the daily check interval are in Info.plist;
/// Scripts/release.sh signs the dmg and attaches appcast.xml to each GitHub Release.
/// Not started in the debug snapshot / keychain-probe modes.
@MainActor final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NotificationCenter.default.post(name: .tokenBarClosePopover, object: nil)
        NSApp.activate()   // LSUIElement app: bring Sparkle's window to the front
        controller?.checkForUpdates(nil)
    }

    // A menu bar app has no Dock icon: let Sparkle remind gently instead of stealing focus.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
