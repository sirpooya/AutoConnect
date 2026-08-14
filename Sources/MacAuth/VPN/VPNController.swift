import AppKit
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
        /// The tunnel is not carrying traffic and is being re-established.
        case reconnecting(OpenConnectRunner.Tunnel, reason: String?)
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .contactingGateway, .awaitingLogin, .exchangingToken, .startingTunnel,
                 .reconnecting:
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
            case .reconnecting: return "Reconnecting..."
            case .failed: return "Failed"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// The connection the menu bar acts on. Assigning it switches which gateway Connect dials.
    @Published var profile: VPNProfile
    /// Every configured connection, so the panel and Settings can list and switch between them.
    @Published var profiles: [VPNProfile] = []

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
    private var wakeObserver: NSObjectProtocol?
    private var consecutiveFailures = 0
    /// True once the user has connected at least once this launch, so a network change can restore
    /// a tunnel they asked for without ever starting one they did not.
    private var userHasConnected = false

    /// Loads the saved connections and selects one, or starts empty. Nothing about any
    /// particular gateway is compiled in: Settings takes an address and asks it for the rest.
    init(profile: VPNProfile? = nil) {
        let store = VPNSettingsStore()

        if let profile {
            // An explicit profile means a preview or a test: do not touch what is on disk.
            self.profile = profile
            self.profiles = [profile]
        } else {
            // Credentials were briefly a list of their own; anything saved that way is folded
            // back into the connection that used it before the list is read.
            store.foldCredentialsIntoConnections()
            self.profiles = store.loadProfiles()
            self.profile = store.selectedProfile() ?? .empty
        }
    }

    // MARK: - Connections

    /// Makes one connection the active one, both here and on disk.
    func select(profileID: UUID) {
        guard let chosen = profiles.first(where: { $0.id == profileID }) else { return }

        let store = VPNSettingsStore()
        store.selectedProfileID = profileID
        store.save(profile: chosen)
        profile = chosen
    }

    /// Re-reads the connection list, after Settings has added, edited or removed one.
    func reloadProfiles() {
        let store = VPNSettingsStore()
        profiles = store.loadProfiles()

        // Keep pointing at the same connection when it still exists, so an edit elsewhere does
        // not silently move the menu bar onto a different gateway.
        if let current = profiles.first(where: { $0.id == profile.id }) {
            profile = current
        } else {
            profile = store.selectedProfile() ?? .empty
        }
    }

    /// Builds a controller parked in a fixed phase, for the playground and for previews.
    ///
    /// Nothing is started: no gateway call, no process, no clock, and crucially no stats polling.
    /// A preview that polled would read whatever `utun` device happens to exist on the machine,
    /// so a mock would silently display the user's real tunnel, and each sample would overwrite
    /// `referenceDate` with the wall clock, turning a "2h" uptime into months.
    static func preview(
        phase: Phase,
        profile: VPNProfile = .example,
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
        switch phase {
        case .connected(let tunnel): return tunnel
        case .reconnecting(let tunnel, _): return tunnel
        default: return nil
        }
    }

    /// Why the tunnel is being re-established, when openconnect said.
    var reconnectReason: String? {
        if case .reconnecting(_, let reason) = phase { return reason }
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
        // A preview controller must never touch the machine. Without this, Connect in the
        // playground ran the real sequence against the example gateway: a webview sign-in, and
        // then openconnect.
        guard !isPreview else { return }
        guard connectTask == nil, !isConnected else { return }

        userHasConnected = true
        startNetworkMonitorIfNeeded()
        startSleepWakeObservers()

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

            // Remember which identity provider this gateway uses, so Settings can offer that
            // site's saved password first. Nothing depends on it being right.
            if let idpHost = login.observedIdPHost, idpHost != profile.idpHost {
                profile.idpHost = idpHost
                VPNSettingsStore().save(profile: profile)
            }
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
        // With no username there is nothing to start from, so let the user drive.
        let username = profile.username
        guard !username.isEmpty else { return nil }

        let password = passwordForAutofill()

        let otpAccountID = profile.otpAccountID
        let accountStore = KeychainStore()

        return LoginFormFiller.Credentials(
            username: username,
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

    /// The password to type into the IdP page, from wherever the profile says it lives.
    ///
    /// Never fails closed: any source that comes up empty just means the login window opens with
    /// the password field blank and the user finishes by hand.
    private func passwordForAutofill() -> String? {
        switch profile.passwordSource {
        case .ask:
            return nil

        case .stored:
            return VPNSettingsStore().password(account: profile.credentialAccount)

        case .loginKeychain:
            guard let server = profile.passwordKeychainServer else { return nil }
            // This is the call that makes macOS ask permission, which is why it happens here,
            // at connect time, rather than while Settings is merely listing candidates.
            return try? LoginKeychain.password(server: server, account: profile.username)
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
            // A tunnel that dropped on its own is exactly what auto-reconnect is for.
            if autoReconnect, userHasConnected { scheduleRetryAfterFailure() }

        case .connecting:
            phase = .startingTunnel

        case .connected(let tunnel):
            phase = .connected(tunnel)
            consecutiveFailures = 0
            startClock()
            if autoReconnect { scheduleRenewal() }

        case .reconnecting(let tunnel, let reason):
            // openconnect is retrying on its own. Show it honestly and leave it to try; our own
            // policy takes over only if it gives up.
            phase = .reconnecting(tunnel, reason: reason)
            setStatsPolling(false)

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

    /// Watches for sleep and wake.
    ///
    /// This is the case the logs from a closed laptop lid show: openconnect's dead-peer detection
    /// fires, its own retries all fail with "Can't assign requested address" because the physical
    /// interface went away, and after its retry window it exits. A path change alone does not
    /// always arrive in time, so wake is handled explicitly.
    private func startSleepWakeObservers() {
        guard !isPreview, wakeObserver == nil else { return }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWake()
            }
        }
    }

    /// After waking, a tunnel that looks connected may be carrying nothing. Verify the interface
    /// is really there before trusting the state, and recover if it is not.
    private func handleWake() {
        guard autoReconnect, userHasConnected else { return }

        // Give the network a moment to come back before judging it.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))

            let interface = tunnel?.interface
                ?? Self.interfaceOwning(address: tunnel?.assignedIP)

            // No interface means openconnect is gone or its device was torn down.
            guard let interface, Self.interfaceExists(interface) else {
                scheduleRetryAfterFailure()
                return
            }

            // The device survived, so let openconnect's own detection run; it will report a dead
            // peer if nothing is getting through, which lands us in .reconnecting.
            statsReader.reset()
        }
    }

    private static func interfaceExists(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = [name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
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
        // Same reason as connect: a mock must not be able to tear down the real tunnel, which is
        // the user's actual network connection.
        guard !isPreview else { return }

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
