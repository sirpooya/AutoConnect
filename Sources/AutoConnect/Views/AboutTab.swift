import AppKit
import SwiftUI

/// The About pane: what this build is, and where it came from.
///
/// A separate view, not another computed property on `SettingsView`. That file has already had the
/// type checker give up on one over-long expression, and this pane shares no state with the others.
struct AboutTab: View {

    /// The process-wide Sparkle wrapper. Observed rather than read once, so the button disables
    /// itself while a check is running and "Last checked" moves when one finishes.
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        SettingsTabBody {
            header

            SettingsFootnote(
                text: "A menu-bar connector for a Cisco gateway over the AnyConnect protocol, "
                    + "signing in with SAML, and the authenticator that fills in its own "
                    + "one-time code. The tunnel itself is openconnect, a separate program "
                    + "under the LGPL; this app launches the copy installed on this Mac and "
                    + "does not bundle or modify it."
            )

            updatesSection
            sourceSection
        }
    }

    // MARK: - Sections

    /// Icon, name, version. The icon is the one macOS is already drawing for this app, so a
    /// rebuild with new artwork cannot leave this pane showing the old one.
    private var header: some View {
        SettingsCard {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("AutoConnect")
                        .font(.system(size: 15, weight: .semibold))
                    Text(appVersion)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 10)

                // Beside the version, because "which version am I on" and "is there a newer one"
                // are the same question asked twice.
                Button("Check Now") {
                    updates.checkForUpdates()
                }
                .controlSize(.small)
                .disabled(!updates.canCheckForUpdates)
            }
            .padding(.horizontal, SettingsMetrics.rowHPadding)
            .padding(.vertical, 12)
        }
    }

    /// Automatic checks, and when the last one happened.
    ///
    /// The switch is Sparkle's own preference rather than a defaults key of ours, so turning it off
    /// stops the scheduled cycle instead of only hiding it. The date earns its row because a check
    /// that finds nothing says nothing: without it there is no way to tell "up to date" from
    /// "never asked".
    @ViewBuilder
    private var updatesSection: some View {
        SettingsSectionHeader(text: "Updates")
            .padding(.top, 10)

        SettingsCard {
            SettingsRow(title: "Check automatically") {
                SettingsSwitch(isOn: $updates.checksAutomatically)
            }
            SettingsDivider()
            SettingsRow(title: "Last checked") {
                Text(lastCheckedText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!updates.isAvailable)

        SettingsFootnote(
            text: updates.isAvailable
                ? "Once a day, in the background, and never while the tunnel is up: installing an "
                    + "update restarts the app, which would take the connection down with it."
                : "Updates need the packaged app. An unpackaged build has no Info.plist, so there "
                    + "is no feed to read."
        )
    }

    @ViewBuilder
    private var sourceSection: some View {
        SettingsSectionHeader(text: "Source")
            .padding(.top, 10)

        SettingsCard {
            SettingsRow(title: "Made by Sirpooya") {
                Link("View on GitHub", destination: Self.repository)
                    .font(.system(size: 12))
            }
            SettingsDivider()
            SettingsRow(title: "Something wrong?") {
                Link("Report an issue", destination: Self.issues)
                    .font(.system(size: 12))
            }
        }
    }

    // MARK: - What to show

    /// The repo the README sends people to for releases. The `osx-auth-qr` name it was pushed
    /// under first is gone, so nothing here should point at it.
    private static let repository = URL(string: "https://github.com/sirpooya/AutoConnect")!
    private static let issues = URL(string: "https://github.com/sirpooya/AutoConnect/issues")!

    /// Read from the bundle rather than compiled in, so `make-app.sh` stamping a version is the
    /// single place a version number lives. `swift run` has no Info.plist at all, and saying so
    /// is more use than a number that would be a guess.
    /// Relative, because the exact minute never matters; whether it was today or a month ago does.
    private var lastCheckedText: String {
        guard updates.isAvailable else { return "Unavailable" }
        guard let date = updates.lastCheck else { return "Never" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        switch (short, build) {
        case let (.some(short), .some(build)): return "Version \(short) (\(build))"
        case let (.some(short), .none): return "Version \(short)"
        default: return "Unpackaged build"
        }
    }

}
