import Foundation

/// Spawns and supervises the `openconnect` process, and turns its chatter into state.
///
/// openconnect needs root to create the `utun` device, so it is launched through `sudo`. The
/// session token goes in on stdin (`--cookie-on-stdin`) rather than as an argument, so it never
/// appears in the process list.
public final class OpenConnectRunner {

    public enum State: Equatable {
        case disconnected
        case connecting
        case connected(Tunnel)
        /// The tunnel exists but is not carrying traffic, and openconnect is retrying by itself.
        /// Distinct from `connected` so the UI never claims a working connection that is not.
        case reconnecting(Tunnel, reason: String?)
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .connecting, .reconnecting: return true
            default: return false
            }
        }

        public var tunnel: Tunnel? {
            switch self {
            case .connected(let tunnel): return tunnel
            case .reconnecting(let tunnel, _): return tunnel
            default: return nil
            }
        }
    }

    /// What the app can tell the user about a live tunnel.
    public struct Tunnel: Equatable {
        public var assignedIP: String?
        public var usingDTLS: Bool
        /// When the gateway will force a re-authentication, parsed from openconnect's own line.
        public var sessionExpiry: Date?
        /// The gateway endpoint actually reached, as `93.113.226.130:28015`. This is the closest
        /// thing to "what am I connected to": a VPN carries whole packets, so there is no
        /// per-request URL to report.
        public var gatewayEndpoint: String?
        /// Negotiated protocol version, for example `DTLS1.2` or `TLS1.2`.
        public var transport: String?
        /// Negotiated bulk cipher, for example `AES-256-CBC`.
        public var cipher: String?
        /// When the tunnel came up, for the uptime readout.
        public var connectedAt: Date?
        /// Traffic counters, refreshed by `TunnelStatsReader` while connected.
        public var stats: TunnelStats?

        /// Interface name, so stats can be sampled from the right device.
        public var interface: String?

        /// Full negotiated ciphersuite, as openconnect reports it. `cipher` above is just the bulk
        /// cipher, which is what fits on one line; this is the whole thing for the details block.
        public var ciphersuite: String?

        /// Routes openconnect added through the tunnel.
        public var securedRouteCount = 0
        /// Routes openconnect was told to keep off the tunnel.
        public var excludedRouteCount = 0
        /// True once the default route points into the tunnel, meaning all traffic is carried.
        public var carriesDefaultRoute = false

        /// How traffic is split, in the vocabulary AnyConnect uses for the same thing.
        public var tunnelMode: String? {
            if carriesDefaultRoute {
                return excludedRouteCount > 0 ? "Split Exclude" : "Full tunnel"
            }
            guard securedRouteCount > 0 else { return nil }
            return "Split Include"
        }

        /// Route counts as one line, for example "12 secured, 1 excluded".
        public var routeSummary: String? {
            guard securedRouteCount > 0 || excludedRouteCount > 0 else { return nil }
            var parts = ["\(securedRouteCount) secured"]
            if excludedRouteCount > 0 { parts.append("\(excludedRouteCount) excluded") }
            return parts.joined(separator: ", ")
        }

        public init(
            assignedIP: String? = nil,
            usingDTLS: Bool = false,
            sessionExpiry: Date? = nil,
            gatewayEndpoint: String? = nil,
            transport: String? = nil,
            cipher: String? = nil,
            connectedAt: Date? = nil,
            stats: TunnelStats? = nil,
            interface: String? = nil
        ) {
            self.assignedIP = assignedIP
            self.usingDTLS = usingDTLS
            self.sessionExpiry = sessionExpiry
            self.gatewayEndpoint = gatewayEndpoint
            self.transport = transport
            self.cipher = cipher
            self.connectedAt = connectedAt
            self.stats = stats
            self.interface = interface
        }
    }

    public enum RunnerError: Error, CustomStringConvertible {
        case binaryMissing(String)
        case alreadyRunning
        case launchFailed(String)

        public var description: String {
            switch self {
            case .binaryMissing(let path):
                return """
                    openconnect was not found at \(path). \
                    Install it with: brew install openconnect
                    """
            case .alreadyRunning:
                return "A VPN connection is already running."
            case .launchFailed(let detail):
                return "Could not start openconnect: \(detail)"
            }
        }
    }

    // MARK: - Output parsing

    /// Recognises the lines that matter in openconnect's output. Pure, so the whole state
    /// machine is testable without ever launching a process.
    public enum OutputEvent: Equatable {
        case assignedAddress(String)
        case dtlsEstablished
        case sessionExpiry(Date)
        case certificateRejected
        case authenticationFailed
        case connected
        case disconnected
        /// The gateway endpoint reached, as host:port.
        case gatewayEndpoint(String)
        /// Dead peer detection fired: the tunnel is up on paper but carrying nothing. openconnect
        /// starts retrying on its own from here.
        case peerDead
        /// One of openconnect's own reconnect attempts failed. Carries its reason.
        case reconnectAttemptFailed(String)
        /// openconnect exhausted its retry window and is giving up.
        case reconnectFailed
        /// Negotiated protocol version, bulk cipher, and the full suite string.
        case ciphersuite(transport: String, cipher: String, suite: String = "")
        /// The tunnel device openconnect configured, so stats read the right interface.
        case interface(String)
        /// A route was added through the tunnel. True when it is the default route.
        case routeAdded(isDefault: Bool)
        /// A route was deliberately kept off the tunnel.
        case routeExcluded

        /// openconnect prints expiry as RFC 1123 with a numeric zone, for example
        /// `Fri, 14 Aug 2026 10:30:25 +0330`.
        private static let expiryFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
            return formatter
        }()

        public static func parse(line: String) -> OutputEvent? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // "Configured as 10.250.232.188, with SSL connected and DTLS connected"
            if trimmed.hasPrefix("Configured as ") {
                let remainder = trimmed.dropFirst("Configured as ".count)
                let address = remainder
                    .prefix { $0 != "," && !$0.isWhitespace }
                    .trimmingCharacters(in: .whitespaces)
                return address.isEmpty ? nil : .assignedAddress(address)
            }

            if trimmed.hasPrefix("Established DTLS connection") {
                return .dtlsEstablished
            }

            // "Connected to 93.113.226.130:28015"
            if trimmed.hasPrefix("Connected to "), trimmed.contains(":") {
                let endpoint = trimmed
                    .dropFirst("Connected to ".count)
                    .trimmingCharacters(in: .whitespaces)
                // Distinguish the endpoint line from "Connected to HTTPS on <host> with ...".
                if !endpoint.contains(" ") {
                    return .gatewayEndpoint(endpoint)
                }
            }

            // "... Ciphersuite (DTLS1.2)-(DHE-CUSTOM)-(AES-256-CBC)-(SHA1)."
            if let range = trimmed.range(of: "Ciphersuite ") {
                let suite = String(trimmed[range.upperBound...])
                let parts = suite
                    .split(whereSeparator: { $0 == "(" || $0 == ")" })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-. ")) }
                    .filter { !$0.isEmpty }

                let transport = parts.first ?? ""
                // The bulk cipher is the part naming a block or stream cipher.
                let cipher = parts.first {
                    $0.contains("AES") || $0.contains("CHACHA") || $0.contains("CAMELLIA")
                } ?? ""

                if !transport.isEmpty {
                    // Everything after the protocol version, joined the way AnyConnect prints it,
                    // so the details block can show the whole negotiated suite.
                    let suite = parts.dropFirst().joined(separator: "_")
                    return .ciphersuite(transport: transport, cipher: cipher, suite: suite)
                }
            }

            // "add net 10.250.232.0: gateway 10.250.232.188" and "add net default: gateway ...".
            // A failed re-add ("...: File exists") is not a new route, so it must not be counted.
            if trimmed.hasPrefix("add net "), !trimmed.hasSuffix("File exists"),
               !trimmed.contains("Network is unreachable")
            {
                return .routeAdded(isDefault: trimmed.hasPrefix("add net default"))
            }

            // "ignoring non-forwardable exclude route 0.0.0.0/32"
            if trimmed.contains("exclude route") {
                return .routeExcluded
            }

            // "Configured tun device 'utun6'" or openconnect's "Using tun device utun6"
            if let range = trimmed.range(of: "tun device") {
                let name = String(trimmed[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                if name.hasPrefix("utun") {
                    return .interface(name)
                }
            }

            // "Session authentication will expire at Fri, 14 Aug 2026 10:30:25 +0330"
            if let range = trimmed.range(of: "Session authentication will expire at ") {
                let raw = String(trimmed[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if let date = expiryFormatter.date(from: raw) {
                    return .sessionExpiry(date)
                }
                return nil
            }

            // "DTLS Dead Peer Detection detected dead peer!" and the CSTP equivalent. The tunnel
            // is nominally up but carrying nothing, which is what a closed laptop lid produces.
            if trimmed.contains("Dead Peer Detection detected dead peer") {
                return .peerDead
            }

            // "Reconnect failed" / "CSTP reconnect failed; exiting". Checked before the
            // per-attempt line, since both contain "reconnect failed".
            if trimmed.hasPrefix("Reconnect failed") || trimmed.contains("reconnect failed;") {
                return .reconnectFailed
            }

            // "Failed to reconnect to host mfa-vpn...: Can't assign requested address"
            if trimmed.hasPrefix("Failed to reconnect to host") {
                let reason = trimmed.components(separatedBy: ": ").last ?? trimmed
                return .reconnectAttemptFailed(reason)
            }

            if trimmed.contains("Server certificate verify failed") {
                return .certificateRejected
            }

            if trimmed.contains("Login failed")
                || trimmed.contains("Cookie was rejected")
                || trimmed.contains("Failed to complete authentication")
            {
                return .authenticationFailed
            }

            if trimmed.hasPrefix("CSTP connected") {
                return .connected
            }

            if trimmed.contains("Sent Disconnect") || trimmed.hasPrefix("Disconnected") {
                return .disconnected
            }

            return nil
        }
    }

    // MARK: - Arguments

    /// Path of the pid file this app's openconnect writes.
    ///
    /// It doubles as a signature: the path appears in the process command line, so shutdown can
    /// target *only* the process this app started. That matters because a user may well have
    /// their own openconnect running in a terminal, and killing by the name "openconnect" would
    /// take that down too. Never widen this to a bare process-name match.
    public static let pidFilePath = "/tmp/macauth-openconnect.pid"

    /// The exact argument list used to bring up a tunnel. Built separately from the launch so it
    /// can be asserted on in tests, and so it is reviewable without running anything.
    ///
    /// Deliberately impersonates AnyConnect: some gateways reject unknown clients.
    public static func arguments(
        profile: VPNProfile,
        serverCertHash: String,
        clientVersion: String = ConfigAuth.defaultClientVersion
    ) -> [String] {
        var arguments = [
            profile.openconnectPath,
            "--useragent", "AnyConnect Linux_64 \(clientVersion)",
            "--version-string", clientVersion,
            "--cookie-on-stdin",
            "--servercert", serverCertHash,
            "--pid-file", pidFilePath,
            // openconnect's own retry window. Its default of 300s is too long: after sleep the
            // physical interface has gone, so every attempt fails with "Can't assign requested
            // address" and the user waits five minutes watching it fail. Capping it at 30s lets a
            // brief blip be recovered cheaply by openconnect (which keeps the existing session),
            // while a real outage escalates quickly to a fresh login, which is what actually works.
            "--reconnect-timeout", "30",
        ]

        if let script = profile.vpncScriptPath {
            arguments += ["--script", script]
        }

        arguments.append("https://\(profile.host)/")
        return arguments
    }

    /// Shutdown command. Matches on the pid-file path, which only this app's process carries.
    public static func shutdownArguments() -> [String] {
        ["/usr/bin/pkill", "-INT", "-f", pidFilePath]
    }

    /// Whether the binary the profile points at actually exists and can be run.
    public static func verifyBinary(at path: String) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw RunnerError.binaryMissing(path)
        }
    }

    // MARK: - Lifecycle

    /// Called on the main actor whenever the state changes.
    public var onStateChange: (@Sendable (State) -> Void)?

    private let profile: VPNProfile
    private var process: Process?
    private var tunnel = Tunnel()

    public private(set) var state: State = .disconnected {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    public init(profile: VPNProfile) {
        self.profile = profile
    }

    /// Brings up the tunnel. `sessionToken` is written to stdin and not retained.
    ///
    /// Requires a passwordless sudo rule for the openconnect binary, otherwise sudo will block
    /// waiting for a password that no one can type.
    public func connect(sessionToken: String, serverCertHash: String) throws {
        guard process == nil else { throw RunnerError.alreadyRunning }
        try Self.verifyBinary(at: profile.openconnectPath)

        tunnel = Tunnel()
        state = .connecting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n"] + Self.arguments(
            profile: profile,
            serverCertHash: serverCertHash
        )

        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                self?.handle(line: String(line))
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }

        do {
            try process.run()
        } catch {
            state = .failed(RunnerError.launchFailed(error.localizedDescription).description)
            throw RunnerError.launchFailed(error.localizedDescription)
        }

        self.process = process

        // openconnect reads the cookie from stdin, then expects the pipe to close.
        input.fileHandleForWriting.write(Data((sessionToken + "\n").utf8))
        try? input.fileHandleForWriting.close()
    }

    /// Tears the tunnel down. openconnect runs as root, so the signal has to come from sudo too.
    ///
    /// Scoped to this app's own process via the pid-file marker, so an openconnect the user
    /// started themselves is left alone.
    public func disconnect() {
        guard let process, process.isRunning else {
            state = .disconnected
            return
        }

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        kill.arguments = ["-n"] + Self.shutdownArguments()
        try? kill.run()
        kill.waitUntilExit()
    }

    // MARK: - Internals

    private func handle(line: String) {
        guard let event = OutputEvent.parse(line: line) else { return }

        switch event {
        case .assignedAddress(let address):
            tunnel.assignedIP = address
            if tunnel.connectedAt == nil { tunnel.connectedAt = Date() }
            state = .connected(tunnel)

        case .dtlsEstablished:
            tunnel.usingDTLS = true
            if case .connected = state { state = .connected(tunnel) }

        case .sessionExpiry(let date):
            tunnel.sessionExpiry = date
            if case .connected = state { state = .connected(tunnel) }

        case .gatewayEndpoint(let endpoint):
            tunnel.gatewayEndpoint = endpoint
            if case .connected = state { state = .connected(tunnel) }

        case .ciphersuite(let transport, let cipher, let suite):
            tunnel.transport = transport
            if !cipher.isEmpty { tunnel.cipher = cipher }
            if !suite.isEmpty { tunnel.ciphersuite = suite }
            if case .connected = state { state = .connected(tunnel) }

        case .routeAdded(let isDefault):
            tunnel.securedRouteCount += 1
            if isDefault { tunnel.carriesDefaultRoute = true }
            if case .connected = state { state = .connected(tunnel) }

        case .routeExcluded:
            tunnel.excludedRouteCount += 1
            if case .connected = state { state = .connected(tunnel) }

        case .interface(let name):
            tunnel.interface = name
            if case .connected = state { state = .connected(tunnel) }

        case .connected:
            if tunnel.connectedAt == nil { tunnel.connectedAt = Date() }
            state = .connected(tunnel)

        case .peerDead:
            // Keep the tunnel details so the UI can still show what it was, but stop calling it
            // connected: from here nothing is getting through.
            state = .reconnecting(tunnel, reason: nil)

        case .reconnectAttemptFailed(let reason):
            state = .reconnecting(tunnel, reason: reason)

        case .reconnectFailed:
            state = .failed(
                "The tunnel dropped and could not be re-established. This usually follows sleep "
                    + "or a network change; connecting again starts a fresh session."
            )

        case .certificateRejected:
            state = .failed("The gateway certificate did not match the pinned fingerprint.")

        case .authenticationFailed:
            state = .failed("The gateway rejected the session token. Try logging in again.")

        case .disconnected:
            state = .disconnected
        }
    }

    private func handleTermination() {
        process = nil

        // A clean exit after being connected is a normal disconnect; anything else is a failure
        // worth showing, but only if we have not already recorded a more specific reason.
        switch state {
        case .failed:
            break
        default:
            state = .disconnected
        }
    }
}
