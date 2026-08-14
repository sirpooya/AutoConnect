import MacAuthCore
import SwiftUI

// MARK: - Params

/// Live parameters for the VPN status row. The shipping `VPNSection` reads these, so tuning the
/// playground tunes the real menu with no rebuild.
///
/// Only the values that cannot be judged from a static screenshot are knobs. Everything else
/// (paddings, font sizes, the colour ramp) stays a measured constant in the view: a number with a
/// reason behind it is a finding, not a dial.
@MainActor
@Observable
final class VPNStatusParams {
    static let shared = VPNStatusParams()

    // MARK: Appearance

    /// Diameter of the state dot. 8 pt reads as a status light next to 11 pt semibold text;
    /// below 7 the colour is too small to name at a glance.
    var dotSize: Double = 8

    // The pulsing halo behind the dot is gone, so its scale and duration knobs went with it. A
    // knob that no longer drives anything is worse than no knob: it invites tuning a value the
    // app has stopped reading.

    /// Which menu bar glyph set the status item draws. See `MenuBarIconSet`.
    var menuBarIconSet: Int = MenuBarIconSet.keyholeArc.rawValue

    /// Whether the connect control is a switch instead of a Connect / Disconnect button. A real
    /// choice, not a fake: the switch reads as state, the button reads as an instruction, and only
    /// the button can say "Cancel" while a connect is in flight.
    var usesSwitch: Bool = false

    /// Size of the connect switch, as one of AppKit's four control sizes.
    ///
    /// Deliberately not a free slider. A switch is an AppKit control drawn at fixed sizes, so a
    /// continuous scale would have to be a `scaleEffect`, which renders it at its native size and
    /// then resamples: soft edges and a thumb that no longer matches any other control on screen.
    var switchSizeIndex: Int = SwitchSize.mini.rawValue

    var switchControlSize: ControlSize {
        SwitchSize(rawValue: switchSizeIndex)?.controlSize ?? .mini
    }

    /// Diameter of the countdown wedge on each account row. 18 pt was chosen by eye against the
    /// 19 pt code beside it: smaller and the wedge reads as a stray dot, larger and it competes
    /// with the number.
    var countdownSize: Double = 18

    /// Gap between the countdown wedge and the row's trailing edge, on top of the row's own
    /// padding. The wedge and the "Copied" label share a trailing-aligned slot, so this moves
    /// both and neither can shift the row.
    var countdownMarginRight: Double = 0

    // MARK: Fake state (stage-only)

    /// Stage-only. Which phase the mock row is parked in.
    var phaseIndex: Int = PreviewPhase.connected.rawValue

    /// Stage-only. Tunnel address shown in the connected state.
    var assignedIP: String = "10.250.232.188"

    /// Stage-only. Hours left on the gateway session. The real gateway issues 12 hours.
    var hoursRemaining: Double = 11.9

    /// Stage-only. Whether the tunnel negotiated DTLS.
    var usingDTLS: Bool = true

    /// Stage-only. Text shown in the failed state. Defaults to a real message the code can emit.
    var errorText: String = "The gateway rejected the session token. Try logging in again."

    /// Stage-only. How many authenticator rows sit below the VPN row.
    var accountCount: Double = 2

    /// Stage-only. Hours the tunnel has been up.
    var uptimeHours: Double = 2.2

    /// Stage-only. Throughput as a power of ten, in bytes per second. A log scale because the
    /// point is to see the layout hold from "0 B/s" through "1.2 GB/s", and a linear slider
    /// spends its whole travel in the top decade.
    var rateExponent: Double = 6.1

    /// Stage-only. Cumulative transfer as a power of ten, in bytes.
    var transferredExponent: Double = 9.1

    init(loadSaved: Bool = true) {
        if loadSaved, let saved = VPNStatusSnapshot.load() { apply(saved) }
    }

    func reset() {
        apply(VPNStatusSnapshot(VPNStatusParams(loadSaved: false)))
        save()
    }

