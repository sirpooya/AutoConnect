import Foundation

/// Detects and clears the stale host route a crashed tunnel leaves behind.
///
/// openconnect adds a host route to the gateway's own address, pointing at the physical next-hop,
/// so tunnel traffic does not loop back through the tunnel. If the process dies without a clean
/// teardown (a closed laptop lid is enough), that route survives. Move to a different network and
/// its next-hop no longer exists, so every connection to the gateway fails instantly with
/// `Can't assign requested address`, and the honest-looking symptom is a connection timeout.
///
/// This was hit for real on 2026-08-14: a route to `93.113.226.130` via `172.20.10.1` outlived its
/// session, and the next day's network was `172.20.78.0/23`.
public enum RoutePreflight {

    /// One entry from `route -n get <address>`.
    public struct HostRoute: Equatable {
        public var destination: String
        /// Next hop, absent when the destination is directly on-link.
        public var gateway: String?
        public var interface: String?
        public var isStatic: Bool

        public init(
            destination: String,
            gateway: String? = nil,
            interface: String? = nil,
            isStatic: Bool = false
        ) {
            self.destination = destination
            self.gateway = gateway
            self.interface = interface
            self.isStatic = isStatic
        }
    }

    /// An interface's IPv4 address and mask, used to judge whether a next-hop is on-link.
    public struct Subnet: Equatable {
        public var interface: String
        public var address: UInt32
        public var mask: UInt32

        public init(interface: String, address: UInt32, mask: UInt32) {
            self.interface = interface
            self.address = address
            self.mask = mask
        }

        public func contains(_ ip: UInt32) -> Bool {
            (ip & mask) == (address & mask)
        }
    }

    public enum Verdict: Equatable {
        /// Nothing in the way.
        case healthy
        /// A route exists whose next-hop is on no local subnet, so it can never be used.
        case stale(HostRoute)
    }

    // MARK: - Decision

    /// Judges a route against the machine's current subnets.
    ///
    /// Only a route with an unreachable next-hop is called stale. A route that is merely unusual,
    /// or on-link, is left alone: deleting a working route would break the very connection this is
    /// meant to protect.
    public static func judge(route: HostRoute?, subnets: [Subnet]) -> Verdict {
        guard let route, let gateway = route.gateway, let gatewayIP = ipv4(gateway) else {
            return .healthy
        }

        // A next-hop must be directly reachable on some interface, by definition.
        let reachable = subnets.contains { $0.contains(gatewayIP) }
        return reachable ? .healthy : .stale(route)
    }

    // MARK: - Parsing

    /// Parses `route -n get <address>` output.
    public static func parseRoute(_ output: String) -> HostRoute? {
        var fields: [String: String] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1]
        }

        guard let destination = fields["destination"] else { return nil }

        return HostRoute(
            destination: destination,
            gateway: fields["gateway"],
            interface: fields["interface"],
            isStatic: fields["flags"]?.contains("STATIC") ?? false
        )
    }

    /// Parses `ifconfig -a` into the IPv4 subnets currently configured.
    public static func parseSubnets(_ output: String) -> [Subnet] {
        var subnets: [Subnet] = []
        var current = ""

        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)

            // Interface headers start at column zero: "en0: flags=..."
            if !line.hasPrefix("\t"), !line.hasPrefix(" "),
               let name = line.split(separator: ":").first
            {
                current = String(name)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet "), !trimmed.hasPrefix("inet6") else { continue }

            let parts = trimmed.split(separator: " ").map(String.init)
            guard parts.count >= 4,
                  let address = ipv4(parts[1]),
                  let maskIndex = parts.firstIndex(of: "netmask"),
                  maskIndex + 1 < parts.count,
                  let mask = hexMask(parts[maskIndex + 1])
            else {
                continue
            }

            subnets.append(Subnet(interface: current, address: address, mask: mask))
        }

        return subnets
    }

    /// Dotted quad to a 32-bit value.
    public static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }

        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    /// ifconfig prints masks as `0xfffffe00`.
    public static func hexMask(_ text: String) -> UInt32? {
        guard text.hasPrefix("0x") else { return ipv4(text) }
        return UInt32(text.dropFirst(2), radix: 16)
    }

    // MARK: - Live inspection

    /// Looks up the current route to an address and judges it.
    public static func check(address: String) -> Verdict {
        guard let routeOutput = run("/sbin/route", ["-n", "get", address]) else { return .healthy }
        guard let ifconfigOutput = run("/sbin/ifconfig", ["-a"]) else { return .healthy }

        return judge(
            route: parseRoute(routeOutput),
            subnets: parseSubnets(ifconfigOutput)
        )
    }

    /// The command that clears a stale route, for both execution and for telling the user.
    public static func deleteCommand(for destination: String) -> [String] {
        ["/sbin/route", "-n", "delete", "-host", destination]
    }

    /// Deletes a stale route. Needs root, so it goes through `sudo -n`; returns false when no
    /// passwordless rule covers it, which is not a failure worth aborting on. The caller then
    /// tells the user what to run.
    @discardableResult
    public static func clear(_ route: HostRoute) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n"] + deleteCommand(for: route.destination)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8)
    }
}
