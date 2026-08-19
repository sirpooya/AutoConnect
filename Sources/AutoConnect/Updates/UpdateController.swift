import AppKit
import Sparkle

/// The one Sparkle updater for the process, and the two rules this app puts around it.
///
/// Sparkle is the only external dependency in the package. It earns that because the app is
/// distributed as a zip attached to a GitHub release: without in-app updates, the only way anyone
/// learns a new version exists is by going back to the releases page, and the only way they
/// install it is by replacing the bundle by hand, which also loses the Keychain prompts the
/// stable signature was there to avoid.
///
/// Two behaviours are specific to this app:
///
/// - **Never interrupt a tunnel.** Installing an update relaunches the app, and quitting takes
///   openconnect down with it (`applicationWillTerminate`). A scheduled check that surfaced an
///   update while the user was working over the VPN would therefore offer a button that drops
///   their connection. Background checks are refused while a tunnel is up or being built; a
///   check the user asked for is not, because they are standing right there and Sparkle asks
///   before it installs anything.
/// - **Foreground for Sparkle's own windows.** The app runs as `.accessory`, which cannot take
///   key focus, so Sparkle's alerts would open behind whatever is in front and refuse the
///   keyboard. The activation policy is claimed through `WindowActivation`, not set directly, so
///   Settings being open at the same time cannot leave the app stuck in the wrong one.
///
/// Nothing here runs under `swift run`. Sparkle reads its feed URL and public key from the
/// bundle's Info.plist, and a bare executable has no Info.plist at all, so `start` does nothing
/// unless this process is a real `.app`. `isAvailable` says so out loud rather than leaving About
/// with a button that silently does nothing.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    /// False until `start` runs, and false forever in an unpackaged build.
    @Published private(set) var isAvailable = false

    /// Sparkle's own answer to "can a check start right now", which is false while one is already
    /// running. The button in About reads it so it disables itself instead of queuing checks.
    @Published private(set) var canCheckForUpdates = false

    /// When the last check finished, whoever started it. Nil until the first one.
    @Published private(set) var lastCheck: Date?

    /// Mirrors Sparkle's own preference. Stored rather than computed so SwiftUI has something to
    /// observe, and written straight back to the updater so the switch and the scheduler cannot
    /// disagree about what was chosen.
    @Published var checksAutomatically = false {
        didSet {
            guard let updater, updater.automaticallyChecksForUpdates != checksAutomatically else {
                return
            }
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    private var updaterController: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { updaterController?.updater }
    private var observations: [NSKeyValueObservation] = []

    /// Asked before every background check. Installed by `start` so the updater never has to know
    /// what a tunnel is, and so a scheduled check cannot fire before the gate is in place.
    private var shouldDeferBackgroundChecks: () -> Bool = { false }

    private override init() {
        super.init()
    }

    /// Starts the scheduled check cycle. Called once, at launch.
    ///
    /// The interval and whether automatic checks are on at all come from `SUScheduledCheckInterval`
    /// and `SUEnableAutomaticChecks` in the Info.plist that `Scripts/make-app.sh` writes.
    func start(deferBackgroundChecks: @escaping () -> Bool) {
        guard updaterController == nil else { return }
        guard Self.isBundled else {
            DiagnosticLog.write("updates: unpackaged build, updater not started")
            return
        }

        shouldDeferBackgroundChecks = deferBackgroundChecks

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        updaterController = controller
        isAvailable = true
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate

        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
                [weak self] updater, _ in
                // Hopped rather than assumed: KVO delivers on whichever thread changed the value,
                // and `assumeIsolated` off the main actor is a trap, not a warning.
                Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
            }
        ]
    }

    /// The explicit "Check Now" in About. Sparkle reports its own result, including "you are up to
    /// date", which is the one case a silent check would leave the user guessing about.
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    /// Whether this process is a real `.app`, and so has the Info.plist keys Sparkle needs.
    /// Same test the notifier uses, for the same reason: `swift run` is not a bundle.
    private static let isBundled: Bool = {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }()
}

// MARK: - SPUUpdaterDelegate

extension UpdateController: SPUUpdaterDelegate {

    /// The gate. Only background checks are refused: `.updatesInBackground` is the scheduled
    /// cycle, and everything else was asked for by the person at the keyboard.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground else { return }

        let busy = MainActor.assumeIsolated { self.shouldDeferBackgroundChecks() }
        guard busy else { return }

        DiagnosticLog.write("updates: background check deferred, tunnel in use")
        throw NSError(
            domain: "com.pooya.AutoConnect.updates",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "AutoConnect does not check for updates while the tunnel is up, "
                    + "because installing one restarts the app and drops the connection."
            ]
        )
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        Task { @MainActor in
            self.lastCheck = updater.lastUpdateCheckDate
        }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdateController: SPUStandardUserDriverDelegate {

    /// Sparkle asks before it puts anything on screen, which is the moment an accessory app has to
    /// become one that can be focused.
    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in WindowActivation.claim() }
    }

    /// Back to a menu bar app. `release` re-derives the policy from the windows still open, so
    /// Settings sitting behind Sparkle's alert keeps the app `.regular` and nothing else does.
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in WindowActivation.release() }
    }
}