    func save() {
        VPNStatusSnapshot(self).save()
        // The status item is AppKit and observes nothing, so tell it a knob moved. Without this
        // the menu bar keeps the old glyph set until the next launch.
        NotificationCenter.default.post(name: .vpnStatusParamsChanged, object: nil)
    }

    private func apply(_ snapshot: VPNStatusSnapshot) {
        dotSize = snapshot.dotSize
        menuBarIconSet = snapshot.menuBarIconSet
        usesSwitch = snapshot.usesSwitch
        switchSizeIndex = snapshot.switchSizeIndex
        countdownSize = snapshot.countdownSize
        countdownMarginRight = snapshot.countdownMarginRight
        phaseIndex = snapshot.phaseIndex
        assignedIP = snapshot.assignedIP
        hoursRemaining = snapshot.hoursRemaining
        usingDTLS = snapshot.usingDTLS
        errorText = snapshot.errorText
        accountCount = snapshot.accountCount
        uptimeHours = snapshot.uptimeHours
        rateExponent = snapshot.rateExponent
        transferredExponent = snapshot.transferredExponent
    }

    /// Autosave watches this, and the stage rebuilds its mock controller from it.
    var signature: [Double] {
        [
            dotSize, Double(menuBarIconSet), usesSwitch ? 1 : 0, Double(switchSizeIndex),
            countdownSize, countdownMarginRight,
            Double(phaseIndex), hoursRemaining, usingDTLS ? 1 : 0, accountCount,
            uptimeHours, rateExponent, transferredExponent,
            Double(assignedIP.hashValue & 0xffff), Double(errorText.hashValue & 0xffff),
        ]
    }

    /// Only the shipping values. The stage-only fakes are deliberately absent: they describe the
    /// mock, not the app.
    var swiftSnippet: String {
        """
        // Menu bar
        static let menuBarIconSet: MenuBarIconSet = .\(MenuBarIconSet(rawValue: menuBarIconSet).map { "\($0)" } ?? "keyholeArc")

        // VPN status row
        static let vpnDotSize: CGFloat = \(Int(dotSize))
        static let vpnUsesSwitch = \(usesSwitch)
        static let vpnSwitchSize: ControlSize = .\(SwitchSize(rawValue: switchSizeIndex)?.title.lowercased() ?? "mini")

        // Account row countdown
        static let countdownSize: CGFloat = \(Int(countdownSize))
        static let countdownMarginRight: CGFloat = \(Int(countdownMarginRight))
        """
    }
}

/// The sizes AppKit draws a switch at, smallest first.
enum SwitchSize: Int, CaseIterable, Identifiable {
    case mini
    case small
    case regular
    case large

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .mini: "Mini"
        case .small: "Small"
        case .regular: "Regular"
        case .large: "Large"
        }
    }

    var controlSize: ControlSize {
        switch self {
        case .mini: .mini
        case .small: .small
        case .regular: .regular
        case .large: .large
        }
    }
}

/// The phases the stage can park in, in the order a connect visits them.
enum PreviewPhase: Int, CaseIterable, Identifiable {
    case idle
    case contactingGateway
    case awaitingLogin
    case exchangingToken
    case startingTunnel
    case connected
    case reconnecting
    case failed

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .contactingGateway: "Contacting"
        case .awaitingLogin: "Awaiting login"
        case .exchangingToken: "Exchanging"
        case .startingTunnel: "Starting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .failed: "Failed"
        }
    }
}

// MARK: - Snapshot

/// Flat mirror of the params, persisted as one JSON blob.
struct VPNStatusSnapshot: Codable {
    var dotSize: Double
    var menuBarIconSet: Int
    var usesSwitch: Bool
    var switchSizeIndex: Int
    var countdownSize: Double
    var countdownMarginRight: Double
    var phaseIndex: Int
    var assignedIP: String
    var hoursRemaining: Double
    var usingDTLS: Bool
    var errorText: String
    var accountCount: Double
    var uptimeHours: Double
    var rateExponent: Double
    var transferredExponent: Double

    private static let key = "macauth.vpnStatusPlayground"

