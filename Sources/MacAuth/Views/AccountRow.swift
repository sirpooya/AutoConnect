import MacAuthCore
import SwiftUI

/// One account in the menu: issuer, label, the live code, and a countdown ring.
/// The whole row is the copy button.
struct AccountRow: View {
    @EnvironmentObject private var state: AppState

    let account: Account

    @State private var isHovering = false

    private var wasJustCopied: Bool {
        state.copiedAccountID == account.id
    }

    private var secondsLeft: Int {
        state.secondsRemaining(for: account)
    }

    /// The ring goes amber in the last third and red in the last five seconds.
    private var ringColor: Color {
        if secondsLeft <= 5 { return .red }
        if Double(secondsLeft) <= Double(account.period) / 3 { return .orange }
        return .accentColor
    }

    var body: some View {
        Button(action: { state.copy(account) }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(account.displayTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        if account.usesNonDefaultSettings {
                            Text(settingsSummary)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text(state.formattedCode(for: account))
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(wasJustCopied ? Color.green : Color.primary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: state.code(for: account))

                    if !account.displaySubtitle.isEmpty {
                        Text(account.displaySubtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 4)

                VStack(spacing: 4) {
                    CountdownRing(
                        fraction: state.remainingFraction(for: account),
                        color: ringColor,
                        secondsLeft: secondsLeft
                    )

                    if wasJustCopied {
                        Text("Copied")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.green)
                    } else if isHovering {
                        Text("Copy")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44)
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
            Button("Edit...") { state.route = .edit(account) }
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

    var body: some View {
        PieSlice(fraction: fraction)
            .fill(color)
            .frame(width: 14, height: 14)
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
