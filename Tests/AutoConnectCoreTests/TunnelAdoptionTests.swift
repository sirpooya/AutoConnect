import XCTest
@testable import AutoConnectCore

/// openconnect outlives the app that started it, so a relaunch has to work out whether the machine
/// is still on the VPN. Getting this wrong in either direction is bad: claiming a tunnel that is
/// gone, or reporting "not connected" while traffic is flowing through one.
/// Names the parser under test without exposing a private helper.
private enum RoutePreflightBridge {
    static func defaultInterface(_ output: String) -> String? {
        TunnelAdoption.parseDefaultInterface(output)
    }
}

final class TunnelAdoptionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "autoconnect.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - The pid file

    func testParsesAPIDFile() {
        XCTAssertEqual(TunnelAdoption.parsePID("41173"), 41173)
        XCTAssertEqual(TunnelAdoption.parsePID("41173\n"), 41173)
        XCTAssertEqual(TunnelAdoption.parsePID("  41173  "), 41173)
    }

    /// A truncated or empty pid file must not be read as a process id. Adopting pid 1 would be
    /// especially bad: launchd is always alive, so the app would claim a tunnel forever.
    func testRejectsNonsensePIDs() {
        XCTAssertNil(TunnelAdoption.parsePID(""))
        XCTAssertNil(TunnelAdoption.parsePID("not a pid"))
        XCTAssertNil(TunnelAdoption.parsePID("0"))
        XCTAssertNil(TunnelAdoption.parsePID("1"))
        XCTAssertNil(TunnelAdoption.parsePID("-5"))
    }

    func testRecognisesThisProcessAsRunning() {
        XCTAssertTrue(TunnelAdoption.isRunning(pid: getpid()))
    }

    func testRecognisesADeadProcess() {
        // Above the default pid_max, so it cannot correspond to anything.
        XCTAssertFalse(TunnelAdoption.isRunning(pid: 999_999))
    }

    // MARK: - Deciding

    func testNothingRunningAndNothingRememberedMeansNothingToAdopt() {
        let decision = TunnelAdoption.decide(
            marker: "/tmp/does-not-exist.pid",
            defaults: defaults,
            pidOverride: { nil }
        )

        XCTAssertEqual(decision, .none)
    }

    /// A remembered tunnel whose process is gone must not be adopted, or the app would show a
    /// connection that does not exist and offer to disconnect it.
    func testRememberedTunnelWithNoProcessIsStale() {
        TunnelAdoption.record(TunnelAdoption.Snapshot(assignedIP: "10.0.0.5"), defaults: defaults)

        XCTAssertEqual(
            TunnelAdoption.decide(marker: "marker", defaults: defaults, pidOverride: { nil }),
            .stalePIDFile
        )
    }

    /// The live case, standing in this test process for openconnect.
    func testAdoptsARunningProcessWithItsRememberedFacts() throws {
        let snapshot = TunnelAdoption.Snapshot(
            assignedIP: "10.250.232.182",
            interface: "utun6",
            gatewayEndpoint: "93.113.226.130:28015",
            transport: "DTLS1.2",
            sessionExpiry: Date(timeIntervalSince1970: 1_776_000_000),
            usingDTLS: true
        )
        TunnelAdoption.record(snapshot, defaults: defaults)

        guard case .adopt(let pid, let restored) = TunnelAdoption.decide(
            marker: "marker",
            defaults: defaults,
            pidOverride: { getpid() }
        ) else {
            return XCTFail("expected to adopt the running process")
        }

        XCTAssertEqual(pid, getpid())
        XCTAssertEqual(restored, snapshot)
    }

    /// Adoption must still work with nothing remembered: the tunnel is real either way, and the
    /// missing details are cosmetic.
    func testAdoptsEvenWithoutASnapshot() throws {
        guard case .adopt(_, let restored) = TunnelAdoption.decide(
            marker: "marker",
            defaults: defaults,
            pidOverride: { getpid() }
        ) else {
            return XCTFail("expected to adopt")
        }

        XCTAssertNil(restored)
    }

    // MARK: - Remembering

    func testSnapshotSurvivesARoundTrip() {
        let snapshot = TunnelAdoption.Snapshot(
            profileID: UUID(),
            assignedIP: "10.0.0.5",
            sessionExpiry: Date(timeIntervalSince1970: 1_776_000_000),
            securedRouteCount: 12,
            excludedRouteCount: 1,
            carriesDefaultRoute: true
        )

        TunnelAdoption.record(snapshot, defaults: defaults)
        XCTAssertEqual(TunnelAdoption.recorded(defaults: defaults), snapshot)
    }

    /// Forgetting has to be complete: a leftover record would let a later launch describe a tunnel
    /// that has since been disconnected.
    func testForgetClearsTheRecord() {
        TunnelAdoption.record(TunnelAdoption.Snapshot(assignedIP: "10.0.0.5"), defaults: defaults)
        TunnelAdoption.forget(defaults: defaults)

        XCTAssertNil(TunnelAdoption.recorded(defaults: defaults))
    }

    // MARK: - Discovery

    /// A tunnel adopted with nothing remembered still has to report statistics, so its device and
    /// address are found from the system. Without this the details block sits on "Sampling..."
    /// forever, which is what an adopted tunnel actually did.
    func testFindsTheInterfaceCarryingTheDefaultRoute() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 10.250.232.200
          interface: utun6
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """

        XCTAssertEqual(RoutePreflightBridge.defaultInterface(output), "utun6")
    }

    func testFindsUTunAddresses() {
        let output = """
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 172.20.78.104 netmask 0xfffffe00 broadcast 172.20.79.255
        utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
        \tinet6 fe80::ce81:b1c:bd2c:69e%utun3 prefixlen 64 scopeid 0x11
        utun6: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1300
        \tinet 10.250.232.200 --> 10.250.232.200 netmask 0xffffffff
        """

        let found = TunnelAdoption.parseUTunAddresses(output)

        // en0 is not a tunnel, and utun3 has no IPv4 address, so neither qualifies.
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.interface, "utun6")
        XCTAssertEqual(found.first?.address, "10.250.232.200")
    }

    func testIgnoresAnInterfaceListWithNoTunnels() {
        let output = """
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 172.20.78.104 netmask 0xfffffe00 broadcast 172.20.79.255
        """

        XCTAssertTrue(TunnelAdoption.parseUTunAddresses(output).isEmpty)
    }

    /// Shutting down an adopted tunnel uses the same marker as a normal disconnect, so it can
    /// never reach an openconnect the user started themselves.
    func testAdoptedShutdownUsesTheSameScopedCommand() {
        let arguments = OpenConnectRunner.shutdownArguments()

        XCTAssertTrue(arguments.contains(OpenConnectRunner.pidFilePath))
        XCTAssertFalse(arguments.contains("openconnect"))
    }
}
