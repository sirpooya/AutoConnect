import MacAuthCore
import SwiftUI

/// VPN status at the top of the menu: state, assigned IP, time left, and one button.
/// Replaces what AnyConnect's window used to show.
struct VPNSection: View {
    @EnvironmentObject private var vpn: VPNController

    /// Live from the playground, so the dot and its pulse can be tuned while running.
    private var params: VPNStatusParams { VPNStatusParams.shared }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                statusDot

                VStack(alignment: .leading, spacing: 1) {
                    Text(vpn.profile.tunnelGroup)
                        .font(.system(size: 11, weight: .semibold))

                    Text(detailLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                actionButton
            }

            if case .failed(let message) = vpn.phase {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: params.dotSize, height: params.dotSize)
            .overlay(
                Circle()
                    .stroke(statusColor.opacity(0.3), lineWidth: 4)
                    .scaleEffect(vpn.phase.isWorking ? params.pulseScale : 1)
                    .animation(
                        vpn.phase.isWorking
                            ? .easeInOut(duration: params.pulseDuration)
                                .repeatForever(autoreverses: true)
                            : .default,
                        value: vpn.phase.isWorking
                    )
            )
    }

    private var statusColor: Color {
        switch vpn.phase {
        case .connected: return .green
        case .failed: return .red
        case .idle: return .secondary
        default: return .orange
        }
    }

    /// One line that answers "is it up, on what address, and for how long".
    private var detailLine: String {
        switch vpn.phase {
        case .connected(let tunnel):
            var parts: [String] = []
            if let ip = tunnel.assignedIP { parts.append(ip) }
            if let remaining = vpn.timeRemaining { parts.append("\(remaining) left") }
            if tunnel.usingDTLS { parts.append("DTLS") }
            return parts.isEmpty ? "Connected" : parts.joined(separator: "  ")
        default:
            return vpn.phase.label
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
