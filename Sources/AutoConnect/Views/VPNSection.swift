import AutoConnectCore
import SwiftUI

/// VPN status at the top of the menu: the gateway it dials, the state, and while connected a
/// collapsible block of statistics. Replaces what AnyConnect's window used to show.
struct VPNSection: View {
    @EnvironmentObject private var vpn: VPNController
    /// Only so the Set Up button can hand the settings window the same objects the panel uses.
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var notifier: VPNStatusNotifier

    /// Live from the playground, so the dot and its pulse can be tuned while running.
    private var params: VPNStatusParams { VPNStatusParams.shared }

    /// Whether the statistics block is open. Persisted, so it reopens as it was left.
    @AppStorage("autoconnect.vpnDetailsExpanded") private var showDetails = false

    /// Holds each phase on screen long enough to be read, however fast the real ones move.
    ///
    /// The **phase** is paced, not the status string. Pacing the string alone left the rest of the
    /// row on the real phase, so a connect that finished while the steps were still queued showed a
    /// green dot beside "Waiting for sign-in". Everything that describes state reads `shown`.
    @State private var pacer = StatusPacer<VPNController.Phase>()

    /// The phase the row is describing, which trails the real one by at most the dwell.
    private var shown: VPNController.Phase { pacer.shown ?? vpn.phase }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                statusDot

                connectionTitle

                Spacer(minLength: 4)