    @MainActor
    init(_ params: VPNStatusParams) {
        dotSize = params.dotSize
        menuBarIconSet = params.menuBarIconSet
        usesSwitch = params.usesSwitch
        switchSizeIndex = params.switchSizeIndex
        countdownSize = params.countdownSize
        countdownMarginRight = params.countdownMarginRight
        phaseIndex = params.phaseIndex
        assignedIP = params.assignedIP
        hoursRemaining = params.hoursRemaining
        usingDTLS = params.usingDTLS
        errorText = params.errorText
        accountCount = params.accountCount
        uptimeHours = params.uptimeHours
        rateExponent = params.rateExponent
        transferredExponent = params.transferredExponent
    }

    /// Decoded key by key with a default each. A synthesized decoder throws on the first missing
    /// key, which would silently discard a whole saved tuning set the moment a knob is added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // `try?` flattens the optional, so a missing key and a decode failure both land here.
            guard let decoded = try? container.decodeIfPresent(T.self, forKey: key) else {
                return fallback
            }
            return decoded
        }

        dotSize = value(.dotSize, 8)
        menuBarIconSet = value(.menuBarIconSet, MenuBarIconSet.keyholeArc.rawValue)
        usesSwitch = value(.usesSwitch, false)
        switchSizeIndex = value(.switchSizeIndex, SwitchSize.mini.rawValue)
        countdownSize = value(.countdownSize, 18)
        countdownMarginRight = value(.countdownMarginRight, 0)
        phaseIndex = value(.phaseIndex, PreviewPhase.connected.rawValue)
        assignedIP = value(.assignedIP, "10.250.232.188")
        hoursRemaining = value(.hoursRemaining, 11.9)
        usingDTLS = value(.usingDTLS, true)
        errorText = value(
            .errorText,
            "The gateway rejected the session token. Try logging in again."
        )
        accountCount = value(.accountCount, 2)
        uptimeHours = value(.uptimeHours, 2.2)
        rateExponent = value(.rateExponent, 6.1)
        transferredExponent = value(.transferredExponent, 9.1)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    static func load() -> VPNStatusSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(VPNStatusSnapshot.self, from: data)
    }
}

// MARK: - Stage

/// Mock of the menu bar panel at its real 320 pt width, on a desktop-ish backdrop.
/// Walks the mock through the phases a real connect visits, one after another, so the controls
/// show the sequence instead of snapping to the end state.
///
/// Held outside the stage view because the walk has to survive the rebuilds it causes: every phase
/// change re-renders the stage, and a task owned by the view would be cancelled by its own effect.
@MainActor
@Observable
final class PhaseScripter {
    /// The phases a connect visits, in order. `connected` is the last one and does not wait.
    private static let connectSequence: [PreviewPhase] = [
        .contactingGateway, .awaitingLogin, .exchangingToken, .startingTunnel, .connected,
    ]

    /// How long each intermediate phase is held. Long enough to read the label, short enough that
    /// the whole walk is quicker than reaching for the phase picker.
    private static let step = Duration.milliseconds(700)

    private var task: Task<Void, Never>?

    func request(connect: Bool, params: VPNStatusParams) {
        task?.cancel()

        guard connect else {
            // Disconnecting is immediate, and cancels a walk in progress: that is what the
            // Cancel button does to a real connect too.
            params.phaseIndex = PreviewPhase.idle.rawValue
            return
        }

        task = Task {
            for phase in Self.connectSequence {
                params.phaseIndex = phase.rawValue
                guard phase != .connected else { return }
                do { try await Task.sleep(for: Self.step) } catch { return }
            }
        }
    }
}

struct VPNStatusStage: View {
    var params: VPNStatusParams

    @State private var scripter = PhaseScripter()

    /// Rebuilt whenever the fake state changes, so the real `VPNSection` renders it unmodified.
    private var mockController: VPNController {
        let controller = buildMockController()

        // Make the controls live. The mock cannot connect, so Connect, Disconnect and the switch
        // drive the stage's own phase instead, walking the same sequence a real connect visits.
        controller.onPreviewConnectRequest = { [params, scripter] wantsConnect in
            scripter.request(connect: wantsConnect, params: params)
        }
        return controller
    }

