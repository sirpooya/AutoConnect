import Foundation

/// What a status notification says, and when one is worth posting at all.
///
/// The decision is here rather than in the app so it can be tested without a notification centre
/// and without a live tunnel. The delivery half is `VPNStatusNotifier` in the app target.

/// One notifiable moment in a tunnel's life. Coarser than `VPNController.Phase` on purpose: the
/// intermediate steps of a connect are progress, not news, and nobody wants four banners for one
/// Connect click.
public enum VPNStatusEvent: String, Equatable, Sendable, CaseIterable {
    case connected
    case disconnected
    case reconnecting
    /// The app is rebuilding the session on purpose, because the gateway's twelve hours are up.
    ///
    /// Distinct from `reconnecting`, which is a tunnel that dropped on its own. This one is the
    /// app's own decision, and it used to pass in silence on the grounds that nothing about the
    /// connection had changed. It had: the tunnel really is down for the seconds a renewal takes,
    /// and a gap nobody was told about reads as a fault rather than as maintenance.
    case renewing
    case failed
}

/// Whether the user wants to hear about status changes at all.
///
/// One switch, off by default. An app that starts posting banners the first time it is launched
/// is an app people turn off, and the menu bar icon already carries the state for anyone who
/// wants to look. There is no switch per kind: the moments this covers (up, down, in trouble, and
/// the session being rebuilt) are the same question asked several times, and nobody wants to be
/// told about some of them and not the rest.
public struct NotificationPreferences: Equatable, Sendable {
    /// The only switch. With this off nothing is posted and no authorization is ever requested.
    public var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    /// Whether this event is wanted. Every notifiable event is, once the switch is on.
    public func wants(_ event: VPNStatusEvent) -> Bool { isEnabled }
}

/// A banner ready to be posted.
public struct StatusNotification: Equatable, Sendable {
    public let event: VPNStatusEvent
    public let title: String
    public let body: String

    /// Notifications are posted under this, so a newer one about the same tunnel replaces the
    /// last rather than stacking four dead banners in Notification Centre.
    public static let identifier = "autoconnect.vpn.status"

    public init(event: VPNStatusEvent, title: String, body: String) {
        self.event = event
        self.title = title
        self.body = body
    }
}

/// Decides which transitions deserve a banner, and what it says.
public enum StatusNotificationPolicy {

    /// How long a `reconnecting` waits before it is worth saying out loud.
    ///
    /// openconnect's own dead-peer detection can drop and rebuild a tunnel in under half a
    /// second. Both halves of that pair are banners, and every banner is posted under one
    /// identifier so the newest replaces the last, so the connect overwrote the reconnect before
    /// it had finished sliding onto the screen: what the user saw was "VPN connected" out of
    /// nowhere, with nothing on screen to say what it had reconnected from. A drop the tunnel
    /// settles by itself inside this window is not news either way, so neither half is announced.
    ///
    /// Long enough to cover a self-heal, short enough that a real outage is still reported while
    /// the user is wondering why nothing loads.
    public static let reconnectingHold: TimeInterval = 3

    /// How long this event should be held back, in case the tunnel answers it first, or nil to
    /// announce it at once.
    ///
    /// Only `reconnecting` waits. `renewing` is the app's own decision and takes a full sign-in to
    /// carry out, so there is nothing for a wait to resolve, and the rest are settled states.
    public static func hold(before event: VPNStatusEvent) -> TimeInterval? {
        event == .reconnecting ? reconnectingHold : nil
    }

    /// The banner for a transition, or nil when this one should pass in silence.
    ///
    /// - Parameters:
    ///   - previous: the last event announced, or nil at launch.
    ///   - current: the event just reached.
    ///   - gateway: the connection's display name, so a machine with two of them says which.
    ///   - detail: the assigned IP for a connect, or the reason for a drop or a failure.
    public static func notification(
        from previous: VPNStatusEvent?,
        to current: VPNStatusEvent,
        gateway: String,
        detail: String? = nil,
        preferences: NotificationPreferences
    ) -> StatusNotification? {
        guard preferences.wants(current) else { return nil }

        // The same event twice running is not news. openconnect's own retries can pass through
        // reconnecting more than once, and a failed connect that is retried lands on failed again.
        guard current != previous else { return nil }

        // Nothing has happened yet at launch, and the app starts disconnected. Announcing that
        // would mean a banner every login saying the VPN is off, which it always is.
        if previous == nil, current != .connected { return nil }

        let trimmedGateway = gateway.trimmingCharacters(in: .whitespaces)
        let named = trimmedGateway.isEmpty ? "the VPN" : trimmedGateway

        // An empty detail is the same as none: openconnect sometimes reports a blank reason.
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = (trimmed?.isEmpty ?? true) ? nil : trimmed

        switch current {
        case .connected:
            return StatusNotification(
                event: current,
                title: "VPN connected",
                body: reason.map { "Connected to \(named) as \($0)." }
                    ?? "Connected to \(named)."
            )

        case .disconnected:
            return StatusNotification(
                event: current,
                title: "VPN disconnected",
                body: reason ?? "The tunnel to \(named) is down."
            )

        case .reconnecting:
            return StatusNotification(
                event: current,
                title: "VPN reconnecting",
                body: reason.map { "\($0) Reconnecting to \(named)." }
                    ?? "The tunnel dropped. Reconnecting to \(named)."
            )

        case .renewing:
            return StatusNotification(
                event: current,
                title: "VPN session renewing",
                body: reason.map { "\($0) Renewing the session on \(named)." }
                    ?? "The session on \(named) is expiring. Renewing it now."
            )

        case .failed:
            return StatusNotification(
                event: current,
                title: "VPN connection failed",
                body: reason ?? "Could not connect to \(named)."
            )
        }
    }
}
