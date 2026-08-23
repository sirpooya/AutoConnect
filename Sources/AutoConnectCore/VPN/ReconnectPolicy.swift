import Foundation

/// Decides when a tunnel should be re-established, and refuses to do so in a loop.
///
/// Pure and synchronous, so the awkward cases (a gateway that rejects every attempt, a session
/// that has already expired, a network that flaps) are decided by tested logic rather than by
/// timers firing in the dark. It lives in the core module for exactly that reason: the decisions
/// are the part worth testing, and they must not need a running app to exercise.
public struct ReconnectPolicy {

    public init() {}

    /// How long before the session's hard expiry to renew. The gateway issues twelve hours, so a
    /// five minute lead is ample and keeps the renewal well clear of the cliff.
    public var lead: TimeInterval = 300

    /// Give up after this many consecutive failed attempts, so a gateway that is refusing
    /// outright is not hammered.
    ///
    /// Six rather than three. With the doubling backoff below, three gave up ninety seconds after
    /// the first failure, which is less time than an ordinary Wi-Fi handover or a captive portal
    /// takes, so an outage that cleared itself a minute later had already used the whole budget.
    /// Six reaches about a quarter of an hour, and every rung is now spent on an attempt that was
    /// really made and really did fail.
    public var maxConsecutiveFailures = 6

    /// Wait this long after a failure before trying again, doubling each time.
    public var baseBackoff: TimeInterval = 30

    /// Never wait longer than this between attempts.
    public var maxBackoff: TimeInterval = 600

    /// How long to let a returning network settle before attempting over it.
    ///
    /// A recovering network is reported several times over, as interfaces, addresses and DNS
    /// arrive separately. Attempting on the first of those reaches a path that is up but not yet
    /// usable; collapsing the burst into one attempt a few seconds later does not.
    public var networkSettleDelay: TimeInterval = 3

    public enum Decision: Equatable {
        /// Do nothing for now.
        case wait
        /// Reconnect immediately.
        case reconnectNow
        /// Reconnect after this delay.
        case reconnect(after: TimeInterval)
        /// Stop trying and tell the user.
        case giveUp(reason: String)
    }

    /// What a tunnel that claims to be connected actually looks like right now.
    ///
    /// The claim is openconnect's, and openconnect can be wrong in two directions. Its process can
    /// be gone, which nothing notices on its own for a tunnel adopted from a previous launch: there
    /// is no output handler watching it. And its session can expire underneath a device that is
    /// still up, which is the state that reads as "Connected" beside a countdown saying "expired"
    /// while nothing gets through.
    public enum Health: Equatable {
        /// Nothing to do.
        case healthy
        /// Inside the renewal lead. Still carrying traffic, but the session should be rebuilt now.
        case renewDue
        /// Past the gateway's expiry. The session is over whatever the tunnel device says, and the
        /// routes it still holds are why the machine has no working network at all.
        case expired
        /// openconnect is no longer running, so there is no tunnel behind the state.
        case processGone
    }

    /// Judges a tunnel that is nominally connected, for the watchdog that has to notice the two
    /// ways "connected" goes stale without anything reporting it.
    public func evaluateHealth(expiry: Date?, now: Date, isProcessAlive: Bool) -> Health {
        // First, because with no process there is nothing left to renew whatever the clock says.
        guard isProcessAlive else { return .processGone }
        guard let expiry else { return .healthy }

        let remaining = expiry.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        if remaining <= lead { return .renewDue }
        return .healthy
    }

    /// Should a connected tunnel be renewed yet?
    public func decideRenewal(expiry: Date?, now: Date) -> Decision {
        guard let expiry else { return .wait }

        let remaining = expiry.timeIntervalSince(now)
        if remaining <= 0 { return .reconnectNow }
        if remaining <= lead { return .reconnectNow }

        // Wake up just before the lead window opens.
        return .reconnect(after: remaining - lead)
    }

    /// What to do after a failed attempt.
    ///
    /// `isNetworkAvailable` is what keeps an outage from spending the whole budget. An attempt that
    /// could not leave the machine says nothing about whether the gateway is willing, so with no
    /// path this answers `.wait`: hold the count where it is, and let the network monitor start the
    /// next attempt once there is something to attempt over. Counting those is how a half-minute
    /// drop in the network exhausted every retry before the network was even back.
    public func decideAfterFailure(
        consecutiveFailures: Int,
        isNetworkAvailable: Bool = true
    ) -> Decision {
        guard isNetworkAvailable else { return .wait }

        guard consecutiveFailures < maxConsecutiveFailures else {
            return .giveUp(
                reason: "Reconnecting failed \(consecutiveFailures) times, so automatic retries "
                    + "have stopped. Connect manually when ready."
            )
        }

        // 30s, 60s, 120s, ... capped.
        let exponent = max(0, consecutiveFailures - 1)
        let delay = min(maxBackoff, baseBackoff * pow(2, Double(exponent)))
        return .reconnect(after: delay)
    }

    /// Whether a network change should trigger a reconnect.
    ///
    /// Only when the path is satisfied and the tunnel is down: reconnecting while a healthy tunnel
    /// is up would tear down a working connection for no reason.
    ///
    /// `isAttemptInFlight` is the other half of that. Bringing a tunnel down and up again *is* a
    /// network change, so a renewal's own teardown arrives here as one, with no tunnel up and a
    /// user who has connected before: every condition for starting another attempt on top of the
    /// one already running, which is how a renewal restarts itself until the failure count gives up.
    ///
    /// `isTunnelSelfHealing` is the third. openconnect retries on its own when a peer goes dead,
    /// and those retries usually succeed and keep the same session, so they are worth waiting out.
    /// Taking over from them here was the bug behind automatic retries stopping during a brief
    /// outage: the tunnel was not up, so every report from a recovering network read as a reason to
    /// start an attempt, and the budget ran out while openconnect was quietly fixing it anyway.
    /// When openconnect really does give up it exits, and that arrives as a failure of its own.
    public func shouldReconnectOnNetworkChange(
        isNetworkAvailable: Bool,
        isTunnelUp: Bool,
        wasConnectedBefore: Bool,
        isAttemptInFlight: Bool = false,
        isTunnelSelfHealing: Bool = false
    ) -> Bool {
        isNetworkAvailable
            && !isTunnelUp
            && !isAttemptInFlight
            && !isTunnelSelfHealing
            && wasConnectedBefore
    }
}