    private func buildMockController() -> VPNController {
        let phase = PreviewPhase(rawValue: params.phaseIndex) ?? .connected
        let reference = Date(timeIntervalSince1970: 1_776_000_000)

        switch phase {
        case .idle:
            return .preview(phase: .idle, referenceDate: reference)
        case .contactingGateway:
            return .preview(phase: .contactingGateway, referenceDate: reference)
        case .awaitingLogin:
            return .preview(phase: .awaitingLogin, referenceDate: reference)
        case .exchangingToken:
            return .preview(phase: .exchangingToken, referenceDate: reference)
        case .startingTunnel:
            return .preview(phase: .startingTunnel, referenceDate: reference)
        case .failed:
            return .preview(phase: .failed(params.errorText), referenceDate: reference)

        case .reconnecting:
            // The tunnel details survive so the row can show what it is trying to keep, with an
            // honest reason underneath. This message is one openconnect really emits after sleep.
            let tunnel = OpenConnectRunner.Tunnel(
                assignedIP: params.assignedIP.isEmpty ? nil : params.assignedIP,
                usingDTLS: params.usingDTLS,
                sessionExpiry: reference.addingTimeInterval(params.hoursRemaining * 3600),
                connectedAt: reference.addingTimeInterval(-params.uptimeHours * 3600)
            )
            return .preview(
                phase: .reconnecting(tunnel, reason: "Can't assign requested address"),
                referenceDate: reference
            )

        case .connected:
            let rate = pow(10, params.rateExponent)
            let transferred = pow(10, params.transferredExponent)

            let tunnel = OpenConnectRunner.Tunnel(
                assignedIP: params.assignedIP.isEmpty ? nil : params.assignedIP,
                usingDTLS: params.usingDTLS,
                sessionExpiry: reference.addingTimeInterval(params.hoursRemaining * 3600),
                gatewayEndpoint: "93.113.226.130:28015",
                transport: params.usingDTLS ? "DTLS1.2" : "TLS1.2",
                cipher: "AES-256-CBC",
                connectedAt: reference.addingTimeInterval(-params.uptimeHours * 3600),
                stats: TunnelStats(
                    // Upload runs lighter than download, as it does in practice.
                    bytesIn: UInt64(transferred),
                    bytesOut: UInt64(transferred * 0.7),
                    rateIn: rate,
                    rateOut: rate * 0.3,
                    mtu: 1300
                ),
                interface: "utun6"
            )

            let controller = VPNController.preview(
                phase: .connected(tunnel),
                referenceDate: reference
            )
            controller.setPreviewHistory(Self.fakeHistory(peak: rate))
            return controller
        }
    }

    /// A bursty traffic trace, so the chart is judged against the shape real traffic makes rather
    /// than a smooth curve. Deterministic: no randomness, so dragging a slider does not reshuffle
    /// the graph under the cursor.
    private static func fakeHistory(peak: Double) -> [VPNController.ThroughputSample] {
        (0..<VPNController.historyLength).map { index in
            let t = Double(index)
            // Two out-of-phase waves plus a slow swell gives peaks and lulls without noise.
            let shape = 0.45
                + 0.3 * sin(t / 3.1)
                + 0.18 * sin(t / 1.3)
                + 0.12 * sin(t / 11)
            let down = max(0, shape) * peak
            return VPNController.ThroughputSample(down: down, up: down * 0.28)
        }
    }

    /// A notifier that reads the saved switches but delivers nothing, so the mock panel cannot
    /// put a banner about a tunnel that does not exist on screen.
    private var mockNotifier: VPNStatusNotifier { .preview() }

