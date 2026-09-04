import Foundation

/// Finds and re-adopts a tunnel that outlived the app.
///
/// openconnect runs as a separate root process, so quitting the app (or rebuilding it) leaves the
/// tunnel up and carrying traffic. Without this, the next launch reports "Not connected" while the
/// machine is very much still on the VPN, which is the most misleading thing a status display can
/// do. It also strands the process: only the pid file could stop it.
///
/// Adoption reads the pid file openconnect maintains, confirms the process is alive, and restores
/// the facts that cannot be recovered from the system (session expiry, the gateway endpoint, the
/// negotiated cipher), which were saved while the tunnel was being watched.
public enum TunnelAdoption {

    /// What was true about the tunnel when the app last saw it. Everything here is descriptive:
    /// no secrets, and nothing that would be wrong to show if it turned out to be stale.
    public struct Snapshot: Codable, Equatable {
        public var profileID: UUID?
        public var assignedIP: String?
        public var interface: String?
        public var gatewayEndpoint: String?
        public var transport: String?
        public var cipher: String?
        public var ciphersuite: String?
        public var sessionExpiry: Date?
        public var connectedAt: Date?
        public var usingDTLS: Bool
        public var securedRouteCount: Int
        public var excludedRouteCount: Int
        public var carriesDefaultRoute: Bool

        public init(
            profileID: UUID? = nil,
            assignedIP: String? = nil,
            interface: String? = nil,
            gatewayEndpoint: String? = nil,
            transport: String? = nil,
            cipher: String? = nil,
            ciphersuite: String? = nil,
            sessionExpiry: Date? = nil,
            connectedAt: Date? = nil,
            usingDTLS: Bool = false,
            securedRouteCount: Int = 0,
            excludedRouteCount: Int = 0,
            carriesDefaultRoute: Bool = false
        ) {
            self.profileID = profileID
            self.assignedIP = assignedIP
            self.interface = interface
            self.gatewayEndpoint = gatewayEndpoint
            self.transport = transport
            self.cipher = cipher
            self.ciphersuite = ciphersuite
            self.sessionExpiry = sessionExpiry
            self.connectedAt = connectedAt
            self.usingDTLS = usingDTLS
            self.securedRouteCount = securedRouteCount
            self.excludedRouteCount = excludedRouteCount
            self.carriesDefaultRoute = carriesDefaultRoute
        }
    }

    private static let defaultsKey = "autoconnect.liveTunnel"

    // MARK: - Recording

    public static func record(_ snapshot: Snapshot, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    public static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    public static func recorded(defaults: UserDefaults = .standard) -> Snapshot? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    // MARK: - The pid file

    /// Reads a pid file's contents. openconnect writes just the number, sometimes with a newline.
    public static func parsePID(_ contents: String) -> Int32? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32(trimmed), value > 1 else { return nil }
        return value
    }

