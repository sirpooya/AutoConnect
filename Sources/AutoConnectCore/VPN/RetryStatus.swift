import Foundation

/// What the panel says while the app is between automatic attempts.
///
/// This exists because "down but still trying" had no state of its own. `Phase.reconnecting`
/// carries a live tunnel, so it only covers openconnect healing a tunnel that is still there;
/// once the tunnel was gone the app fell back to `.failed`, which is a settled state by design:
/// red dot, no shimmer, an error with a dismiss button. The backoff ladder climbs to ten minutes
/// between attempts, and with no network at all nothing is scheduled until the monitor reports a
/// path, so the panel could sit on "Failed" for a quarter of an hour while the app was working.
///
/// The countdown is what makes it legible. The attempt number changes once every thirty to six
/// hundred seconds, so a bare counter looks as frozen as "Failed" did; seconds ticking down are
/// the part that says the app is alive. Pure and here rather than in the view so the wording is
/// tested, the same reason `StatusNotificationPolicy` lives in this module.
public struct RetryStatus: Equatable, Sendable {

    /// The ordinal of the attempt that is coming next, counting the one that just failed as the
    /// first. So the first automatic retry is attempt 2.
    public var attempt: Int

    /// The ladder's budget, `ReconnectPolicy.maxConsecutiveFailures`.
    public var maxAttempts: Int

    /// True when there is no path to attempt over. Nothing is scheduled in that case: the ladder
    /// deliberately holds its count and waits for the network monitor, so there is no deadline to
    /// count down to and claiming one would be a lie.
    public var isWaitingForNetwork: Bool

    /// Why the last attempt ended, shown under the countdown. Optional because a tunnel that
    /// simply stopped does not always say.
    public var reason: String?

    public init(
        attempt: Int,
        maxAttempts: Int,
        isWaitingForNetwork: Bool = false,
        reason: String? = nil
    ) {
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.isWaitingForNetwork = isWaitingForNetwork
        self.reason = reason
    }

    /// The status line, in place of `Phase.label`.
    ///
    /// `remaining` is seconds until the next attempt, or nil when none is scheduled. Offline wins
    /// over any number: it is both the honest description and the useful one, since it names the
    /// thing the user can actually fix.
    public func statusText(remaining: TimeInterval?) -> String {
        if isWaitingForNetwork { return "Waiting for network" }
        guard let remaining else { return "Retrying soon" }
        if remaining <= 0 { return "Retrying now" }
        return "Retrying in \(Self.clock(remaining))"
    }

    /// The line under it. The reason is appended rather than given a row of its own: the panel is
    /// 320pt wide, and the failure and the plan for it are one piece of news.
    public var detailText: String {
        let count = "Attempt \(attempt) of \(maxAttempts)"
        guard let reason, !reason.isEmpty else { return count }
        return "\(count) · \(reason)"
    }

    /// `m:ss`, rounded up so the countdown reaches 0:01 rather than resting a second on 0:00.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