    /// Fresh in-memory accounts, so the mock never reads or writes the real Keychain.
    private var mockState: AppState {
        let names = [
            ("DigikalaMFA", "p.kamel@digikala.com"),
            ("DigikalaMFA", "design@digikala.com"),
            ("GitHub", "octocat"),
            ("AWS", "root@example.com"),
            ("Cloudflare", "ops@example.com"),
            ("Datadog", "sre@example.com"),
        ]
        let wanted = Array(names.prefix(Int(params.accountCount)))
        return AppState(store: InMemoryAccountStore(demoAccounts: wanted))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.07, blue: 0.16),
                         Color(red: 0.16, green: 0.09, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // The icon above the panel it opens, so a phase can be judged as the menu bar shows
            // it: the glyph is the only thing visible when the panel is closed.
            VStack(spacing: 0) {
                menuBarStrip

                MenuPanel()
                    .environmentObject(mockState)
                    .environmentObject(mockController)
                    // The panel's Settings button needs one; the preview copy cannot post anything.
                    .environmentObject(mockNotifier)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                    .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
            // Identity keyed on the fake state so the panel rebuilds when a knob moves,
            // rather than caching a stale controller.
            .id(params.signature.description)
        }
    }

    /// A mock menu bar. Not a screenshot of the real one: the point is the glyph this phase
    /// produces, at the size and tint the real status item draws it, with the panel hanging off it.
    private var menuBarStrip: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            MenuBarIconView(isConnected: mockController.isConnected)
                // The glyphs are template images; in the real menu bar AppKit tints them, so the
                // mock has to tint them too or a white icon would vanish on a light strip.
                .foregroundStyle(.primary)

            Text("13:45")
                .font(.system(size: 11))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - Controls

struct VPNStatusPlaygroundView: View {
    @State private var params = VPNStatusParams.shared

    /// Which accordions are open, persisted so the window reopens as it was left.
    /// The separator is a real newline in both directions.
    @AppStorage("macauth.vpnStatusPlayground.expanded")
    private var expandedRaw: String = "State\nStatistics\nAppearance\nPanel"

    private var expanded: Set<String> {
        get { Set(expandedRaw.split(separator: "\n").map(String.init)) }
        nonmutating set { expandedRaw = newValue.sorted().joined(separator: "\n") }
    }

    /// Shared row geometry, so every control's trailing edge agrees. Owned by the row helpers
    /// below and applied exactly once: a section that also insets its own stack double-insets
    /// every slider inside it, which is how three sections ended up at three different margins.
    private static let rowInset: CGFloat = 10

    /// Gap between two controls in a section. It has to be clearly larger than the 6 pt between a
    /// label and the slider it names, or a label reads as belonging to the slider above it just as
    /// much as to its own. This is the whole reason the sidebar looked mislabelled.
    private static let rowSpacing: CGFloat = 10

    @State private var copied = false

    var body: some View {
        HSplitView {
            VPNStatusStage(params: params)
                .frame(minWidth: 420)

            controls
                .frame(width: 320)
        }
        .onChange(of: params.signature) { params.save() }
        // Hand the activation policy back, or clicking the menu bar icon afterwards makes AppKit
        // reopen a window of its own choosing.
        .onDisappear { WindowActivation.release() }
    }