    /// Whether a process with this id exists. Signal 0 asks the question without sending anything.
    ///
    /// A root-owned process can be *queried* by any user, so this needs no privilege; only
    /// signalling it does.
    public static func isRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Parses `ps -o uid= -p <pid>` output.
    public static func parseUID(_ output: String) -> UInt32? {
        UInt32(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether a process is running as root.
    ///
    /// The marker below is matched against a command line, and a command line is not a credential:
    /// anything running on this Mac can put that string in its own `argv` and be adopted as this
    /// app's tunnel. That is worth closing because of what adoption then claims — a green dot and
    /// "Connected" in the menu bar, with no tunnel behind it, which is the most misleading thing a
    /// VPN indicator can say. openconnect needs root to make the `utun` device, so a real tunnel is
    /// always root-owned, and an unprivileged process cannot pretend to be.
    public static func isRootOwned(pid: Int32) -> Bool {
        guard let output = shell("/bin/ps", ["-o", "uid=", "-p", String(pid)]) else { return false }
        return parseUID(output) == 0
    }

    /// The live tunnel this app started, if it is still running.
    ///
    /// Found by matching the marker in the process's command line, not by reading a pid file:
    /// openconnect writes `--pid-file` only when it daemonizes with `-b`, and this app runs it in
    /// the foreground so it can read its output. The marker is in `argv` either way, which is also
    /// exactly what shutdown matches on, so finding and stopping a tunnel use the same handle.
    ///
    /// The match is then confirmed against the one thing `argv` cannot fake: see `isRootOwned`.
    public static func runningPID(marker: String) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // -f matches the whole command line; -n takes the newest if several somehow exist.
        process.arguments = ["-n", "-f", marker]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let pid = parsePID(text),
              isRunning(pid: pid),
              isRootOwned(pid: pid)
        else {
            return nil
        }

        return pid
    }

    // MARK: - Deciding

    public enum Decision: Equatable {
        /// Nothing of ours is running.
        case none
        /// A tunnel is running and these are the facts we remembered about it.
        case adopt(pid: Int32, snapshot: Snapshot?)
        /// A pid file was left behind by a process that is gone.
        case stalePIDFile
    }

    /// Works out whether a tunnel this app started is still running.
    ///
    /// `pidOverride` exists for tests, which cannot spawn a real openconnect.
    public static func decide(
        marker: String,
        defaults: UserDefaults = .standard,
        pidOverride: (() -> Int32?)? = nil
    ) -> Decision {
        let pid = pidOverride?() ?? runningPID(marker: marker)

        guard let pid else {
            // Nothing running. Any remembered tunnel is history, and saying otherwise would show
            // a connection that is not there.
            return recorded(defaults: defaults) == nil ? .none : .stalePIDFile
        }

        return .adopt(pid: pid, snapshot: recorded(defaults: defaults))
    }

    // MARK: - Discovery

    /// Works out which interface and address a running tunnel is using, when nothing was
    /// remembered about it.
    ///
    /// Needed because a tunnel adopted from an older build (or one whose snapshot was lost) would
    /// otherwise show Connected with no statistics at all: the sampler has no interface to read.
    /// The tunnel device is the one carrying the default route, and failing that, the only `utun`
    /// with an IPv4 address.
    public static func discoverTunnel() -> (interface: String, address: String)? {
        if let viaDefault = interfaceCarryingDefaultRoute(),
           viaDefault.hasPrefix("utun"),
           let address = address(of: viaDefault)
        {
            return (viaDefault, address)
        }

        for interface in utunInterfacesWithAddresses() {
            return interface
        }

        return nil
    }

    /// Parses `route -n get default` for its interface.
    public static func parseDefaultInterface(_ routeOutput: String) -> String? {
        for line in routeOutput.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0] == "interface" { return parts[1] }
        }
        return nil
    }

    /// Parses `ifconfig -a` for every `utun` carrying an IPv4 address.
    public static func parseUTunAddresses(_ ifconfigOutput: String) -> [(interface: String, address: String)] {
        var found: [(String, String)] = []
        var current = ""

        for rawLine in ifconfigOutput.split(separator: "\n") {
            let line = String(rawLine)

            if !line.hasPrefix("\t"), !line.hasPrefix(" "),
               let name = line.split(separator: ":").first
            {
                current = String(name)
                continue
            }

            guard current.hasPrefix("utun") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet "), !trimmed.hasPrefix("inet6") else { continue }

            let parts = trimmed.split(separator: " ").map(String.init)
            if parts.count >= 2 { found.append((current, parts[1])) }
        }

        return found
    }

    private static func interfaceCarryingDefaultRoute() -> String? {
        guard let output = shell("/sbin/route", ["-n", "get", "default"]) else { return nil }
        return parseDefaultInterface(output)
    }

    private static func address(of interface: String) -> String? {
        guard let output = shell("/sbin/ifconfig", [interface]) else { return nil }
        return parseUTunAddresses("\(interface): x\n" + output).first?.address
    }

    private static func utunInterfacesWithAddresses() -> [(interface: String, address: String)] {
        guard let output = shell("/sbin/ifconfig", ["-a"]) else { return [] }
        return parseUTunAddresses(output)
    }

    private static func shell(_ path: String, _ arguments: [String]) -> String? {
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

    /// Removes a pid file left by a process that has exited.
    public static func cleanUp(pidFilePath: String) {
        try? FileManager.default.removeItem(atPath: pidFilePath)
    }
}
