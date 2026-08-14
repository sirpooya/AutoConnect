import AutoConnectCore
import SwiftUI

/// One account in the menu: issuer, label, the live code, and a countdown ring.
/// The whole row is the copy button.
struct AccountRow: View {
    @EnvironmentObject private var state: AppState

    /// Live tuning values, the same object VPNSection reads. See the playground.
    private var params: VPNStatusParams { VPNStatusParams.shared }

    let account: Account

    @State private var isHovering = false

    private var wasJustCopied: Bool {
        state.copiedAccountID == account.id
    }

    private var secondsLeft: Int {
        state.secondsRemaining(for: account)
    }

    /// Always neutral. The shrinking wedge already says how much time is left, so colouring it
    /// would only add noise.
    private var ringColor: Color { .secondary }

    var body: some View {
        Button(action: { state.copy(account) }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(account.displayHeading)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if account.usesNonDefaultSettings {
                            Text(settingsSummary)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text(state.formattedCode(for: account))
                        .font(.system(size: 19, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: state.code(for: account))
                }

                Spacer(minLength: 4)

                // The copy confirmation takes the wedge's place instead of being added beside it,
                // so the row keeps its size. Nothing here reacts to hover, for the same reason.
                Group {
                    if wasJustCopied {
                        Text("Copied")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    } else {
                        CountdownPie(
                            fraction: state.remainingFraction(for: account),
                            color: ringColor,
                            secondsLeft: secondsLeft,
                            size: params.countdownSize
                        )
                    }
                }
                // A fixed slot wide enough for "Copied", both contents trailing-aligned, so the
                // swap cannot move anything however the wedge is sized.
                .frame(width: 52, alignment: .trailing)
                .padding(.trailing, params.countdownMarginRight)
                .animation(.easeInOut(duration: 0.15), value: wasJustCopied)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Code") { state.copy(account) }
            Divider()
            Button("Details...") { state.route = .details(account) }
            Button("Delete...") { state.route = .confirmDelete(account) }
        }
        .help("Click to copy \(account.displayTitle) code")
    }

    private var settingsSummary: String {
        var parts: [String] = []
        if account.algorithm != .sha1 { parts.append(account.algorithm.rawValue) }
        if account.digits != TOTP.defaultDigits { parts.append("\(account.digits) digits") }
        if account.period != TOTP.defaultPeriod { parts.append("\(account.period)s") }
        return parts.joined(separator: " / ")
    }
}

/// Solid wedge that empties as the period runs down. The seconds are not spelled out: at a
/// glance the shape answers the only question being asked, which is whether there is time to use
/// the code or whether to wait for the next one.
struct CountdownPie: View {
    let fraction: Double
    let color: Color
    let secondsLeft: Int
    /// 18 pt, settled in the playground against the 19 pt code beside it.
    var size: CGFloat = 18

    var body: some View {
        PieSlice(fraction: fraction)
            .fill(color)
            .frame(width: size, height: size)
            .animation(.linear(duration: 0.95), value: fraction)
            .accessibilityLabel("\(secondsLeft) seconds remaining")
    }
}

/// A filled circular wedge, depleting clockwise from twelve o'clock.
struct PieSlice: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(fraction, 0), 1)
        var path = Path()

        guard clamped > 0 else { return path }
        // A full circle drawn as an arc would leave a seam at the join, so special-case it.
        guard clamped < 1 else {
            path.addEllipse(in: rect)
            return path
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(
            center: center,
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * clamped),
            // SwiftUI's y axis points down, so this sweeps clockwise on screen.
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
