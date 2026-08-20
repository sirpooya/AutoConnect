import XCTest

@testable import AutoConnectCore

final class StatusNotificationTests: XCTestCase {

    private let all = NotificationPreferences(isEnabled: true)

    private func notification(
        from previous: VPNStatusEvent?,
        to current: VPNStatusEvent,
        gateway: String = "vpn.example.com",
        detail: String? = nil,
        preferences: NotificationPreferences? = nil
    ) -> StatusNotification? {
        StatusNotificationPolicy.notification(
            from: previous,
            to: current,
            gateway: gateway,
            detail: detail,
            preferences: preferences ?? all
        )
    }

    // MARK: - The switch

    /// Notifications are opt-in, so the default preferences must post nothing at all.
    func testDisabledByDefault() {
        let defaults = NotificationPreferences()
        XCTAssertFalse(defaults.isEnabled)

        for event in VPNStatusEvent.allCases {
            XCTAssertNil(notification(from: .connected, to: event, preferences: defaults))
        }
    }

    /// One switch covers every kind: with it on, each notifiable moment is announced.
    func testEnabledCoversEveryKind() {
        XCTAssertNotNil(notification(from: .disconnected, to: .connected))
        XCTAssertNotNil(notification(from: .connected, to: .disconnected))
        XCTAssertNotNil(notification(from: .connected, to: .reconnecting))
        XCTAssertNotNil(notification(from: .connected, to: .failed))
    }

    // MARK: - Which transitions are news

    /// The app starts disconnected, so announcing that at launch would mean a banner every login
    /// saying the VPN is off, which it always is.
    func testNothingIsAnnouncedForTheLaunchState() {
        XCTAssertNil(notification(from: nil, to: .disconnected))
        XCTAssertNil(notification(from: nil, to: .failed))
        XCTAssertNil(notification(from: nil, to: .reconnecting))
    }

    /// A tunnel already up when the notifier starts watching is still worth one banner.
    func testConnectedIsAnnouncedWithNoPreviousEvent() {
        XCTAssertEqual(notification(from: nil, to: .connected)?.event, .connected)
    }

    /// openconnect's own retries pass through reconnecting repeatedly, and a retried connect fails
    /// again. Neither should produce a second banner.
    func testRepeatedEventIsNotRepeated() {
        XCTAssertNil(notification(from: .reconnecting, to: .reconnecting))
        XCTAssertNil(notification(from: .failed, to: .failed))
        XCTAssertNil(notification(from: .connected, to: .connected))
    }

    // MARK: - Wording

    func testConnectedNamesTheGatewayAndTheAddress() {
        let banner = notification(from: .disconnected, to: .connected, detail: "10.20.30.40")

        XCTAssertEqual(banner?.title, "VPN connected")
        XCTAssertEqual(banner?.body, "Connected to vpn.example.com as 10.20.30.40.")
    }

    func testConnectedWithoutAnAddressStillReads() {
        XCTAssertEqual(
            notification(from: .disconnected, to: .connected)?.body,
            "Connected to vpn.example.com."
        )
    }

    func testFailureUsesTheReasonItWasGiven() {
        let banner = notification(from: .connected, to: .failed,
                                  detail: "The gateway refused the session token.")

        XCTAssertEqual(banner?.title, "VPN connection failed")
        XCTAssertEqual(banner?.body, "The gateway refused the session token.")
    }

    func testReconnectingKeepsTheReasonAndSaysWhereTo() {
        XCTAssertEqual(
            notification(from: .connected, to: .reconnecting, detail: "Dead peer detected.")?.body,
            "Dead peer detected. Reconnecting to vpn.example.com."
        )
    }

    /// openconnect sometimes reports a blank reason, which must not produce a banner with an
    /// empty body.
    func testBlankDetailFallsBackToTheDefaultWording() {
        XCTAssertEqual(
            notification(from: .connected, to: .disconnected, detail: "   \n ")?.body,
            "The tunnel to vpn.example.com is down."
        )
    }

    /// A connection with no name yet still has to read as a sentence.
    func testUnnamedGatewayGetsAGenericName() {
        XCTAssertEqual(
            notification(from: .disconnected, to: .connected, gateway: " ")?.body,
            "Connected to the VPN."
        )
    }

    /// Every banner replaces the last, so a bad afternoon does not leave a stack of dead ones.
    func testOneIdentifierForEveryStatusBanner() {
        XCTAssertEqual(StatusNotification.identifier, "autoconnect.vpn.status")
    }
}
