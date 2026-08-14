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
    case failed
}

/// Which status changes the user wants to hear about.
///
/// Off by default, every one of them. An app that starts posting banners the first time it is
/// launched is an app people turn off, and the menu bar icon already carries the state for anyone
/// who wants to look.
public struct NotificationPreferences: Equatable, Sendable {
    /// The master switch. With this off nothing is posted and no authorization is ever requested.
    public var isEnabled: Bool
    /// Banner when the tunnel comes up.
    public var notifiesOnConnect: Bool
    /// Banner when the tunnel goes down, however it went down.
    public var notifiesOnDisconnect: Bool
    /// Banner when the tunnel is dropping and being re-established, and when a connect fails.
    /// One switch for both because they are the same event to the user: the VPN is in trouble.
    public var notifiesOnProblem: Bool

    public init(
        isEnabled: Bool = false,
        notifiesOnConnect: Bool = true,
        notifiesOnDisconnect: Bool = true,
        notifiesOnProblem: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.notifiesOnConnect = notifiesOnConnect
        self.notifiesOnDisconnect = notifiesOnDisconnect
        self.notifiesOnProblem = notifiesOnProblem
    }

    /// Whether this event is wanted, master switch included.
    public func wants(_ event: VPNStatusEvent) -> Bool {
        guard isEnabled else { return false }
        switch event {
        case .connected: return notifiesOnConnect
        case .disconnected: return notifiesOnDisconnect
        case .reconnecting, .failed: return notifiesOnProblem
        }
    }
}

/// A banner ready to be posted.
public struct StatusNotification: Equatable, Sendable {
    public let event: VPNStatusEvent
    public let title: String
    public let body: String

    /// Notifications are posted under this, so a newer one about the same tunnel replaces the
    /// last rather than stacking four dead banners in Notification Centre.
    public static let identifier = "macauth.vpn.status"

    public init(event: VPNStatusEvent, title: String, body: String) {
        self.event = event
        self.title = title
        self.body = body
    }
}

/// Decides which transitions deserve a banner, and what it says.
public enum StatusNotificationPolicy {

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

        case .failed:
            return StatusNotification(
                event: current,
                title: "VPN connection failed",
                body: reason ?? "Could not connect to \(named)."
            )
        }
    }
}
