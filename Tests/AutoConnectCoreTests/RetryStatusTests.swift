import XCTest

@testable import AutoConnectCore

final class RetryStatusTests: XCTestCase {

    private func status(
        attempt: Int = 2,
        maxAttempts: Int = 6,
        waiting: Bool = false,
        reason: String? = nil
    ) -> RetryStatus {
        RetryStatus(
            attempt: attempt,
            maxAttempts: maxAttempts,
            isWaitingForNetwork: waiting,
            reason: reason
        )
    }

    // MARK: - The countdown

    func testCountsDownInMinutesAndSeconds() {
        XCTAssertEqual(status().statusText(remaining: 24), "Retrying in 0:24")
        XCTAssertEqual(status().statusText(remaining: 60), "Retrying in 1:00")
        XCTAssertEqual(status().statusText(remaining: 95), "Retrying in 1:35")
        // The ceiling of the backoff ladder, so the widest string the row ever has to fit.
        XCTAssertEqual(status().statusText(remaining: 600), "Retrying in 10:00")
    }

    /// Rounded up, so a countdown passes through 0:01 rather than resting a whole second on 0:00
    /// while the attempt has not started.
    func testRoundsPartialSecondsUp() {
        XCTAssertEqual(status().statusText(remaining: 0.2), "Retrying in 0:01")
        XCTAssertEqual(status().statusText(remaining: 23.4), "Retrying in 0:24")
    }

    func testReachingZeroSaysTheAttemptIsStarting() {
        XCTAssertEqual(status().statusText(remaining: 0), "Retrying now")
        // Late by a tick, because the deadline and the ticker are not the same clock.
        XCTAssertEqual(status().statusText(remaining: -3), "Retrying now")
    }

    // MARK: - Offline

    /// The case in the bug report. With no path the ladder deliberately queues nothing, so there
    /// is no deadline; the row must still say the app is alive, and must not invent a number.
    func testWaitingForNetworkNamesTheNetworkAndShowsNoCountdown() {
        XCTAssertEqual(status(waiting: true).statusText(remaining: nil), "Waiting for network")
    }

    /// Offline wins over any number left over from before the path went away.
    func testWaitingForNetworkOutranksAStaleDeadline() {
        XCTAssertEqual(status(waiting: true).statusText(remaining: 42), "Waiting for network")
    }

    func testNoDeadlineAndNoNetworkProblemStillReadsAsWorking() {
        XCTAssertEqual(status().statusText(remaining: nil), "Retrying soon")
    }

    // MARK: - The detail line

    func testDetailCountsTheAttempt() {
        XCTAssertEqual(status(attempt: 3, maxAttempts: 6).detailText, "Attempt 3 of 6")
    }

    func testDetailAppendsTheReason() {
        XCTAssertEqual(
            status(attempt: 2, reason: "The Internet connection appears to be offline.").detailText,
            "Attempt 2 of 6 · The Internet connection appears to be offline."
        )
    }

    /// A tunnel that simply stopped does not always say why, and "Attempt 2 of 6 · " with nothing
    /// after it reads as a truncation.
    func testDetailOmitsAnEmptyReason() {
        XCTAssertEqual(status(attempt: 2, reason: "").detailText, "Attempt 2 of 6")
        XCTAssertEqual(status(attempt: 2, reason: nil).detailText, "Attempt 2 of 6")
    }

    // MARK: - Against the ladder it describes

    /// The attempt numbering has to line up with the give-up message, or the panel counts to five
    /// and the banner says six. Walks the real policy the way the controller does.
    func testAttemptNumbersReachTheLaddersOwnCount() {
        let policy = ReconnectPolicy()
        var consecutiveFailures = 0
        var shown: [Int] = []

        while true {
            let decision = policy.decideAfterFailure(
                consecutiveFailures: consecutiveFailures + 1,
                isNetworkAvailable: true
            )
            if case .giveUp = decision { break }
            consecutiveFailures += 1
            shown.append(consecutiveFailures + 1)
        }

        XCTAssertEqual(shown, [2, 3, 4, 5, 6])
        XCTAssertEqual(shown.last, policy.maxConsecutiveFailures)
    }
}
