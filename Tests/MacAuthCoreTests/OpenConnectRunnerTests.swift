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
        let noise = [
            "POST https://MFA-VPN.DKservices.ir:28015/",
            "Connected to 93.113.226.130:28015",
            "SSL negotiation with mfa-vpn.dkservices.ir",
            "Got CONNECT response: HTTP/1.1 200 OK",
            "add net 10.250.232.0: gateway 10.250.232.188",
            "ignoring non-forwardable exclude route 0.0.0.0/32",
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
            profile: .digikalaMFA,
            serverCertHash: "AA46A448019A03FFDAF8803558C9B19CE77B951B"
        )

        XCTAssertEqual(arguments.first, "/opt/homebrew/bin/openconnect")
        XCTAssertEqual(arguments.last, "https://mfa-vpn.dkservices.ir:28015/")
        XCTAssertTrue(arguments.contains("--cookie-on-stdin"))
        XCTAssertTrue(arguments.contains("AnyConnect Linux_64 4.7.00136"))

        let certIndex = try? XCTUnwrap(arguments.firstIndex(of: "--servercert"))
        XCTAssertEqual(arguments[(certIndex ?? 0) + 1], "AA46A448019A03FFDAF8803558C9B19CE77B951B")
    }

    /// The session token must never appear in the argument list, since that is world-readable
    /// through the process table.
    func testArgumentsNeverContainTheSessionToken() {
        let arguments = OpenConnectRunner.arguments(
            profile: .digikalaMFA,
            serverCertHash: "HASH"
        )

        XCTAssertFalse(arguments.contains { $0.contains("--cookie=") })
        XCTAssertTrue(arguments.contains("--cookie-on-stdin"))
    }

    func testArgumentsIncludeVPNCScriptWhenConfigured() {
        let arguments = OpenConnectRunner.arguments(profile: .digikalaMFA, serverCertHash: "H")

        let scriptIndex = try? XCTUnwrap(arguments.firstIndex(of: "--script"))
        XCTAssertEqual(arguments[(scriptIndex ?? 0) + 1], "/opt/homebrew/etc/vpnc/vpnc-script")
    }

    func testArgumentsOmitScriptWhenNotConfigured() {
        var profile = VPNProfile.digikalaMFA
        profile.vpncScriptPath = nil

        let arguments = OpenConnectRunner.arguments(profile: profile, serverCertHash: "H")
        XCTAssertFalse(arguments.contains("--script"))
    }

    /// Safety property: the app must be able to identify its own openconnect process, because a
    /// user may have an unrelated openconnect running in a terminal.
    func testArgumentsCarryThePIDFileMarker() {
        let arguments = OpenConnectRunner.arguments(profile: .digikalaMFA, serverCertHash: "H")

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
            try OpenConnectRunner.verifyBinary(at: VPNProfile.digikalaMFA.openconnectPath)
        )
    }
}
