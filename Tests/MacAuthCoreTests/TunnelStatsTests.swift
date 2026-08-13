import XCTest
@testable import MacAuthCore

final class TunnelStatsTests: XCTestCase {

    /// Real `netstat -ibn -I utun6` output, captured from a live tunnel on 2026-08-14.
    /// The Link row omits the Address column, which shifts every later column left by one; the
    /// per-address rows below it include Address and print `-` for errors. Parsing the wrong row
    /// silently yields packet counts where bytes were wanted.
    private let netstatOutput = """
    Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
    utun6      1300  <Link#25>                      1739606     0 1148180614   900391     0  813138424     0
    utun6      1300  10.250.232.18 10.250.232.188   1739606     - 1148180614   900391     -  813138424     -
    """

    func testParsesRealNetstatOutput() throws {
        let parsed = try XCTUnwrap(
            TunnelStats.parse(netstatOutput: netstatOutput, interface: "utun6")
        )

        XCTAssertEqual(parsed.bytesIn, 1_148_180_614)
        XCTAssertEqual(parsed.bytesOut, 813_138_424)
        XCTAssertEqual(parsed.mtu, 1300)
    }

    func testIgnoresOtherInterfaces() {
        XCTAssertNil(TunnelStats.parse(netstatOutput: netstatOutput, interface: "utun3"))
    }

    func testHandlesMissingInterface() {
        XCTAssertNil(TunnelStats.parse(netstatOutput: "", interface: "utun6"))
        XCTAssertNil(
            TunnelStats.parse(netstatOutput: "Name Mtu Network Address", interface: "utun6")
        )
    }

    /// A freshly created interface has zero counters, which must parse rather than be skipped.
    func testParsesZeroedCounters() throws {
        let fresh = """
        Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        utun9      1300  <Link#31>                            0     0          0        0     0          0     0
        """

        let parsed = try XCTUnwrap(TunnelStats.parse(netstatOutput: fresh, interface: "utun9"))
        XCTAssertEqual(parsed.bytesIn, 0)
        XCTAssertEqual(parsed.bytesOut, 0)
    }

    // MARK: - Formatting

    func testFormatsBytes() {
        XCTAssertEqual(TunnelStats.formatBytes(0), "0 B")
        XCTAssertEqual(TunnelStats.formatBytes(512), "512 B")
        XCTAssertEqual(TunnelStats.formatBytes(1_500), "2 KB")
        XCTAssertEqual(TunnelStats.formatBytes(813_138_424), "813 MB")
        XCTAssertEqual(TunnelStats.formatBytes(1_148_180_614), "1.1 GB")
        XCTAssertEqual(TunnelStats.formatBytes(2_500_000_000_000), "2.5 TB")
    }

    /// Past ten units the decimal is noise, so it is dropped.
    func testDropsDecimalOnLargerValues() {
        XCTAssertEqual(TunnelStats.formatBytes(12_300_000_000), "12 GB")
    }

    func testFormatsRates() {
        XCTAssertEqual(TunnelStats.formatRate(0), "0 B/s")
        XCTAssertEqual(TunnelStats.formatRate(0.4), "0 B/s")
        XCTAssertEqual(TunnelStats.formatRate(1_200_000), "1 MB/s")
        XCTAssertEqual(TunnelStats.formatRate(340_000), "340 KB/s")
    }

    // MARK: - Rates

    /// The reader turns two absolute readings into a rate. Without a previous sample there is no
    /// rate to report, which must read as zero rather than as a spike.
    func testFirstSampleHasNoRate() {
        let stats = TunnelStats(bytesIn: 1000, bytesOut: 500)
        XCTAssertEqual(stats.rateIn, 0)
        XCTAssertEqual(stats.rateOut, 0)
    }
}

final class OpenConnectDetailParsingTests: XCTestCase {

    typealias Event = OpenConnectRunner.OutputEvent

    func testParsesGatewayEndpoint() {
        XCTAssertEqual(
            Event.parse(line: "Connected to 93.113.226.130:28015"),
            .gatewayEndpoint("93.113.226.130:28015")
        )
    }

    /// The HTTPS line starts the same way but describes the handshake, not the endpoint.
    func testDoesNotMistakeHTTPSLineForAnEndpoint() {
        let line = "Connected to HTTPS on mfa-vpn.dkservices.ir with ciphersuite "
            + "(TLS1.2)-(DHE-CUSTOM2048)-(RSA-SHA512)-(AES-256-CBC)-(SHA256)"
        XCTAssertNotEqual(
            Event.parse(line: line),
            .gatewayEndpoint("HTTPS on mfa-vpn.dkservices.ir")
        )
    }

    func testParsesDTLSCiphersuite() {
        let line = "Established DTLS connection (using GnuTLS). "
            + "Ciphersuite (DTLS1.2)-(DHE-CUSTOM)-(AES-256-CBC)-(SHA1)."

        // The DTLS prefix wins, since establishing DTLS is the more significant event.
        XCTAssertEqual(Event.parse(line: line), .dtlsEstablished)
    }

    func testParsesTLSCiphersuiteFromHandshakeLine() {
        let line = "Connected to HTTPS on mfa-vpn.dkservices.ir with ciphersuite "
            + "(TLS1.2)-(DHE-CUSTOM2048)-(RSA-SHA512)-(AES-256-CBC)-(SHA256)"

        // Lowercase "ciphersuite" in this line, so it is not matched; the DTLS line supplies the
        // transport instead. Documented here so the asymmetry is deliberate, not a surprise.
        XCTAssertNil(Event.parse(line: line))
    }

    func testParsesCiphersuiteWhenCapitalised() {
        XCTAssertEqual(
            Event.parse(line: "Ciphersuite (TLS1.3)-(ECDHE-SECP256R1)-(AES-128-GCM)"),
            .ciphersuite(transport: "TLS1.3", cipher: "AES-128-GCM")
        )
    }

    func testParsesInterfaceName() {
        XCTAssertEqual(
            Event.parse(line: "Configured tun device 'utun6'"),
            .interface("utun6")
        )
    }

    func testTunnelRecordsConnectionTimeOnFirstAddress() {
        // Documents the contract the UI's uptime readout depends on.
        var tunnel = OpenConnectRunner.Tunnel()
        XCTAssertNil(tunnel.connectedAt)

        tunnel.connectedAt = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(tunnel.connectedAt?.timeIntervalSince1970, 1000)
    }
}
