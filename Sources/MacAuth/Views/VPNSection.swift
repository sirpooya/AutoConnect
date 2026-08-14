import MacAuthCore
import SwiftUI

/// VPN status at the top of the menu: the gateway it dials, the state, and while connected a
/// collapsible block of statistics. Replaces what AnyConnect's window used to show.
struct VPNSection: View {
    @EnvironmentObject private var vpn: VPNController

    /// Live from the playground, so the dot and its pulse can be tuned while running.
    private var params: VPNStatusParams { VPNStatusParams.shared }

    /// Whether the statistics block is open. Persisted, so it reopens as it was left.
    @AppStorage("macauth.vpnDetailsExpanded") private var showDetails = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                statusDot

                connectionTitle

                Spacer(minLength: 4)

                actionButton
            }

            if vpn.isConnected {
                connectedSummary
            }

            if case .failed(let message) = vpn.phase {
                errorRow(message)
            }

            // While openconnect retries by itself, say so and say why. The address shown above is
            // the one it is trying to keep, not one that is currently carrying traffic.
            if case .reconnecting = vpn.phase {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)

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
            Text(vpn.phase.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The gateway this connection dials. Not the username: that is the account row below, and
    /// showing it here printed the same address twice in one small panel.
    private var title: String {
        vpn.profile.displayName
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
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)

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
        switch vpn.phase {
        case .connected: return .green
        case .failed: return .red
        case .idle: return .secondary
        default: return .orange
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if vpn.isConnected {
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
}