                actionButton
            }

            if case .connected = shown {
                connectedSummary
            }

            if case .failed(let message) = shown {
                errorRow(message)
            }

            // While openconnect retries by itself, say so and say why. The address shown above is
            // the one it is trying to keep, not one that is currently carrying traffic.
            if case .reconnecting = shown {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)

                    Text(vpn.reconnectReason ?? "The tunnel stopped responding.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { submitPhase() }
        .onChange(of: vpn.phase) { submitPhase() }
    }

    private func submitPhase() {
        pacer.submit(
            vpn.phase,
            minimumDwell: params.statusMinimumDwell,
            immediately: interruptsSequence,
            // Connecting shows one line; connected adds the pill row, so the block changes height
            // and the panel with it. The spring goes to the pacer rather than onto this view,
            // because the pacer owns the moment the phase changes and `withAnimation` there covers
            // the ancestors that do the resizing. The popover follows too: `StatusItemController`
            // gives its hosting controller `.preferredContentSize`, so each frame of the spring is
            // a new content size.
            animation: .spring(
                duration: params.rowResizeDuration,
                bounce: params.rowResizeBounce
            )
        )
    }

    // MARK: - Which connection

    /// The active connection, and a way to switch when there is more than one.
    ///
    /// The name is what the user called the combination of gateway, credentials and OTP
    /// account, so it is the honest label for what Connect is about to do.
    @ViewBuilder
    private var connectionTitle: some View {
        if vpn.profiles.count > 1 {
            Menu {
                ForEach(vpn.profiles) { item in
                    Button {
                        vpn.select(profileID: item.id)
                    } label: {
                        // A tick marks the active one, the way a macOS menu shows a choice.
                        Label(
                            item.displayName,
                            systemImage: item.id == vpn.profile.id ? "checkmark" : ""
                        )
                    }
                }
            } label: {
                titleLines(showsChevron: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(vpn.isConnected)
            .help(vpn.isConnected
                  ? "Disconnect before switching connection."
                  : "Switch connection")
        } else {
            titleLines(showsChevron: false)
        }
    }

    private func titleLines(showsChevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if showsChevron {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            // Status on its own line, not beside the title: sharing the line left the title too
            // little room and wrapped the address in half. The gateway address is not repeated
            // here, it is already the title when no account is set, and Settings owns it.
            //
            // One size throughout, matching the account rows below. Weight and colour carry the
            // hierarchy; a different size per line made the block look assembled from spare parts.
            //
            // Nothing configured means no status: every wording of it either repeats the title or
            // repeats the Set Up button beside it, and "Not connected" invites waiting for a
            // connection nothing will ever start.
            if isConfigured {
                // Only the four connect steps and reconnecting shimmer. Those are the states where
                // the app is waiting on something and nothing else on screen moves; "Not
                // connected", "Connected" and "Failed" are settled, and a highlight crossing them
                // says work is under way when none is.
                StatusLine(text: shown.label, isShimmering: shown.isWorking)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The gateway this connection dials. Not the username: that is the account row below, and
    /// showing it here printed the same address twice in one small panel.
    ///
    /// With nothing saved there is no gateway to name, so the row names what it is instead.
    /// "New connection" is the editor's word for a row being filled in, and at the top of the
    /// panel it read as if one were already underway.
    private var title: String {
        vpn.profiles.isEmpty ? "No connection" : vpn.profile.displayName
    }


    /// Whether this connection has everything a connect needs: an address, a group and a pin.
    private var isConfigured: Bool { vpn.profile.isComplete }

    /// Whether this status cuts the sequence short rather than continuing it, and so skips the
    /// pacer's queue.
    ///
    /// Four do. Two answer a click and must not wait behind anything: a disconnect, and the first
    /// step of a connect, which is the only feedback that the switch did something. The other two
    /// are news that nobody sees if it queues: a failure, and a drop into reconnecting.
    ///
    /// **`connected` is not one of them.** It used to be, as "anything that is not working", and
    /// that made the dwell knob look broken: the end of a connect arrived while the steps were still
    /// queued and flushed every one of them, so the line jumped from "Not connected" straight to
    /// "Connected" whatever the dwell was set to. Only the *first* step of a connect skips the
    /// queue; the ones after it are what the dwell exists to pace.
    private var interruptsSequence: Bool {
        switch vpn.phase {
        case .idle, .contactingGateway, .failed, .reconnecting: true
        default: false
        }
    }

    // MARK: - Connected

    /// The two things worth knowing at a glance, then everything else behind a disclosure.
    private var connectedSummary: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                if let ip = vpn.tunnel?.assignedIP {
                    pill(ip, icon: "network")
                }
                if let remaining = vpn.timeRemaining {
                    pill(remaining, icon: "clock")
                }

                Spacer(minLength: 0)

                Button(action: { showDetails.toggle() }) {
                    HStack(spacing: 2) {
                        Text(showDetails ? "Less" : "Details")
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if showDetails {
                statistics
                    // Counters are sampled by spawning netstat, so only poll while visible.
                    .onAppear { vpn.setStatsPolling(true) }
                    .onDisappear { vpn.setStatsPolling(false) }
            }
        }
    }

    private var statistics: some View {
        VStack(spacing: 3) {
            ThroughputChart(samples: vpn.history)
                .padding(.bottom, 3)

            if let stats = vpn.tunnel?.stats {
                statRow(
                    "Traffic",
                    "\(stats.formattedRateIn) down  \(stats.formattedRateOut) up"
                )
                statRow(
                    "Transferred",
                    "\(stats.formattedIn) down  \(stats.formattedOut) up"
                )
                // AnyConnect calls these "Frames".
                statRow(
                    "Packets",
                    "\(stats.packetsIn.formatted()) in  \(stats.packetsOut.formatted()) out"
                )
            }

            if let uptime = vpn.uptime {
                statRow("Uptime", uptime)
            }
            if let endpoint = vpn.tunnel?.gatewayEndpoint {
                statRow("Gateway", endpoint)
            }
            if let mode = vpn.tunnel?.tunnelMode {
                statRow("Tunnel mode", mode)
            }
            if let routes = vpn.tunnel?.routeSummary {
                statRow("Routes", routes)
            }
            if let transport = vpn.tunnel?.transport {
                statRow("Protocol", transport)
            }
            if let suite = vpn.tunnel?.ciphersuite ?? vpn.tunnel?.cipher {
                statRow("Cipher", suite)
            }
            if let interface = vpn.tunnel?.interface {
                statRow("Interface", interface)
            }
            if let mtu = vpn.tunnel?.stats?.mtu {
                statRow("MTU", "\(mtu)")
            }
        }
        .padding(.top, 2)
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 9))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func pill(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 9))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    // MARK: - Failure

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Neutral, not a coloured alert glyph. The text already says what went wrong, and the
            // status dot is the one thing in this panel that carries state as colour.
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: { vpn.clearError() }) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    // MARK: - Status dot

    /// A plain dot in every state. No halo, no pulse: the colour already carries the state, and a
    /// ring that only some states draw makes the dot change size as well as colour.
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: params.dotSize, height: params.dotSize)
    }

    private var statusColor: Color {
        switch shown {
        case .connected: return .green
        case .failed: return .red
        case .idle: return .secondary
        default: return .orange
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if !isConfigured {
            setUpButton
        } else if params.usesSwitch {
            connectSwitch
        } else if vpn.isConnected {
            Button("Disconnect") { vpn.disconnect() }
                .controlSize(.small)
        } else if vpn.phase.isWorking {
            Button("Cancel") { vpn.disconnect() }
                .controlSize(.small)
        } else {
            Button("Connect") { vpn.connect() }
                .controlSize(.small)
                .keyboardShortcut("k")
        }
    }

    /// What stands in for the switch until there is something to connect to.
    ///
    /// A switch with no gateway behind it is a control that cannot do what it offers, and a
    /// disabled one says only that. This says what is missing and goes to the page that fixes it,
    /// which is the whole of what the panel can do about it.
    private var setUpButton: some View {
        Button("Set Up") {
            SettingsWindow.shared.show(
                state: state, vpn: vpn, notifier: notifier, tab: .connections
            )
        }
        .controlSize(.small)
        .help(vpn.profiles.isEmpty
              ? "Add a connection in Settings."
              : "Finish setting up this connection in Settings.")
    }

    /// The switch alternative. It reads as state rather than as an instruction, and it has one
    /// honest problem the button does not: a connect takes seconds and can fail, so the switch is
    /// on while nothing is connected yet. It stays on during the working phases and flips back if
    /// the attempt fails, which is why the status line still has to say what is happening.
    private var connectSwitch: some View {
        Toggle("", isOn: Binding(
            get: { vpn.isConnected || vpn.phase.isWorking },
            set: { wantsOn in wantsOn ? vpn.connect() : vpn.disconnect() }
        ))
        .toggleStyle(.switch)
        .controlSize(params.switchControlSize)
        .labelsHidden()
        .help(vpn.isConnected ? "Disconnect" : "Connect")
    }
}
