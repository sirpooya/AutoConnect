import Foundation
import MacAuthCore
import Network

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

    /// Recent throughput samples, oldest first, for the sparkline. Bounded so it cannot grow
    /// without limit over a twelve-hour session.
    @Published private(set) var history: [ThroughputSample] = []

    /// One moment of throughput, in bytes per second.
    struct ThroughputSample: Equatable, Identifiable {
        let id = UUID()
        var down: Double
        var up: Double
    }

    static let historyLength = 40

    private var runner: OpenConnectRunner?
    private var connectTask: Task<Void, Never>?
    private var login: SAMLLoginController?
    private var clockTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private let statsReader = TunnelStatsReader()

    /// True for controllers built by `preview`. Suppresses anything that would touch the real
    /// machine, so a mock cannot display or disturb a live tunnel.
    private var isPreview = false

    // MARK: Reconnection

    /// Whether automatic reconnection is wanted. Off by default: an app that dials a corporate
    /// VPN unasked is worse than one that waits to be told.
    @Published var autoReconnect = UserDefaults.standard.bool(forKey: "macauth.autoReconnect") {
        didSet {
            UserDefaults.standard.set(autoReconnect, forKey: "macauth.autoReconnect")
            autoReconnect ? scheduleRenewal() : cancelRenewal()
        }
    }

    private let policy = ReconnectPolicy()
    private var renewalTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var consecutiveFailures = 0
    /// True once the user has connected at least once this launch, so a network change can restore
    /// a tunnel they asked for without ever starting one they did not.
    private var userHasConnected = false

    /// Loads the saved profile, falling back to the verified defaults for this project's gateway
    /// so a fresh install is usable before anyone opens Settings.
    init(profile: VPNProfile? = nil) {
        self.profile = profile ?? VPNSettingsStore().loadProfile() ?? .digikalaMFA
    }

    /// Builds a controller parked in a fixed phase, for the playground and for previews.
    ///
    /// Nothing is started: no gateway call, no process, no clock, and crucially no stats polling.
    /// A preview that polled would read whatever `utun` device happens to exist on the machine,
    /// so a mock would silently display the user's real tunnel, and each sample would overwrite
    /// `referenceDate` with the wall clock, turning a "2h" uptime into months.
    static func preview(
        phase: Phase,
        profile: VPNProfile = .digikalaMFA,
        referenceDate: Date = Date()
    ) -> VPNController {
        // Pass the profile explicitly so a preview never picks up saved settings.
        let controller = VPNController(profile: profile)
        controller.isPreview = true
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

        userHasConnected = true
        startNetworkMonitorIfNeeded()

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
            let login = SAMLLoginController(
                authRequest: authRequest,
                profile: profile,
                credentials: autofillCredentials()
            )
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

    /// Gathers what autofill needs, or nil when there is nothing useful to fill.
    ///
    /// The password is read from the Keychain at connect time, and the one-time code is produced
    /// by a closure so it is generated at the instant the field is reached rather than seconds
    /// earlier, when it might already have rolled over.
    private func autofillCredentials() -> LoginFormFiller.Credentials? {
        let settings = VPNSettingsStore()
        let password = settings.password(account: profile.credentialAccount)

        // With no username there is nothing to start from, so let the user drive.
        guard !profile.username.isEmpty else { return nil }

        let otpAccountID = profile.otpAccountID
        let accountStore = KeychainStore()

        return LoginFormFiller.Credentials(
            username: profile.username,
            password: password,
            oneTimeCode: {
                guard let otpAccountID,
                      let account = (try? accountStore.loadAccounts())?
                        .first(where: { $0.id == otpAccountID }),
                      let secret = try? accountStore.secret(for: otpAccountID)
                else {
                    return nil
                }

                return TOTP.generate(
                    secret: secret,
                    algorithm: account.algorithm,
                    digits: account.digits,
                    period: account.period
                )
            }
        )
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
            // A tunnel that dropped on its own is exactly what auto-reconnect is for.
            if autoReconnect, userHasConnected { scheduleRetryAfterFailure() }

        case .connecting:
            phase = .startingTunnel

        case .connected(let tunnel):
            phase = .connected(tunnel)
            consecutiveFailures = 0
            startClock()
            if autoReconnect { scheduleRenewal() }

        case .failed(let message):
            phase = .failed(message)
            stopClock()
            if autoReconnect { scheduleRetryAfterFailure() }
        }
    }

    // MARK: - Reconnection

    /// Schedules a renewal shortly before the gateway's session expires, so a twelve-hour day does
    /// not end with an abrupt disconnection mid-task.
    private func scheduleRenewal() {
        cancelRenewal()
        guard !isPreview, autoReconnect else { return }

        switch policy.decideRenewal(expiry: tunnel?.sessionExpiry, now: Date()) {
        case .wait, .giveUp:
            return
        case .reconnectNow:
            renew()
        case .reconnect(let delay):
            renewalTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.renew()
            }
        }
    }

    private func scheduleRetryAfterFailure() {
        cancelRenewal()
        guard !isPreview else { return }

        consecutiveFailures += 1

        switch policy.decideAfterFailure(consecutiveFailures: consecutiveFailures) {
        case .giveUp(let reason):
            phase = .failed(reason)
            consecutiveFailures = 0
        case .reconnect(let delay):
            renewalTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.renew()
            }
        case .wait, .reconnectNow:
            renew()
        }
    }

    /// Tears down and reconnects. The IdP cookie usually survives in the webview's persistent
    /// store, so this often completes without any typing.
    private func renew() {
        guard autoReconnect, userHasConnected else { return }

        runner?.disconnect()
        runner = nil
        connectTask?.cancel()
        connectTask = nil
        connect()
    }

    private func cancelRenewal() {
        renewalTask?.cancel()
        renewalTask = nil
    }

    /// Watches for the network coming back, so a laptop waking on a different Wi-Fi restores the
    /// tunnel instead of sitting silently disconnected.
    private func startNetworkMonitorIfNeeded() {
        guard pathMonitor == nil, !isPreview else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let shouldReconnect = self.policy.shouldReconnectOnNetworkChange(
                    isNetworkAvailable: path.status == .satisfied,
                    isTunnelUp: self.isConnected,
                    wasConnectedBefore: self.userHasConnected
                )
                if shouldReconnect, self.autoReconnect { self.scheduleRetryAfterFailure() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "macauth.network"))
        pathMonitor = monitor
    }

    // MARK: - Disconnect

    func disconnect() {
        // An explicit disconnect is an instruction, not a fault: cancel any pending retry and
        // clear the "user wanted this" flag so nothing dials back in behind their back.
        cancelRenewal()
        userHasConnected = false
        consecutiveFailures = 0

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
        // A preview's numbers are supplied by the playground, not read from the machine.
        guard !isPreview else { return }

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

        history.append(ThroughputSample(down: stats.rateIn, up: stats.rateOut))
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    /// Seeds a plausible-looking history, for the playground only.
    func setPreviewHistory(_ samples: [ThroughputSample]) {
        guard isPreview else { return }
        history = samples
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
