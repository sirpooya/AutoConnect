import Foundation
import MacAuthCore

/// Drives the whole connect sequence and owns the VPN's observable state.
///
/// The four steps, in order:
/// 1. `GatewayClient.requestAuthentication()` asks the gateway how to log in.
/// 2. `SAMLLoginController` logs in in our own webview and returns the SAML token.
/// 3. `GatewayClient.completeAuthentication()` trades that token for a session token.
/// 4. `OpenConnectRunner.connect()` hands the session token to openconnect over stdin.
@MainActor
final class VPNController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case contactingGateway
        case awaitingLogin
        case exchangingToken
        case startingTunnel
        case connected(OpenConnectRunner.Tunnel)
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .contactingGateway, .awaitingLogin, .exchangingToken, .startingTunnel:
                return true
            default:
                return false
            }
        }

        var label: String {
            switch self {
            case .idle: return "Not connected"
            case .contactingGateway: return "Contacting gateway..."
            case .awaitingLogin: return "Waiting for sign-in..."
            case .exchangingToken: return "Authenticating..."
            case .startingTunnel: return "Starting tunnel..."
            case .connected: return "Connected"
            case .failed: return "Failed"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published var profile: VPNProfile

    /// Ticks while connected so the expiry countdown stays live.
    @Published private(set) var now = Date()

    private var runner: OpenConnectRunner?
    private var connectTask: Task<Void, Never>?
    private var login: SAMLLoginController?
    private var clockTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private let statsReader = TunnelStatsReader()

    init(profile: VPNProfile = .digikalaMFA) {
        self.profile = profile
    }

    /// Builds a controller parked in a fixed phase, for the playground and for previews.
    ///
    /// Nothing is started: no gateway call, no process, no clock. `referenceDate` pins `now` so a
    /// countdown renders deterministically instead of drifting while the window is open.
    static func preview(
        phase: Phase,
        profile: VPNProfile = .digikalaMFA,
        referenceDate: Date = Date()
    ) -> VPNController {
        let controller = VPNController(profile: profile)
        controller.phase = phase
        controller.now = referenceDate
        return controller
    }

    // MARK: - Derived display values

    var tunnel: OpenConnectRunner.Tunnel? {
        if case .connected(let tunnel) = phase { return tunnel }
        return nil
    }

    /// Time left before the gateway forces a re-authentication, as "11h 52m".
    var timeRemaining: String? {
        guard let expiry = tunnel?.sessionExpiry else { return nil }
        let seconds = Int(expiry.timeIntervalSince(now))
        guard seconds > 0 else { return "expired" }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// How long the tunnel has been up, as "2h 14m" or "6m".
    var uptime: String? {
        guard let start = tunnel?.connectedAt else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(start)))

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// Protocol and cipher as one line, for example "DTLS1.2 / AES-256-CBC".
    var transportSummary: String? {
        guard let tunnel else { return nil }
        let transport = tunnel.transport ?? (tunnel.usingDTLS ? "DTLS" : nil)
        guard let transport else { return nil }

        if let cipher = tunnel.cipher { return "\(transport) / \(cipher)" }
        return transport
    }

    // MARK: - Connect

    func connect() {
        guard connectTask == nil, !isConnected else { return }

        connectTask = Task { [weak self] in
            // The sign-in window takes focus, which would otherwise dismiss the transient panel
            // before the user could see the result.
            await PanelPin.pinned {
                await self?.runConnectSequence()
            }
            self?.connectTask = nil
        }
    }

    private func runConnectSequence() async {
        do {
            try OpenConnectRunner.verifyBinary(at: profile.openconnectPath)

            // Step 1.
            phase = .contactingGateway
            let client = GatewayClient(profile: profile)
            let authRequest = try await client.requestAuthentication()

            // Step 2.
            phase = .awaitingLogin
            let login = SAMLLoginController(authRequest: authRequest, profile: profile)
            self.login = login
            let ssoToken = try await login.obtainSSOToken()
            self.login = nil

            // Step 3.
            phase = .exchangingToken
            let complete = try await client.completeAuthentication(
                authRequest: authRequest,
                ssoToken: ssoToken
            )

            // Step 4. The gateway states its own fingerprint; cross-check it against the pin so
            // a gateway cannot talk us into trusting a certificate we did not expect.
            if let pinned = profile.normalizedCertificateSHA1,
               complete.serverCertHash.uppercased() != pinned
            {
                phase = .failed(
                    "The gateway reported certificate \(complete.serverCertHash), "
                        + "which does not match the pinned fingerprint. Refusing to connect."
                )
                return
            }

            phase = .startingTunnel
            try startTunnel(
                sessionToken: complete.sessionToken,
                serverCertHash: complete.serverCertHash
            )
        } catch let error as SAMLLoginController.LoginError {
            // Backing out of the login window is not a failure worth shouting about.
            if case .cancelled = error {
                phase = .idle
            } else {
                phase = .failed(error.errorDescription ?? "\(error)")
            }
        } catch let error as GatewayClient.ClientError {
            phase = .failed(error.description)
        } catch let error as OpenConnectRunner.RunnerError {
            phase = .failed(error.description)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func startTunnel(sessionToken: String, serverCertHash: String) throws {
        let runner = OpenConnectRunner(profile: profile)
        self.runner = runner

        runner.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.apply(runnerState: state)
            }
        }

        try runner.connect(sessionToken: sessionToken, serverCertHash: serverCertHash)
    }

    private func apply(runnerState state: OpenConnectRunner.State) {
        switch state {
        case .disconnected:
            phase = .idle
            stopClock()
        case .connecting:
            phase = .startingTunnel
        case .connected(let tunnel):
            phase = .connected(tunnel)
            startClock()
        case .failed(let message):
            phase = .failed(message)
            stopClock()
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        runner?.disconnect()
        runner = nil
        stopClock()
        phase = .idle
    }

    func clearError() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Clock

    private func startClock() {
        guard clockTask == nil else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.now = Date()
            }
        }
    }

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
        setStatsPolling(false)
    }

    // MARK: - Statistics

    /// Sampling counters means spawning `netstat`, so it only runs while the statistics block is
    /// actually on screen. The view turns this on and off as it appears and disappears.
    func setStatsPolling(_ enabled: Bool) {
        guard enabled else {
            statsTask?.cancel()
            statsTask = nil
            statsReader.reset()
            return
        }

        guard statsTask == nil, isConnected else { return }

        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleStats()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func sampleStats() {
        guard case .connected(var tunnel) = phase else { return }

        // Fall back to the assigned address's interface when openconnect did not name one.
        let interface = tunnel.interface ?? Self.interfaceOwning(address: tunnel.assignedIP)
        guard let interface else { return }

        tunnel.interface = interface
        guard let stats = statsReader.sample(interface: interface) else { return }

        tunnel.stats = stats
        now = Date()
        phase = .connected(tunnel)
    }

    /// Finds which `utun` device carries a given address, so stats work even when openconnect's
    /// output did not mention the device name.
    private static func interfaceOwning(address: String?) -> String? {
        guard let address else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return nil }

        var current: String?
        for line in output.split(separator: "\n") {
            if !line.hasPrefix("\t"), let name = line.split(separator: ":").first {
                current = String(name)
            }
            if line.contains(" \(address) ") || line.hasSuffix(" \(address)") {
                if let current, current.hasPrefix("utun") { return current }
            }
        }

        return nil
    }
}
