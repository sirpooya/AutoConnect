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

    /// How far the halo grows while a connect is in progress. 1.6x is the smallest scale that
    /// reads as "working" without the halo colliding with the label baseline.
    var pulseScale: Double = 1.6

    /// One breath of the working pulse. 0.9 s matches the pace of the system's own indeterminate
    /// indicators; faster reads as agitated, slower reads as stalled.
    var pulseDuration: Double = 0.9

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

    func save() { VPNStatusSnapshot(self).save() }

    private func apply(_ snapshot: VPNStatusSnapshot) {
        dotSize = snapshot.dotSize
        pulseScale = snapshot.pulseScale
        pulseDuration = snapshot.pulseDuration
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
            dotSize, pulseScale, pulseDuration,
            Double(phaseIndex), hoursRemaining, usingDTLS ? 1 : 0, accountCount,
            uptimeHours, rateExponent, transferredExponent,
            Double(assignedIP.hashValue & 0xffff), Double(errorText.hashValue & 0xffff),
        ]
    }

    /// Only the shipping values. The stage-only fakes are deliberately absent: they describe the
    /// mock, not the app.
    var swiftSnippet: String {
        """
        // VPN status row
        static let vpnDotSize: CGFloat = \(Int(dotSize))
        static let vpnPulseScale: CGFloat = \(String(format: "%.1f", pulseScale))
        static let vpnPulseDuration: TimeInterval = \(String(format: "%.1f", pulseDuration))
        """
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
    var pulseScale: Double
    var pulseDuration: Double
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
        pulseScale = params.pulseScale
        pulseDuration = params.pulseDuration
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
        pulseScale = value(.pulseScale, 1.6)
        pulseDuration = value(.pulseDuration, 0.9)
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
struct VPNStatusStage: View {
    var params: VPNStatusParams

    /// Rebuilt whenever the fake state changes, so the real `VPNSection` renders it unmodified.
    private var mockController: VPNController {
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

            MenuPanel()
                .environmentObject(mockState)
                .environmentObject(mockController)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                .padding(40)
                // Identity keyed on the fake state so the panel rebuilds when a knob moves,
                // rather than caching a stale controller.
                .id(params.signature.description)
        }
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

    /// Shared row geometry, so every control's trailing edge agrees.
    private static let rowInset: CGFloat = 10

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
        Form {
            accordion("State") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Phase", selection: $params.phaseIndex) {
                        ForEach(PreviewPhase.allCases) { phase in
                            Text(phase.title).tag(phase.rawValue)
                        }
                    }
                    .font(.caption)

                    if params.phaseIndex == PreviewPhase.connected.rawValue {
                        textField("Assigned IP", $params.assignedIP)
                        slider("Session left", $params.hoursRemaining, 0...12, "h")
                        toggle("DTLS", $params.usingDTLS)
                    }

                    if params.phaseIndex == PreviewPhase.failed.rawValue {
                        textField("Error", $params.errorText)
                    }
                }
                .padding(.horizontal, Self.rowInset)
            }

            accordion("Statistics") {
                VStack(alignment: .leading, spacing: 2) {
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
                .padding(.horizontal, Self.rowInset)
            }

            accordion("Appearance") {
                VStack(alignment: .leading, spacing: 2) {
                    slider("Dot size", $params.dotSize, 5...14, "pt")
                    slider("Pulse scale", $params.pulseScale, 1...2.5, "x")
                    slider("Pulse duration", $params.pulseDuration, 0.3...2, "s")
                }
            }

            accordion("Panel") {
                slider("Accounts", $params.accountCount, 0...6, "")
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

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue, specifier: format) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            // Vertical room for the knob, which is taller than its track.
            Slider(value: snapped, in: range)
                .padding(.vertical, 3)
        }
        // The inset belongs to the whole row, so labels line up with the track ends.
        .padding(.horizontal, Self.rowInset)
    }

    /// A toggle sized to match the sliders: a bare `Toggle` renders its label at body size.
    private func toggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .font(.caption)
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

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(format(pow(10, exponent.wrappedValue)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Slider(value: snapped, in: range)
                .padding(.vertical, 3)
        }
        .padding(.horizontal, Self.rowInset)
    }

    private func textField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
            TextField(label, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .lineLimit(1...3)
        }
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
                // Bottom inset too, or the section's clip cuts the last slider's knob in half.
                body.padding(.top, 4).padding(.bottom, 2)
            } label: {
                Text(title).font(.headline)
            }
        }
    }
}
