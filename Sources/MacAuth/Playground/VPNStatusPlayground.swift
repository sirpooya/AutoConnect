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
    }

    /// Autosave watches this, and the stage rebuilds its mock controller from it.
    var signature: [Double] {
        [
            dotSize, pulseScale, pulseDuration,
            Double(phaseIndex), hoursRemaining, usingDTLS ? 1 : 0, accountCount,
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
        case .connected:
            let tunnel = OpenConnectRunner.Tunnel(
                assignedIP: params.assignedIP.isEmpty ? nil : params.assignedIP,
                usingDTLS: params.usingDTLS,
                sessionExpiry: reference.addingTimeInterval(params.hoursRemaining * 3600)
            )
            return .preview(phase: .connected(tunnel), referenceDate: reference)
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
    private var expandedRaw: String = "State\nAppearance\nPanel"

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