    private var controls: some View {
        controlsForm
            // Empty space is not a focus target, so a text field kept first responder (and its
            // focus ring) until some other control took it. Clicking the sidebar background now
            // resigns it, whichever field held it.
            .contentShape(Rectangle())
            .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private var controlsForm: some View {
        Form {
            // The two things being decided right now sit first: which glyph the menu bar draws,
            // and whether the connect control is a switch. The stage-only fakes come after, since
            // they set up a scene rather than change the app.
            accordion("Menu bar") {
                section {
                    picker(
                        "Menu bar icon",
                        $params.menuBarIconSet,
                        MenuBarIconSet.allCases.map { ($0.rawValue, $0.title) }
                    )

                    toggle("Switch instead of Connect button", $params.usesSwitch)

                    // Only while the switch is the control being used: a size picker for a
                    // control that is not on screen is a dead knob.
                    if params.usesSwitch {
                        picker(
                            "Switch size",
                            $params.switchSizeIndex,
                            SwitchSize.allCases.map { ($0.rawValue, $0.title) }
                        )
                    }
                }
            }

            accordion("State") {
                section {
                    picker(
                        "Phase",
                        $params.phaseIndex,
                        PreviewPhase.allCases.map { ($0.rawValue, $0.title) }
                    )

                    if params.phaseIndex == PreviewPhase.connected.rawValue {
                        textField("Assigned IP", $params.assignedIP)
                        slider("Session left", $params.hoursRemaining, 0...12, "h")
                        toggle("DTLS", $params.usingDTLS)
                    }

                    if params.phaseIndex == PreviewPhase.failed.rawValue {
                        textField("Error", $params.errorText)
                    }
                }
            }

            accordion("Statistics") {
                section {
                    slider("Uptime", $params.uptimeHours, 0...12, "h")
                    magnitudeSlider(
                        "Traffic rate",
                        $params.rateExponent,
                        0...9
                    ) { TunnelStats.formatRate($0) }
                    magnitudeSlider(
                        "Transferred",
                        $params.transferredExponent,
                        0...12
                    ) { TunnelStats.formatBytes(UInt64($0)) }
                }
            }

            accordion("Appearance") {
                section {
                    slider("Dot size", $params.dotSize, 5...14, "pt")
                    slider("Countdown size", $params.countdownSize, 8...24, "pt")
                    slider("Countdown margin right", $params.countdownMarginRight, 0...24, "pt")
                }
            }

            accordion("Panel") {
                section {
                    slider("Accounts", $params.accountCount, 0...6)
                }
            }

            Section {
                HStack {
                    Button("Reset to measured") { params.reset() }
                    Spacer()
                    Button(copied ? "Copied" : "Copy as Swift") { copySnippet() }
                }
                .font(.caption)
                .padding(.horizontal, Self.rowInset)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Helpers

    private func copySnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(params.swiftSnippet, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    /// One accordion's worth of controls. The spacing is the only thing that says which label goes
    /// with which slider, so it lives here rather than at each call site, where the three sections
    /// had drifted to 8, 2 and 2.
    private func section(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing, content: content)
    }

    /// A row whose control sits below its label: sliders, whose track has to span the full width.
    ///
    /// The label and its readout are drawn here, never by the control, so a slider row and a
    /// magnitude row cannot end up with different typography.
    private func stackedRow(
        _ label: String,
        _ readout: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(label)
                Spacer(minLength: 8)
                Text(readout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            // `.labelsHidden()` is what makes the track span the row, and it is not optional.
            // Inside `.formStyle(.grouped)` a `Slider` is laid out as a form row with a LEADING
            // LABEL COLUMN, and it reserves that column even though the slider has no label: the
            // track then starts at about 46% of the row width while its label sits at the far
            // left, which is what made every label look detached from the control it names.
            // Measured on a 320 pt sidebar: track started 108 pt in. Of the wrappers that look
            // like they should fix it, none does except this one. `HStack { Slider }`,
            // `LabeledContent` with an `EmptyView` label, `.frame(maxWidth: .infinity)` and
            // `Slider { EmptyView() }` all still reserve the column.
            //
            // The vertical padding is room for the knob, which is taller than its track and casts
            // a shadow past that again.
            control()
                .labelsHidden()
                .padding(.vertical, 4)
        }
        // The inset belongs to the whole row, so labels line up with the track ends. Applied here
        // and nowhere else, or a section that insets its stack too doubles it.
        .padding(.horizontal, Self.rowInset)
    }

    /// A row whose control sits beside its label: switches and popups, which have a natural width.
    ///
    /// The label is a plain `Text` styled directly rather than the control's own, because
    /// `.formStyle(.grouped)` restyles a `Toggle`'s or `Picker`'s built-in label and the
    /// `.font(.caption)` applied from outside loses. That is why one switch label was rendering
    /// bigger than every slider label next to it.
    private func inlineRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, Self.rowInset)
    }

    /// Knobs snap by rounding inside the binding, never with `Slider`'s `step:`, because a step
    /// makes AppKit draw tick marks under the track.
    private func slider(
        _ label: String,
        _ value: Binding<Double>,
        _ range: ClosedRange<Double>,
        _ unit: String = "",
        step: Double? = nil
    ) -> some View {
        let step = step ?? (unit == "pt" || unit.isEmpty ? 1 : 0.1)
        let format = step >= 1 ? "%.0f" : (step >= 0.1 ? "%.1f" : "%.2f")
        let snapped = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = ($0 / step).rounded() * step }
        )
        // Joined rather than interpolated with a space, or a unitless knob reads "2 " and its
        // readout hangs a space short of the rows above it.
        let readout = [String(format: format, value.wrappedValue), unit]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return stackedRow(label, readout) {
            Slider(value: snapped, in: range)
        }
    }

