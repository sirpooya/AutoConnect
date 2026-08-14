import XCTest
@testable import MacAuthCore

/// The sample lines here are copied verbatim from the successful connect on 2026-08-13, so the
/// parser is tested against real openconnect output rather than a guess at its format.
final class OpenConnectRunnerTests: XCTestCase {

    typealias Event = OpenConnectRunner.OutputEvent

    func testParsesAssignedAddress() {
        let line = "Configured as 10.250.232.188, with SSL connected and DTLS connected"
        XCTAssertEqual(Event.parse(line: line), .assignedAddress("10.250.232.188"))
    }

    func testParsesAssignedAddressWithoutDTLS() {
        let line = "Configured as 10.250.232.188, with SSL connected and DTLS in progress"
        XCTAssertEqual(Event.parse(line: line), .assignedAddress("10.250.232.188"))
    }

    func testParsesSessionExpiry() throws {
        let line = "Session authentication will expire at Fri, 14 Aug 2026 10:30:25 +0330"

        guard case .sessionExpiry(let date) = try XCTUnwrap(Event.parse(line: line)) else {
            return XCTFail("expected a sessionExpiry event")
        }

        // 10:30:25 at +0330 is 07:00:25 UTC.
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 14
        components.hour = 7
        components.minute = 0
        components.second = 25
        components.timeZone = TimeZone(identifier: "UTC")

        let expected = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
        XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testParsesDTLSEstablished() {
        let line = "Established DTLS connection (using GnuTLS). "
            + "Ciphersuite (DTLS1.2)-(DHE-CUSTOM)-(AES-256-CBC)-(SHA1)."
        XCTAssertEqual(Event.parse(line: line), .dtlsEstablished)
    }

    func testParsesCSTPConnected() {
        XCTAssertEqual(Event.parse(line: "CSTP connected. DPD 30, Keepalive 20"), .connected)
    }

    func testParsesCertificateRejection() {
        XCTAssertEqual(
            Event.parse(line: "Server certificate verify failed: signer not found"),
            .certificateRejected
        )
    }

    func testParsesAuthenticationFailure() {
        XCTAssertEqual(Event.parse(line: "Login failed."), .authenticationFailed)
        XCTAssertEqual(Event.parse(line: "Cookie was rejected by server; exiting."), .authenticationFailed)
        XCTAssertEqual(Event.parse(line: "Failed to complete authentication"), .authenticationFailed)
    }

    /// Route and DNS chatter, and the harmless vpnc-script noise, must not be mistaken for state.
    func testIgnoresIrrelevantLines() {
        // "Connected to <ip>:<port>" is deliberately absent: it is now parsed as the gateway
        // endpoint. See OpenConnectDetailParsingTests.
        let noise = [
            "POST https://MFA-VPN.DKservices.ir:28015/",
            "SSL negotiation with mfa-vpn.dkservices.ir",
            "Got CONNECT response: HTTP/1.1 200 OK",
            " is not a recognized network service.",
            "** Error: The parameters were not valid.",
            "",
        ]

        for line in noise {
            XCTAssertNil(Event.parse(line: line), "should ignore: \(line)")
        }
    }

    /// A malformed expiry date must yield nothing rather than a wrong date.
    func testUnparseableExpiryIsIgnored() {
        XCTAssertNil(Event.parse(line: "Session authentication will expire at soon-ish"))
    }

    // MARK: - Argument construction

    func testArgumentsImpersonateAnyConnectAndPinTheCertificate() {
        let arguments = OpenConnectRunner.arguments(
            profile: .example,
            serverCertHash: "AA46A448019A03FFDAF8803558C9B19CE77B951B"
        )

        XCTAssertEqual(arguments.first, "/opt/homebrew/bin/openconnect")
        XCTAssertEqual(arguments.last, "https://vpn.example.com:443/")
        XCTAssertTrue(arguments.contains("--cookie-on-stdin"))
        XCTAssertTrue(arguments.contains("AnyConnect Linux_64 4.7.00136"))

        let certIndex = try? XCTUnwrap(arguments.firstIndex(of: "--servercert"))
        XCTAssertEqual(arguments[(certIndex ?? 0) + 1], "AA46A448019A03FFDAF8803558C9B19CE77B951B")
    }

    /// The session token must never appear in the argument list, since that is world-readable
    /// through the process table.
    func testArgumentsNeverContainTheSessionToken() {
        let arguments = OpenConnectRunner.arguments(
            profile: .example,
            serverCertHash: "HASH"
        )

        XCTAssertFalse(arguments.contains { $0.contains("--cookie=") })
        XCTAssertTrue(arguments.contains("--cookie-on-stdin"))
    }

    func testArgumentsIncludeVPNCScriptWhenConfigured() {
        let arguments = OpenConnectRunner.arguments(profile: .example, serverCertHash: "H")

        let scriptIndex = try? XCTUnwrap(arguments.firstIndex(of: "--script"))
        XCTAssertEqual(arguments[(scriptIndex ?? 0) + 1], "/opt/homebrew/etc/vpnc/vpnc-script")
    }

    func testArgumentsOmitScriptWhenNotConfigured() {
        var profile = VPNProfile.example
        profile.vpncScriptPath = nil

        let arguments = OpenConnectRunner.arguments(profile: profile, serverCertHash: "H")
        XCTAssertFalse(arguments.contains("--script"))
    }

    /// Safety property: the app must be able to identify its own openconnect process, because a
    /// user may have an unrelated openconnect running in a terminal.
    func testArgumentsCarryThePIDFileMarker() {
        let arguments = OpenConnectRunner.arguments(profile: .example, serverCertHash: "H")

        let markerIndex = try? XCTUnwrap(arguments.firstIndex(of: "--pid-file"))
        XCTAssertEqual(arguments[(markerIndex ?? 0) + 1], OpenConnectRunner.pidFilePath)
    }

    /// The critical one: shutdown must target this app's marker and never the bare process name,
    /// or it would kill a user's own openconnect session too.
    func testShutdownTargetsOnlyThisAppsProcess() {
        let arguments = OpenConnectRunner.shutdownArguments()

        XCTAssertEqual(arguments, ["/usr/bin/pkill", "-INT", "-f", "/tmp/macauth-openconnect.pid"])

        // A pattern of just "openconnect" would match every openconnect on the machine.
        XCTAssertFalse(arguments.contains("openconnect"))
        XCTAssertTrue(arguments.last?.contains("macauth") == true)
    }

    // MARK: - Losing the tunnel

    /// Lines captured from a real session that died when the laptop lid closed. Before these were
    /// parsed, the UI kept claiming "Connected" for the whole five minutes openconnect spent
    /// failing to reconnect, which is the worst possible thing for a status display to do.
    func testParsesDeadPeerDetection() {
        XCTAssertEqual(
            Event.parse(line: "DTLS Dead Peer Detection detected dead peer!"),
            .peerDead
        )
        XCTAssertEqual(
            Event.parse(line: "CSTP Dead Peer Detection detected dead peer!"),
            .peerDead
        )
    }

    func testParsesFailedReconnectAttemptWithReason() {
        XCTAssertEqual(
            Event.parse(
                line: "Failed to reconnect to host mfa-vpn.dkservices.ir: Can't assign requested address"
            ),
            .reconnectAttemptFailed("Can't assign requested address")
        )
        XCTAssertEqual(
            Event.parse(line: "Failed to reconnect to host mfa-vpn.dkservices.ir: Invalid argument"),
            .reconnectAttemptFailed("Invalid argument")
        )
    }

    /// Both giving-up lines must be distinguished from the per-attempt failures above, or the app
    /// would keep waiting for a process that has already exited.
    func testParsesGivingUp() {
        XCTAssertEqual(Event.parse(line: "Reconnect failed"), .reconnectFailed)
        XCTAssertEqual(Event.parse(line: "CSTP reconnect failed; exiting"), .reconnectFailed)
    }

    /// The routing noise a failed teardown produces must not be mistaken for state.
    func testIgnoresRoutingTeardownNoise() {
        let noise = [
            "route: writing to routing socket: File exists",
            "add host 93.113.226.130: gateway 10.250.232.188: File exists",
            "sleep 10s, remaining timeout 300s",
            "delete net default: gateway 10.250.232.188",
            "route: writing to routing socket: Network is unreachable",
            "add net default: gateway 172.20.10.1: Network is unreachable",
            "delete net 80.75.7.41",
            "route: bad address: ",
            "route: writing to routing socket: not in table",
        ]

        for line in noise {
            XCTAssertNil(Event.parse(line: line), "should ignore: \(line)")
        }
    }

    // MARK: - Tunnel mode

    /// Route lines are how the tunnel's shape is discovered: AnyConnect calls the result
    /// "Tunnel Mode", and this is the only source openconnect gives for it.
    func testParsesRouteAdditions() {
        XCTAssertEqual(
            Event.parse(line: "add net 10.250.232.0: gateway 10.250.232.188"),
            .routeAdded(isDefault: false)
        )
        XCTAssertEqual(
            Event.parse(line: "add net default: gateway 10.250.232.188"),
            .routeAdded(isDefault: true)
        )
        XCTAssertEqual(
            Event.parse(line: "ignoring non-forwardable exclude route 0.0.0.0/32"),
            .routeExcluded
        )
    }

    /// A failed re-add during a reconnect is not a new route. Counting it would inflate the route
    /// total every time the tunnel flapped.
    func testFailedRouteAdditionIsNotCounted() {
        XCTAssertNil(
            Event.parse(line: "add host 93.113.226.130: gateway 10.250.232.188: File exists")
        )
        XCTAssertNil(
            Event.parse(line: "add net default: gateway 172.20.10.1: Network is unreachable")
        )
    }

    /// The vocabulary matches AnyConnect's, so the two can be compared side by side.
    func testTunnelModeDescribesTheSplit() {
        var tunnel = OpenConnectRunner.Tunnel()
        XCTAssertNil(tunnel.tunnelMode, "no routes yet means nothing to claim")

        tunnel.securedRouteCount = 5
        XCTAssertEqual(tunnel.tunnelMode, "Split Include")

        tunnel.carriesDefaultRoute = true
        XCTAssertEqual(tunnel.tunnelMode, "Full tunnel")

        tunnel.excludedRouteCount = 1
        XCTAssertEqual(tunnel.tunnelMode, "Split Exclude")
        XCTAssertEqual(tunnel.routeSummary, "5 secured, 1 excluded")
    }

    /// The retry window is capped well below openconnect's 300s default: after sleep every attempt
    /// fails anyway, and a fresh login is what actually recovers.
    func testCapsOpenConnectInternalRetryWindow() {
        let arguments = OpenConnectRunner.arguments(profile: .example, serverCertHash: "H")

        let index = try? XCTUnwrap(arguments.firstIndex(of: "--reconnect-timeout"))
        XCTAssertEqual(arguments[(index ?? 0) + 1], "30")
    }

    func testMissingBinaryIsReportedWithInstallAdvice() {
        XCTAssertThrowsError(
            try OpenConnectRunner.verifyBinary(at: "/nonexistent/openconnect")
        ) { error in
            let message = (error as? OpenConnectRunner.RunnerError)?.description ?? ""
            XCTAssertTrue(message.contains("brew install openconnect"), message)
        }
    }

    /// The real binary is present on this machine, which the connect path depends on.
    func testInstalledBinaryPasses() {
        XCTAssertNoThrow(
            try OpenConnectRunner.verifyBinary(at: VPNProfile.example.openconnectPath)
        )
    }
}
