import Foundation
import AutoConnectCore
import UserNotifications

/// Posts a banner when the tunnel comes up, goes down, or gets into trouble.
///
/// The menu bar icon is the always-there indicator, so this exists for the case the icon cannot
/// cover: something happened to the VPN while the user was looking at something else. Which
/// transitions are worth a banner, and what each says, is `StatusNotificationPolicy` in
/// `AutoConnectCore`; everything here is delivery and permission.
///
/// Off until switched on in Settings. Nothing is requested from macOS, and no banner is ever
/// posted, while it is off.
@MainActor
final class VPNStatusNotifier: NSObject, ObservableObject {

    /// The only switch. Flipping it on is what asks macOS for permission, so the system prompt
    /// arrives as a direct result of something the user just did.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.enabled)
            if isEnabled {
                requestAuthorization()
            } else {
                authorizationNote = nil
            }
        }
    }

    /// Why banners will not appear even though the switch is on: permission was refused, or this
    /// is an unbundled build. Nil when there is nothing to explain.
    @Published private(set) var authorizationNote: String?

    private enum Key {
        static let enabled = "autoconnect.notifications.enabled"
    }

    private let defaults = UserDefaults.standard

    /// The last event announced, so the same one twice running stays quiet and the launch state
    /// is never announced at all.
    private var lastEvent: VPNStatusEvent?

    /// True for the playground's copy. It reads and writes the same preference, so the switch
    /// looks real, but it never registers with the notification centre and never posts: a mock
    /// must not be able to put a banner about a tunnel on screen.
    private let isPreview: Bool

    /// A notifier for the playground: same switch, no delivery.
    static func preview() -> VPNStatusNotifier { VPNStatusNotifier(isPreview: true) }

    init(isPreview: Bool = false) {
        self.isPreview = isPreview

        isEnabled = defaults.bool(forKey: Key.enabled)

        super.init()

        guard !isPreview else { return }

        guard Self.isBundled else {
            if isEnabled { authorizationNote = Self.unbundledNote }
            return
        }

        // Banners must appear while AutoConnect itself is frontmost too. Settings being open is
        // exactly when someone is testing whether this works.
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization()
    }

    var preferences: NotificationPreferences {
        NotificationPreferences(isEnabled: isEnabled)
    }

    // MARK: - Watching the tunnel

    /// Feeds one phase change in. Called for every phase, including the ones that are progress
    /// rather than news; those are dropped here.
    ///
    /// `isRenewing` is the tunnel coming down on purpose so it can go straight back up. It is
    /// dropped for the same reason the connect steps are: it is not a change in whether the
    /// machine is on the VPN, which is the only thing these banners are about.
    func record(phase: VPNController.Phase, gateway: String, isRenewing: Bool = false) {
        if isRenewing {
            // With one exception: a renewal that ends in a failure means the tunnel did not come
            // back, which is the whole reason someone turns these on.
            guard case .failed = phase else { return }
        }

        guard let (event, detail) = Self.event(for: phase) else { return }

        let banner = StatusNotificationPolicy.notification(
            from: lastEvent,
            to: event,
            gateway: gateway,
            detail: detail,
            preferences: preferences
        )

        // The event is remembered whether or not a banner went out, so turning notifications on
        // mid-session does not immediately fire about a state that has been true for hours.
        lastEvent = event

        guard let banner else { return }
        post(banner)
    }

    /// The notifiable event behind a phase, or nil when the phase is one step of a connect in
    /// progress. Four banners for one Connect click is not a status report.
    private static func event(for phase: VPNController.Phase) -> (VPNStatusEvent, String?)? {
        switch phase {
        case .idle:
            return (.disconnected, nil)
        case .connected(let tunnel):
            return (.connected, tunnel.assignedIP)
        case .reconnecting(_, let reason):
            return (.reconnecting, reason)
        case .failed(let message):
            return (.failed, message)
        case .contactingGateway, .awaitingLogin, .exchangingToken, .startingTunnel:
            return nil
        }
    }

    // MARK: - Delivery

    private func post(_ banner: StatusNotification) {
        guard !isPreview, Self.isBundled else { return }

        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.body = banner.body
        // Silent on purpose: this reports a state change, it does not need answering. The one
        // sound a menu bar app can make should not be about routing.
        content.sound = nil

        // One identifier for every status banner, so the newest replaces the last rather than
        // leaving a stack of dead ones in Notification Centre.
        let request = UNNotificationRequest(
            identifier: StatusNotification.identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.authorizationNote = "Could not post the notification: "
                    + error.localizedDescription
            }
        }
    }

    // MARK: - Permission

    private func requestAuthorization() {
        guard !isPreview else { return }
        guard Self.isBundled else {
            authorizationNote = Self.unbundledNote
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor [weak self] in
                // Not turned back off: the switch records what the user wants, and the note says
                // what is standing in the way. Reverting it would hide the reason.
                self?.authorizationNote = granted ? nil : Self.deniedNote
            }
        }
    }

    /// Re-reads the system's answer, for the case permission was refused once and later allowed
    /// in System Settings. Called at launch and whenever the settings pane opens, so the warning
    /// clears itself instead of outliving the problem.
    func refreshAuthorization() {
        guard !isPreview, isEnabled, Self.isBundled else { return }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                switch status {
                case .denied:
                    self?.authorizationNote = Self.deniedNote
                case .notDetermined:
                    self?.requestAuthorization()
                default:
                    self?.authorizationNote = nil
                }
            }
        }
    }

    private static let deniedNote =
        "macOS is blocking these. Allow AutoConnect in System Settings, Notifications."

    private static let unbundledNote =
        "Notifications need the packaged app. Build it with Scripts/make-app.sh."

    /// Whether this process is a real `.app`.
    ///
    /// `UNUserNotificationCenter.current()` traps outright in a bare executable, which is how the
    /// app runs under `swift run`, so every call into the framework is gated on this.
    private static let isBundled: Bool = {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }()
}

extension VPNStatusNotifier: UNUserNotificationCenterDelegate {

    /// Without this, macOS suppresses a notification posted while its own app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
