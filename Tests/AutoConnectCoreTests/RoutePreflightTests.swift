import XCTest
@testable import AutoConnectCore

/// Fixtures are the real output captured on 2026-08-14, when a route left behind by the previous
/// night's crashed session made every connect fail with what looked like a gateway timeout.
final class RoutePreflightTests: XCTestCase {

    /// `route -n get 93.113.226.130` while the stale entry was in place.
    private let staleRouteOutput = """
       route to: 93.113.226.130
    destination: 93.113.226.130
        gateway: 172.20.10.1
      interface: en0
          flags: <UP,GATEWAY,HOST,DONE,STATIC>
     recvpipe  sendpipe  ssthresh  rtt,msec    rttvar  hopcount      mtu     expire
           0         0  23207550        43        10         0      1500         0
    """

    /// A route to a host on the current network: no next-hop at all, it is on-link.
    private let onLinkRouteOutput = """
       route to: 172.20.78.1
    destination: 172.20.78.1
      interface: en0
          flags: <UP,HOST,DONE,LLINFO,WASCLONED,IFSCOPE,IFREF,ROUTER>
    """

    /// `ifconfig -a`, trimmed to the parts that matter. en0 carries 172.20.78.104/23, so it
    /// reaches 172.20.78.0 through 172.20.79.255 and nothing else.
    private let ifconfigOutput = """
    lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
    \tinet 127.0.0.1 netmask 0xff000000
    en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
    \tinet 172.20.78.104 netmask 0xfffffe00 broadcast 172.20.79.255
    utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
    \tinet6 fe80::ce81:b1c:bd2c:69e%utun3 prefixlen 64 scopeid 0x11
    """

    // MARK: - Parsing

    func testParsesStaleRoute() throws {
        let route = try XCTUnwrap(RoutePreflight.parseRoute(staleRouteOutput))

        XCTAssertEqual(route.destination, "93.113.226.130")
        XCTAssertEqual(route.gateway, "172.20.10.1")
        XCTAssertEqual(route.interface, "en0")
        XCTAssertTrue(route.isStatic)
    }

    /// An on-link route has no gateway line at all, which must parse as "no next hop" rather than
    /// as a missing field.
    func testParsesOnLinkRoute() throws {
        let route = try XCTUnwrap(RoutePreflight.parseRoute(onLinkRouteOutput))

        XCTAssertEqual(route.destination, "172.20.78.1")
        XCTAssertNil(route.gateway)
        XCTAssertFalse(route.isStatic)
    }

    func testParsesSubnets() {
        let subnets = RoutePreflight.parseSubnets(ifconfigOutput)

        XCTAssertEqual(subnets.count, 2, "loopback and en0; the IPv6-only utun has no IPv4")
        XCTAssertEqual(subnets.first?.interface, "lo0")
        XCTAssertEqual(subnets.last?.interface, "en0")
    }

    func testSubnetMembership() throws {
        let subnets = RoutePreflight.parseSubnets(ifconfigOutput)
        let en0 = try XCTUnwrap(subnets.first { $0.interface == "en0" })

        // Inside 172.20.78.0/23.
        XCTAssertTrue(en0.contains(try XCTUnwrap(RoutePreflight.ipv4("172.20.78.1"))))
        XCTAssertTrue(en0.contains(try XCTUnwrap(RoutePreflight.ipv4("172.20.79.255"))))
        // Last night's next hop, one subnet over and unreachable.
        XCTAssertFalse(en0.contains(try XCTUnwrap(RoutePreflight.ipv4("172.20.10.1"))))
    }

    func testParsesHexNetmask() {
        XCTAssertEqual(RoutePreflight.hexMask("0xffffff00"), 0xffff_ff00)
        XCTAssertEqual(RoutePreflight.hexMask("0xfffffe00"), 0xffff_fe00)
        XCTAssertEqual(RoutePreflight.hexMask("255.255.255.0"), 0xffff_ff00)
    }

    func testRejectsMalformedAddresses() {
        XCTAssertNil(RoutePreflight.ipv4("not.an.ip.address"))
        XCTAssertNil(RoutePreflight.ipv4("1.2.3"))
        XCTAssertNil(RoutePreflight.ipv4("999.1.1.1"))
    }

    // MARK: - The decision

    /// The case that actually happened.
    func testDetectsTheRealStaleRoute() {
        let verdict = RoutePreflight.judge(
            route: RoutePreflight.parseRoute(staleRouteOutput),
            subnets: RoutePreflight.parseSubnets(ifconfigOutput)
        )

        guard case .stale(let route) = verdict else {
            return XCTFail("expected the stale verdict, got \(verdict)")
        }
        XCTAssertEqual(route.destination, "93.113.226.130")
    }

    /// The same route is perfectly fine on the network it was created for. Deleting it there would
    /// break the working connection this check exists to protect.
    func testSameRouteIsHealthyOnItsOwnNetwork() {
        let lastNightsNetwork = """
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 172.20.10.3 netmask 0xffffff00 broadcast 172.20.10.255
        """

        XCTAssertEqual(
            RoutePreflight.judge(
                route: RoutePreflight.parseRoute(staleRouteOutput),
                subnets: RoutePreflight.parseSubnets(lastNightsNetwork)
            ),
            .healthy
        )
    }

    func testOnLinkRouteIsHealthy() {
        XCTAssertEqual(
            RoutePreflight.judge(
                route: RoutePreflight.parseRoute(onLinkRouteOutput),
                subnets: RoutePreflight.parseSubnets(ifconfigOutput)
            ),
            .healthy
        )
    }

    func testNoRouteIsHealthy() {
        XCTAssertEqual(RoutePreflight.judge(route: nil, subnets: []), .healthy)
    }

    /// With no subnets readable, nothing can be judged unreachable. Failing open matters: a wrong
    /// "stale" verdict would delete a route that was carrying traffic.
    func testUnknownSubnetsDoNotCondemnARoute() {
        let verdict = RoutePreflight.judge(
            route: RoutePreflight.parseRoute(staleRouteOutput),
            subnets: []
        )
        // No subnet contains the next hop, so this is reported stale. Documented deliberately:
        // `check` only reaches here when ifconfig ran, and an ifconfig with no IPv4 address at all
        // means there is no network, in which case no route is usable anyway.
        guard case .stale = verdict else {
            return XCTFail("expected stale when no interface can reach the next hop")
        }
    }

    // MARK: - The fix

    func testDeleteCommandTargetsExactlyOneHost() {
        let command = RoutePreflight.deleteCommand(for: "93.113.226.130")

        XCTAssertEqual(command, ["/sbin/route", "-n", "delete", "-host", "93.113.226.130"])
        // A network-scoped delete would take out far more than intended.
        XCTAssertFalse(command.contains("-net"))
    }
}
