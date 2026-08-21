import XCTest

@testable import AutoConnectCore

final class ReconnectPolicyTests: XCTestCase {

    private let policy = ReconnectPolicy()
    private let now = Date(timeIntervalSince1970: 1_776_000_000)

    // MARK: - Renewal

    func testNoExpiryMeansNothingToDo() {
        XCTAssertEqual(policy.decideRenewal(expiry: nil, now: now), .wait)
    }

    /// A twelve-hour session should schedule a wake-up just before the lead window, not renew now.
    func testFullSessionSchedulesLateWakeUp() {
        let expiry = now.addingTimeInterval(12 * 3600)

        XCTAssertEqual(
            policy.decideRenewal(expiry: expiry, now: now),
            .reconnect(after: 12 * 3600 - 300)
        )
    }

    func testInsideLeadWindowRenewsImmediately() {
        XCTAssertEqual(
            policy.decideRenewal(expiry: now.addingTimeInterval(299), now: now),
            .reconnectNow
        )
        XCTAssertEqual(
            policy.decideRenewal(expiry: now.addingTimeInterval(300), now: now),
            .reconnectNow
        )
    }

    /// An already-expired session must renew rather than schedule a negative delay, which would
    /// otherwise fire instantly in a loop.
    func testExpiredSessionRenewsImmediately() {
        XCTAssertEqual(
            policy.decideRenewal(expiry: now.addingTimeInterval(-3600), now: now),
            .reconnectNow
        )
    }

    // MARK: - Backoff

    func testBackoffDoubles() {
        XCTAssertEqual(policy.decideAfterFailure(consecutiveFailures: 1), .reconnect(after: 30))
        XCTAssertEqual(policy.decideAfterFailure(consecutiveFailures: 2), .reconnect(after: 60))
    }

    /// The point of a cap: a gateway that is down must not be retried forever.
    func testGivesUpAfterRepeatedFailures() {
        guard case .giveUp(let reason) = policy.decideAfterFailure(consecutiveFailures: 3) else {
            return XCTFail("expected giveUp")
        }
        XCTAssertTrue(reason.contains("Connect manually"), reason)
    }

    func testBackoffIsCapped() {
        var eager = ReconnectPolicy()
        eager.maxConsecutiveFailures = 20
        eager.maxBackoff = 600

        XCTAssertEqual(eager.decideAfterFailure(consecutiveFailures: 15), .reconnect(after: 600))
    }

    // MARK: - Health of a tunnel that claims to be connected

    /// The case this was written for: a session past its expiry while openconnect is still running
    /// and the panel still says "Connected".
    func testExpiredSessionIsNotHealthyEvenWithALiveProcess() {
        XCTAssertEqual(
            policy.evaluateHealth(
                expiry: now.addingTimeInterval(-60),
                now: now,
                isProcessAlive: true
            ),
            .expired
        )
    }

    /// Exactly at expiry counts as expired: the gateway has already stopped honouring it.
    func testExpiryBoundaryCountsAsExpired() {
        XCTAssertEqual(
            policy.evaluateHealth(expiry: now, now: now, isProcessAlive: true),
            .expired
        )
    }

    func testInsideTheLeadIsRenewDue() {
        XCTAssertEqual(
            policy.evaluateHealth(
                expiry: now.addingTimeInterval(120),
                now: now,
                isProcessAlive: true
            ),
            .renewDue
        )
    }

    func testAFullSessionIsHealthy() {
        XCTAssertEqual(
            policy.evaluateHealth(
                expiry: now.addingTimeInterval(11 * 3600),
                now: now,
                isProcessAlive: true
            ),
            .healthy
        )
    }

    /// A missing process is the verdict whatever the clock says: there is nothing left to renew.
    func testAMissingProcessOutranksTheClock() {
        for expiry in [now.addingTimeInterval(11 * 3600), now.addingTimeInterval(-11 * 3600), nil] {
            XCTAssertEqual(
                policy.evaluateHealth(expiry: expiry, now: now, isProcessAlive: false),
                .processGone
            )
        }
    }

    /// A tunnel openconnect never gave an expiry for is healthy while its process lives. Guessing
    /// otherwise would tear down a working connection on no evidence at all.
    func testNoExpiryIsHealthyWhileTheProcessLives() {
        XCTAssertEqual(
            policy.evaluateHealth(expiry: nil, now: now, isProcessAlive: true),
            .healthy
        )
    }

    // MARK: - Network changes

    /// The important negative case: never tear down a healthy tunnel because Wi-Fi blinked.
    func testDoesNotReconnectWhileTunnelIsUp() {
        XCTAssertFalse(
            policy.shouldReconnectOnNetworkChange(
                isNetworkAvailable: true,
                isTunnelUp: true,
                wasConnectedBefore: true
            )
        )
    }

    func testReconnectsWhenNetworkReturnsAndTunnelIsDown() {
        XCTAssertTrue(
            policy.shouldReconnectOnNetworkChange(
                isNetworkAvailable: true,
                isTunnelUp: false,
                wasConnectedBefore: true
            )
        )
    }

    /// Never connect on a network change if the user never connected in the first place: the app
    /// must not dial the VPN on its own initiative.
    func testDoesNotConnectUnbidden() {
        XCTAssertFalse(
            policy.shouldReconnectOnNetworkChange(
                isNetworkAvailable: true,
                isTunnelUp: false,
                wasConnectedBefore: false
            )
        )
    }

    /// A renewal takes the tunnel down and puts it back, and that is itself a network change. It
    /// must not be read as one more reason to start another attempt.
    func testDoesNotReconnectWhileAnAttemptIsAlreadyRunning() {
        XCTAssertFalse(
            policy.shouldReconnectOnNetworkChange(
                isNetworkAvailable: true,
                isTunnelUp: false,
                wasConnectedBefore: true,
                isAttemptInFlight: true
            )
        )
    }

    func testDoesNotReconnectWithoutNetwork() {
        XCTAssertFalse(
            policy.shouldReconnectOnNetworkChange(
                isNetworkAvailable: false,
                isTunnelUp: false,
                wasConnectedBefore: true
            )
        )
    }
}