    /// A toggle that matches the sliders: caption label on the left, switch aligned with the
    /// trailing end of every slider track.
    private func toggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        inlineRow(label) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(label)
        }
    }

    /// A popup over an `Int`-tagged choice list.
    ///
    /// Taking `(tag, title)` pairs rather than the enum keeps this free of generics while still
    /// being the only place a popup row is built: a `Picker` written inline at a call site puts its
    /// label at the form's own inset, 10 pt left of every other label in the column, which is
    /// exactly how "Menu bar icon" and "Switch size" ended up out of line.
    ///
    /// `.fixedSize()` rather than a fixed width: a `Picker` given a width centres its popup inside
    /// it, which left the control floating 34 pt short of the trailing edge that every slider
    /// track and switch lines up on. Sized to its content and pushed by the `Spacer`, its trailing
    /// edge is pinned and only its leading edge moves with the selection.
    private func picker(
        _ label: String,
        _ selection: Binding<Int>,
        _ options: [(tag: Int, title: String)]
    ) -> some View {
        inlineRow(label) {
            Picker("", selection: selection) {
                ForEach(options, id: \.tag) { option in
                    Text(option.title).tag(option.tag)
                }
            }
            .labelsHidden()
            .accessibilityLabel(label)
            .font(.caption)
            .fixedSize()
        }
    }

    /// A slider over a power of ten, showing the formatted quantity rather than the exponent.
    ///
    /// Byte figures span nine orders of magnitude, and the layout question is whether the row
    /// still reads at both ends. A linear slider would spend almost all its travel in the top
    /// decade, making the small values unreachable in practice.
    private func magnitudeSlider(
        _ label: String,
        _ exponent: Binding<Double>,
        _ range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        let snapped = Binding(
            get: { exponent.wrappedValue },
            set: { exponent.wrappedValue = ($0 / 0.1).rounded() * 0.1 }
        )

        return stackedRow(label, format(pow(10, exponent.wrappedValue))) {
            Slider(value: snapped, in: range)
        }
    }

    private func textField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
            // The label is drawn above, so the field's own must be hidden. Inside a Section,
            // SwiftUI renders a TextField's title as a leading label, which printed every name
            // twice.
            TextField("", text: text, axis: .vertical)
                .labelsHidden()
                .accessibilityLabel(label)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .lineLimit(1...3)
        }
        .padding(.horizontal, Self.rowInset)
    }

    private func accordion(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        let body = content()
        return Section {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expanded.contains(title) },
                    set: { isOpen in
                        // `expanded` is computed over the stored string, so mutate a copy and
                        // assign it back; calling insert on the getter's result changes nothing.
                        var next = expanded
                        if isOpen { next.insert(title) } else { next.remove(title) }
                        expanded = next
                    }
                )
            ) {
                // Bottom inset too, and more of it than the top: a slider that lands last in a
                // section is drawn with its knob overhanging the track, and the knob's shadow
                // overhangs that again, so 2 pt left a visibly sliced circle.
                body.padding(.top, 4).padding(.bottom, 6)
            } label: {
                Text(title).font(.headline)
            }
        }
    }
}


extension Notification.Name {
    /// Posted whenever a playground knob is saved, so AppKit-side code that reads the params can
    /// redraw. SwiftUI views observing `VPNStatusParams` do not need it.
    static let vpnStatusParamsChanged = Notification.Name("macauth.vpnStatusParamsChanged")
}
