import AppKit
import Foundation
import AutoConnectCore
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
        /// The tunnel is gone and an automatic attempt is queued. Distinct from `failed`, which
        /// is now only the end of the ladder: `retrying` is a working state and says so.
        case retrying(RetryStatus)
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .contactingGateway, .awaitingLogin, .exchangingToken, .startingTunnel,
                 .reconnecting, .retrying:
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
            // A placeholder. The real line counts down, so it needs `now` and is built by the
            // view from `retryStatus` and `retryDeadline`.
            case .retrying(let status): return status.statusText(remaining: nil)
            case .failed: return "Failed"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { DiagnosticLog.write("phase: \(phase.label)") }
            // A renewal ends the moment it has an answer, either way. `didSet` rather than a
            // line in each of the places that reach these phases, because missing one leaves
            // the flag stuck on and the next real drop silently unreported.
            switch phase {
            case .connected, .failed: isRenewing = false
            default: break
            }
        }
    }

    /// True while an automatic renewal is tearing the tunnel down in order to build it again.
    /// That drop is a step of the renewal rather than a disconnection, so it is reported as one:
    /// the steps in between stay quiet, and the renewal itself says that is what it is.
    @Published private(set) var isRenewing = false
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

    /// Preview only. Receives what Connect and Disconnect were asked to do, so the playground can
    /// move its own phase and the controls can be exercised without a gateway. `true` is connect.
    var onPreviewConnectRequest: ((Bool) -> Void)?

    // MARK: Reconnection

    /// Whether automatic reconnection is wanted. Off by default: an app that dials a corporate
    /// VPN unasked is worse than one that waits to be told.
    @Published var autoReconnect = UserDefaults.standard.bool(forKey: "autoconnect.autoReconnect") {
        didSet {
            UserDefaults.standard.set(autoReconnect, forKey: "autoconnect.autoReconnect")
            autoReconnect ? scheduleRenewal() : cancelRenewal()
        }
    }

    private let policy = ReconnectPolicy()
    private var renewalTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    /// Set when a stale gateway route was found but could not be removed automatically.
    private var staleRouteHint: String?
    /// Set when this launch adopted a tunnel it did not start, so Disconnect still works.
    private var adoptedPID: Int32?
    private var consecutiveFailures = 0

    /// When the queued attempt fires, for the countdown in the panel. Nil while nothing is
    /// queued, which with `Phase.retrying` on screen means the app is waiting for a network.
    ///
    /// Deliberately not inside the phase. The phase is paced by `StatusPacer` and compared for
    /// equality on every change; a value that moves every second would either thrash the pacer or
    /// have to defeat it. The deadline is a fixed date instead, and the panel's existing one
    /// second ticker redraws the text from it.
    @Published private(set) var retryDeadline: Date?
    /// True once the user has connected at least once this launch, so a network change can restore
    /// a tunnel they asked for without ever starting one they did not.
    private var userHasConnected = false

    /// What the path monitor last saw. Optimistic until it reports, because the first update takes
    /// a moment to arrive and a connect must not be held up waiting to be told the network works.
    private var isNetworkAvailable = true

    /// True while an attempt is already queued.
    ///
    /// A queued retry *is* the retry. Without this, every trigger cancelled the attempt the last
    /// one had queued and moved the ladder up a rung, so a burst of them spent the whole budget
    /// without a single attempt ever running: the give-up message named three failures that had
    /// never been attempted.
    private var isRetryScheduled = false

    /// Which connect sequence is the current one, and which runner is the current one.
    ///
    /// Both exist because a renewal abandons work that has not finished talking. A cancelled
    /// connect still unwinds through its catch blocks, and an abandoned openconnect keeps printing
    /// until it dies, its output handler still holding a callback into here. Stamping each with the
    /// generation it belongs to is what stops the tail of one attempt from reporting itself over
    /// the phase of the attempt that replaced it, which is how a renewal that was still
    /// authenticating announced itself as connected.
    private var connectGeneration = 0
    private var runnerGeneration = 0

    /// Why the app is rebuilding the session, in the words the banner and the panel both use.
    private static let expiringReason = "The session is about to expire."
    private static let expiredReason = "The session expired."
    private static let droppedReason = "The tunnel dropped."

    /// How often a connected tunnel is re-examined: the countdown is redrawn, and the two ways
    /// "connected" goes stale without anything reporting it are checked for.
    private static let heartbeat: TimeInterval = 15

    /// Loads the saved connections and selects one, or starts empty. Nothing about any
    /// particular gateway is compiled in: Settings takes an address and asks it for the rest.
    /// `isPreview` is passed in rather than set afterwards: `adoptRunningTunnel` runs from here,
    /// and a flag set after `init` returned was still false while it ran, so the playground's
    /// controller adopted whatever tunnel the machine really had.
    init(profile: VPNProfile? = nil, isPreview: Bool = false) {
        self.isPreview = isPreview

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

        adoptRunningTunnel()
    }

    /// Picks up a tunnel that outlived the app.
    ///
    /// openconnect is a separate root process, so quitting or rebuilding the app leaves it running
    /// and the machine still on the VPN. Reporting "Not connected" in that state would be a lie,
    /// and Disconnect would have nothing to act on.
    private func adoptRunningTunnel() {
        guard !isPreview else { return }

        // A playground launch is a second copy of the app running beside the real one, and the
        // real one's tunnel is the user's actual network connection. Adopting it would hand a
        // dev window ownership of a live tunnel it did not start, and quitting that window would
        // take it down. The playground's own controllers are previews and were always safe; this
        // is the controller the app builds for itself before the flag is ever read.
        #if DEBUG
        guard !CommandLine.arguments.contains("--playground") else { return }
        #endif

        switch TunnelAdoption.decide(marker: OpenConnectRunner.pidFilePath) {
        case .none:
            return

        case .stalePIDFile:
            // The process is gone; clear the marker so it cannot be adopted later.
            TunnelAdoption.cleanUp(pidFilePath: OpenConnectRunner.pidFilePath)
            TunnelAdoption.forget()

        case .adopt(let pid, let snapshot):
            DiagnosticLog.write("adopt: found running tunnel, pid \(pid)")

            var tunnel = OpenConnectRunner.Tunnel(
                assignedIP: snapshot?.assignedIP,
                usingDTLS: snapshot?.usingDTLS ?? false,
                sessionExpiry: snapshot?.sessionExpiry,
                gatewayEndpoint: snapshot?.gatewayEndpoint,
                transport: snapshot?.transport,
                cipher: snapshot?.cipher,
                connectedAt: snapshot?.connectedAt,
                interface: snapshot?.interface
            )
            // A tunnel adopted without a snapshot still has to report statistics, so find its
            // device and address from the system rather than showing an empty details block.
            if tunnel.interface == nil || tunnel.assignedIP == nil,
               let discovered = TunnelAdoption.discoverTunnel()
            {
                tunnel.interface = tunnel.interface ?? discovered.interface
                tunnel.assignedIP = tunnel.assignedIP ?? discovered.address
                DiagnosticLog.write(
                    "adopt: discovered \(discovered.interface) \(discovered.address)"
                )
            }

            tunnel.ciphersuite = snapshot?.ciphersuite
            tunnel.securedRouteCount = snapshot?.securedRouteCount ?? 0
            tunnel.excludedRouteCount = snapshot?.excludedRouteCount ?? 0
            tunnel.carriesDefaultRoute = snapshot?.carriesDefaultRoute ?? false

            // Point at the connection this tunnel belongs to, so Disconnect and the row's title
            // describe what is actually running.
            if let profileID = snapshot?.profileID,
               let owner = profiles.first(where: { $0.id == profileID })
            {
                profile = owner
            }

            adoptedPID = pid
            userHasConnected = true
            phase = .connected(tunnel)
            startClock()

            // Everything a connect would have started, because an adopted tunnel has none of it:
            // no runner watching its output, no renewal scheduled, no wake handling. Without this
            // it sat on "Connected" for as long as the app stayed open, however long ago its
            // session ended, which is exactly what a countdown reading "expired" beside a green
            // dot was showing.
            startNetworkMonitorIfNeeded()
            startSleepWakeObservers()
            if autoReconnect { scheduleRenewal() }
        }
    }

    /// Saves what cannot be read back from the system later: expiry, endpoint, cipher, routes.
    private func rememberLiveTunnel(_ tunnel: OpenConnectRunner.Tunnel) {
        guard !isPreview else { return }

        TunnelAdoption.record(
            TunnelAdoption.Snapshot(
                profileID: profile.id,
                assignedIP: tunnel.assignedIP,
                interface: tunnel.interface,
                gatewayEndpoint: tunnel.gatewayEndpoint,
                transport: tunnel.transport,
                cipher: tunnel.cipher,
                ciphersuite: tunnel.ciphersuite,
                sessionExpiry: tunnel.sessionExpiry,
                connectedAt: tunnel.connectedAt,
                usingDTLS: tunnel.usingDTLS,
                securedRouteCount: tunnel.securedRouteCount,
                excludedRouteCount: tunnel.excludedRouteCount,
                carriesDefaultRoute: tunnel.carriesDefaultRoute
            )
        )
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
        referenceDate: Date = Date(),
        retryDeadline: Date? = nil
    ) -> VPNController {
        // Pass the profile explicitly so a preview never picks up saved settings.
        let controller = VPNController(profile: profile, isPreview: true)
        controller.phase = phase
        controller.now = referenceDate
        controller.retryDeadline = retryDeadline
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

    /// True when this app has an openconnect running, including one adopted from a previous
    /// launch or one still coming up. Quitting has to tear those down too, not just a tunnel that
    /// finished connecting.
    var hasRunningTunnel: Bool {
        runner != nil || adoptedPID != nil
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

    /// `userInitiated` is false only for `renew`, which drives this from inside the retry ladder.
    /// A person clicking Connect, or flicking the switch back on during a countdown, is saying to
    /// try now: the wait is cancelled and the ladder starts over, or a connection that failed six
    /// times this morning would give up on its second try this afternoon.
    func connect(userInitiated: Bool = true) {
        // A preview controller must never touch the machine. Without this, Connect in the
        // playground ran the real sequence against the example gateway: a webview sign-in, and
        // then openconnect. The playground gets the request instead, and moves its own state.
        guard !isPreview else {
            onPreviewConnectRequest?(true)
            return
        }
        guard connectTask == nil, !isConnected else { return }

        // The panel offers Set Up rather than Connect until this holds, so reaching here means a
        // keyboard shortcut or a stale profile. Say what is missing instead of POSTing to
        // "https:///" and failing with something about a malformed URL.
        guard profile.isComplete else {
            phase = .failed("This connection is not set up yet. Add a gateway in Settings.")
            return
        }

        if userInitiated {
            cancelRenewal()
            consecutiveFailures = 0
        }

        userHasConnected = true
        startNetworkMonitorIfNeeded()
        startSleepWakeObservers()

        connectGeneration += 1
        let generation = connectGeneration

        connectTask = Task { [weak self] in
            // The sign-in window takes focus, which would otherwise dismiss the transient panel
            // before the user could see the result.
            await PanelPin.pinned {
                await self?.runConnectSequence(generation: generation)
            }
            // Only when it is still ours. A renewal cancels this task and starts another, and
            // clearing the handle blindly left the controller believing nothing was in flight,
            // which is a second connect one click away.
            guard let self, generation == self.connectGeneration else { return }
            self.connectTask = nil
        }
    }

    /// Moves the phase on behalf of one connect sequence, and drops anything a superseded sequence
    /// still has to say.
    private func report(_ next: Phase, generation: Int) {
        guard generation == connectGeneration else { return }
        phase = next
    }

    /// Reports a failed attempt, and lets the retry ladder decide whether to try another.
    ///
    /// The plain `report` stays for failures no retry can clear, such as a certificate that does
    /// not hash to the pin: dialling that again only repeats the alarm. These are the ones a retry
    /// genuinely can clear, a gateway that timed out being the ordinary case, and until now none of
    /// them scheduled anything at all. An attempt that died reaching the gateway simply stopped,
    /// which is the other half of "it should have kept trying": the ladder existed but only a
    /// tunnel that had already been built could get onto it.
    private func reportFailure(_ message: String, generation: Int) {
        guard generation == connectGeneration else { return }

        // The phase is set once, by whichever of these two owns the outcome. Passing through
        // `.failed` on the way to a queued retry was not free: the notifier reads every phase, so
        // a transient drop announced "VPN failed" and then, three seconds later, "reconnecting".
        if autoReconnect, userHasConnected, scheduleRetryAfterFailure(reason: message) { return }
        phase = .failed(message)
    }

    private func runConnectSequence(generation: Int) async {
        // However this ends, the login is over. Held while it runs so a disconnect can close its
        // window; left behind on a failure it would be a window nobody can close from outside.
        //
        // Guarded on the generation for the same reason as `report`: a sequence that has been
        // superseded must not clear the login window belonging to the one that replaced it, which
        // would leave that one waiting on a continuation nothing can resume.
        defer { if generation == connectGeneration { login = nil } }

        do {
            DiagnosticLog.startSession()
            try OpenConnectRunner.verifyBinary(at: profile.openconnectPath)

            // Step 1.
            report(.contactingGateway, generation: generation)
            clearStaleGatewayRoute()

            let client = GatewayClient(profile: profile)
            let authRequest = try await client.requestAuthentication()

            // Step 2.
            report(.awaitingLogin, generation: generation)
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

            // Step 3.
            report(.exchangingToken, generation: generation)
            let complete = try await client.completeAuthentication(
                authRequest: authRequest,
                ssoToken: ssoToken
            )

            // Step 4. The gateway states its own fingerprint; cross-check it against the pin so
            // a gateway cannot talk us into trusting a certificate we did not expect.
            if let pinned = profile.normalizedCertificateSHA1,
               complete.serverCertHash.uppercased() != pinned
            {
                report(
                    .failed(
                        "The gateway reported certificate \(complete.serverCertHash), "
                            + "which does not match the pinned fingerprint. Refusing to connect."
                    ),
                    generation: generation
                )
                return
            }

            // Nothing below this line should start a process on behalf of a sequence that has
            // already been replaced: that is how two openconnects end up racing for one tunnel.
            guard generation == connectGeneration else { return }

            report(.startingTunnel, generation: generation)
            try startTunnel(
                sessionToken: complete.sessionToken,
                serverCertHash: complete.serverCertHash
            )
        } catch let error as SAMLLoginController.LoginError {
            // Backing out of the login window is not a failure worth shouting about.
            if case .cancelled = error {
                report(.idle, generation: generation)
            } else if error.isTerminal {
                // Rejected credentials and a bad certificate are the login half of the rule the
                // pin check below already follows: dialling again only repeats the alarm, and here
                // it also spends the corporate account's lockout budget on a password the gateway
                // has already refused.
                report(.failed(error.errorDescription ?? "\(error)"), generation: generation)
            } else {
                reportFailure(error.errorDescription ?? "\(error)", generation: generation)
            }
        } catch let error as GatewayClient.ClientError {
            // A stale route makes the gateway unreachable, and the symptom is a timeout. Say what
            // is actually wrong, and exactly how to fix it, rather than blaming the network.
            if let hint = staleRouteHint {
                reportFailure(
                    "The gateway could not be reached because a leftover route from a previous "
                        + "session points at a gateway that no longer exists. Clear it "
                        + "with:\n\(hint)",
                    generation: generation
                )
            } else {
                reportFailure(error.description, generation: generation)
            }
        } catch let error as OpenConnectRunner.RunnerError {
            reportFailure(error.description, generation: generation)
        } catch {
            reportFailure(error.localizedDescription, generation: generation)
        }
    }

    /// Clears the host route a previously crashed tunnel left pointing at a gateway that no longer
    /// exists.
    ///
    /// Without this the gateway is unreachable and the failure reads as a timeout, which sends the
    /// user looking at their network rather than at a leftover routing entry. Best effort: if the
    /// route cannot be removed (no passwordless rule for it), the connect proceeds anyway and the
    /// error path below explains what to run.
    private func clearStaleGatewayRoute() {
        guard !isPreview else { return }

        let host = profile.host.split(separator: ":").first.map(String.init) ?? profile.host
        guard case .stale(let route) = RoutePreflight.check(address: host) else {
            staleRouteHint = nil
            return
        }

        if RoutePreflight.clear(route) {
            staleRouteHint = nil
        } else {
            // Remember it, so a subsequent failure can say what to do rather than blaming the
            // network.
            staleRouteHint = RoutePreflight.deleteCommand(for: route.destination)
                .joined(separator: " ")
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

        runnerGeneration += 1
        let generation = runnerGeneration

        runner.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.apply(runnerState: state, generation: generation)
            }
        }

        try runner.connect(sessionToken: sessionToken, serverCertHash: serverCertHash)
    }

    private func apply(runnerState state: OpenConnectRunner.State, generation: Int) {
        // An abandoned openconnect keeps printing until it dies, and its output handler is still
        // holding this callback. Anything but the current runner is ignored: without this, the tail
        // of a torn-down tunnel reported itself over the connect that replaced it, so a renewal
        // that was still authenticating showed, and announced, "Connected".
        guard generation == runnerGeneration else { return }

        switch state {
        case .disconnected:
            stopClock()
            TunnelAdoption.forget()
            // A tunnel that dropped on its own is exactly what auto-reconnect is for. `.idle`
            // only when nothing is going to be tried, or the panel says "Not connected" beside a
            // switch that is still on and a retry that is already counting down.
            if autoReconnect, userHasConnected,
               scheduleRetryAfterFailure(reason: Self.droppedReason) { return }
            phase = .idle

        case .connecting:
            phase = .startingTunnel

        case .connected(let tunnel):
            phase = .connected(tunnel)
            consecutiveFailures = 0
            // Anything queued is moot, including a retry that openconnect's own recovery beat.
            cancelRenewal()
            startClock()
            rememberLiveTunnel(tunnel)
            if autoReconnect { scheduleRenewal() }

        case .reconnecting(let tunnel, let reason):
            // openconnect is retrying on its own. Show it honestly and leave it to try; our own
            // policy takes over only if it gives up.
            phase = .reconnecting(tunnel, reason: reason)
            setStatsPolling(false)

        case .failed(let message):
            stopClock()
            if autoReconnect, userHasConnected,
               scheduleRetryAfterFailure(reason: message) { return }
            phase = .failed(message)
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
            renew(reason: Self.expiringReason)
        case .reconnect(let delay):
            renewalTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.renew(reason: Self.expiringReason)
            }
        }
    }

    /// Queues another attempt after one that really was made and really did fail.
    ///
    /// Only a completed attempt belongs here. A trigger, meaning the network coming back or the
    /// machine waking, goes through `triggerReconnect` instead, because it is not evidence that the
    /// gateway is unwilling. Counting triggers is what stopped automatic retries during a
    /// half-minute network drop: a recovering network is reported several times over, and each
    /// report both spent a rung of the ladder and cancelled the retry the previous one had queued,
    /// so the budget ran out having never once let an attempt run.
    /// Returns whether the phase now describes what is going to happen, so the caller does not
    /// overwrite it with a settled `.failed` that is not true.
    @discardableResult
    private func scheduleRetryAfterFailure(reason: String? = nil) -> Bool {
        guard !isPreview else { return false }

        // A retry is already queued and `phase` is already the `.retrying` that describes it.
        // Saying so is what stops a second failure arriving behind the first from replacing a
        // live countdown with "Failed".
        guard !isRetryScheduled else { return true }

        // Asked before the count moves, so a decision to hold can leave the count alone.
        let decision = policy.decideAfterFailure(
            consecutiveFailures: consecutiveFailures + 1,
            isNetworkAvailable: isNetworkAvailable
        )

        // No path to attempt over. The ladder stays whole for when the network is back, and the
        // monitor is what starts the next attempt. It is still shown, because an app quietly
        // waiting on a network looks exactly like an app that has given up.
        if case .wait = decision {
            showRetrying(reason: reason, waitingForNetwork: true, deadline: nil)
            return true
        }

        cancelRenewal()
        consecutiveFailures += 1

        switch decision {
        case .giveUp(let giveUpReason):
            phase = .failed(giveUpReason)
            consecutiveFailures = 0
            return true
        case .reconnect(let delay):
            scheduleRetry(after: delay, reason: reason)
            return true
        case .wait, .reconnectNow:
            renew(reason: Self.droppedReason)
            return true
        }
    }

    /// Puts the panel on the waiting state without changing what is queued.
    private func showRetrying(reason: String?, waitingForNetwork: Bool, deadline: Date?) {
        retryDeadline = deadline
        phase = .retrying(
            RetryStatus(
                attempt: consecutiveFailures + 1,
                maxAttempts: policy.maxConsecutiveFailures,
                isWaitingForNetwork: waitingForNetwork,
                reason: reason
            )
        )
    }

    /// Starts an attempt because the situation changed, not because one failed: the network came
    /// back, or the machine woke to find the tunnel device gone.
    ///
    /// Deliberately outside the failure ladder. The attempt this queues will spend a rung itself if
    /// it fails, so charging the trigger as well punished the network for recovering. Delayed by
    /// `networkSettleDelay` so a network that returns in pieces produces one attempt, not five.
    private func triggerReconnect() {
        guard !isPreview, autoReconnect, userHasConnected, !isRetryScheduled else { return }

        cancelRenewal()
        scheduleRetry(after: policy.networkSettleDelay)
    }

    /// Queues exactly one attempt, and marks it queued so nothing replaces it.
    private func scheduleRetry(after delay: TimeInterval, reason: String? = nil) {
        isRetryScheduled = true
        showRetrying(
            reason: reason,
            waitingForNetwork: false,
            deadline: Date().addingTimeInterval(delay)
        )
        renewalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.isRetryScheduled = false
            self.retryDeadline = nil
            self.renew(reason: Self.droppedReason)
        }
    }

    /// Tears down and reconnects. The IdP cookie usually survives in the webview's persistent
    /// store, so this often completes without any typing.
    ///
    /// `reason` is what the panel and the banner both say. A renewal used to pass in silence, on
    /// the grounds that nothing about the connection had changed; it had, for the seconds the
    /// rebuild takes, and a gap nobody was told about reads as a fault.
    private func renew(reason: String? = nil) {
        guard autoReconnect, userHasConnected else { return }

        isRenewing = true
        cancelRenewal()

        // The phase has to leave `.connected` before the connect starts, because `connect()`
        // refuses to run while the app believes a tunnel is up. During a renewal it still did:
        // that guard is what made a renewal kill the tunnel and then not rebuild it, leaving the
        // machine with no connection until some later failure happened to schedule a retry.
        if case .connected(let live) = phase {
            phase = .reconnecting(live, reason: reason)
        }

        teardownTunnelProcess()

        connectTask?.cancel()
        connectTask = nil
        connect(userInitiated: false)
    }

    /// Forgets the current runner, so nothing it says afterwards is acted on.
    private func discardRunner() {
        runnerGeneration += 1
        runner = nil
    }

    /// Stops whatever openconnect this app is responsible for, whether it started it or adopted it
    /// from a previous launch, and forgets it.
    ///
    /// The adopted case is the one that was missing: an adopted tunnel has no child process to
    /// signal, so a renewal that only told the runner to stop left the old openconnect running and
    /// started a second one beside it.
    private func teardownTunnelProcess() {
        if let runner {
            runner.disconnect()
        } else if adoptedPID != nil {
            // No child process to signal, so stop it the way the runner would: by its pid-file
            // marker, which only this app's openconnect carries.
            OpenConnectRunner.shutdownAdopted()
        }

        discardRunner()
        adoptedPID = nil
        TunnelAdoption.forget()
        TunnelAdoption.cleanUp(pidFilePath: OpenConnectRunner.pidFilePath)
    }

    // MARK: - Watchdog

    /// Re-examines a tunnel that claims to be connected, once per heartbeat.
    ///
    /// The renewal timer alone is not enough to trust a twelve-hour session to. The machine sleeps,
    /// a timer that long fires late or not at all, and a tunnel adopted at launch never had one
    /// scheduled. Asking the question on every tick instead means the worst case is one interval
    /// late rather than never, which is the whole difference between a session that renews itself
    /// and one that sits on "Connected" beside a countdown reading "expired".
    private func checkTunnelHealth() {
        guard !isPreview, case .connected(let live) = phase else { return }

        switch policy.evaluateHealth(
            expiry: live.sessionExpiry,
            now: Date(),
            isProcessAlive: isTunnelProcessAlive
        ) {
        case .healthy:
            break

        case .renewDue:
            // Nothing to do without permission to dial. The countdown says how long is left, and
            // the user can renew by hand.
            guard autoReconnect else { return }
            renew(reason: Self.expiringReason)

        case .expired:
            sessionExpired()

        case .processGone:
            tunnelProcessVanished()
        }
    }

    /// True while this app's own connect sequence is running, so nothing schedules a second one
    /// over it.
    ///
    /// The sequence, not the phase: openconnect's own retries also leave the phase working, and
    /// taking over from those on a network change is deliberate and older than this. What must not
    /// happen is a renewal restarting itself, which its own teardown otherwise causes: bringing a
    /// tunnel down is a network change too.
    private var isAttemptInFlight: Bool { connectTask != nil }

    /// True while openconnect is rebuilding the tunnel on its own.
    ///
    /// Its own retries are worth waiting out: they usually succeed, and they keep the session
    /// rather than sending the user back through the identity provider. This is the state that read
    /// as "no tunnel, and the network just changed" on every report from a recovering network,
    /// which is how a give-up message appeared over a tunnel openconnect restored eight seconds
    /// later without any attempt of ours being made at all.
    private var isTunnelSelfHealing: Bool {
        if case .reconnecting = phase { return true }
        return false
    }

    /// Whether the openconnect this app is responsible for is still alive.
    private var isTunnelProcessAlive: Bool {
        if let runner { return runner.isRunning }
        if let adoptedPID { return TunnelAdoption.isRunning(pid: adoptedPID) }
        // Neither: nothing is holding a tunnel up, whatever the phase says.
        return false
    }

    /// The gateway's session is over, however healthy the device looks.
    ///
    /// The tunnel is torn down either way. Leaving it up is worse than closing it: it still holds
    /// the routes, including the default one, so every packet goes into a session the gateway has
    /// already dropped and the machine has no working network at all. That is the state this was
    /// reported from: "Connected", an assigned address, and nothing getting through.
    private func sessionExpired() {
        DiagnosticLog.write("watchdog: session expired")

        guard autoReconnect, userHasConnected else {
            teardownTunnelProcess()
            stopClock()
            phase = .failed(
                "The gateway session expired, so the tunnel was closed. Connect again to start a "
                    + "new session."
            )
            return
        }

        // The phase is left to `renew`, which moves it off `.connected` itself. Setting it here
        // first would change it before `isRenewing` was up, and the banner would call a renewal a
        // drop.
        renew(reason: Self.expiredReason)
    }

    /// openconnect is gone, so there is no tunnel behind the state.
    ///
    /// Nothing reports this on its own for an adopted tunnel: there is no child process and no
    /// output handler, so the phase would stay `.connected` until the app was restarted.
    private func tunnelProcessVanished() {
        DiagnosticLog.write("watchdog: openconnect is no longer running")

        let message = "The tunnel is gone: openconnect is no longer running."
        teardownTunnelProcess()
        stopClock()

        if autoReconnect, userHasConnected, scheduleRetryAfterFailure(reason: message) { return }
        phase = .failed(message)
    }

    private func cancelRenewal() {
        renewalTask?.cancel()
        renewalTask = nil
        isRetryScheduled = false
        retryDeadline = nil
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
        guard autoReconnect, userHasConnected, !isAttemptInFlight else { return }

        // Give the network a moment to come back before judging it.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))

            let interface = tunnel?.interface
                ?? Self.interfaceOwning(address: tunnel?.assignedIP)

            // No interface means openconnect is gone or its device was torn down.
            guard let interface, Self.interfaceExists(interface) else {
                triggerReconnect()
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
                // Recorded whatever the decision below is: the retry ladder reads this to tell an
                // outage apart from a gateway that is refusing.
                self.isNetworkAvailable = path.status == .satisfied

                let shouldReconnect = self.policy.shouldReconnectOnNetworkChange(
                    isNetworkAvailable: self.isNetworkAvailable,
                    isTunnelUp: self.isConnected,
                    wasConnectedBefore: self.userHasConnected,
                    isAttemptInFlight: self.isAttemptInFlight,
                    isTunnelSelfHealing: self.isTunnelSelfHealing
                )
                if shouldReconnect, self.autoReconnect { self.triggerReconnect() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "autoconnect.network"))
        pathMonitor = monitor
    }

    // MARK: - Disconnect

    func disconnect() {
        // Same reason as connect: a mock must not be able to tear down the real tunnel, which is
        // the user's actual network connection.
        guard !isPreview else {
            onPreviewConnectRequest?(false)
            return
        }

        // An explicit disconnect is an instruction, not a fault: cancel any pending retry and
        // clear the "user wanted this" flag so nothing dials back in behind their back.
        cancelRenewal()
        userHasConnected = false
        consecutiveFailures = 0
        // Whatever a renewal was doing, this supersedes it: the tunnel is going down and staying
        // down, which is worth reporting even if a renewal was mid-flight.
        isRenewing = false

        // Cancelling the task is not enough while a sign-in is on screen: it is parked on a
        // continuation the window will never resume. Tell the window itself to go.
        login?.cancel()
        login = nil

        connectTask?.cancel()
        connectTask = nil

        teardownTunnelProcess()
        stopClock()
        phase = .idle
    }

    /// Dismisses a settled failure. `.retrying` is deliberately not dismissable: the X would have
    /// to either lie about what the app is doing or silently cancel the retries, and the switch
    /// beside it already turns them off honestly.
    func clearError() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Clock

    /// Redraws the countdown, and asks the watchdog whether the tunnel behind it is still real.
    private func startClock() {
        guard clockTask == nil else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeat))
                guard !Task.isCancelled, let self else { return }
                self.now = Date()
                self.checkTunnelHealth()
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
