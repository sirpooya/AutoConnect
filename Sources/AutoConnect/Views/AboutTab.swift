import AppKit
import AutoConnectCore
import SwiftUI

/// The About pane: what this build is, where it came from, and what it is running on.
///
/// It exists to answer two questions without leaving the app. "Which version am I on" is the
/// obvious one. The other is what a bug report needs, which for this app is never just the app:
/// the tunnel is `openconnect`, and its version and the OS are as much a part of a failure as
/// anything here. So the same three lines the pane shows are also one button away from the
/// clipboard, rather than being three things to go and look up.
///
/// A separate view, not another computed property on `SettingsView`. That file has already had the
/// type checker give up on one over-long expression, and this pane shares no state with the others.
struct AboutTab: View {

    /// Taken from the settings pane rather than read again here, so a path edited on the General
    /// tab is the one probed, not the one last saved.
    let openconnectPath: String

    /// Nil until the probe answers, and nil for good if there is no binary to ask.
    @State private var openconnectVersion: String?

    var body: some View {
        SettingsTabBody {
            header

            SettingsFootnote(
                text: "A menu-bar connector for a Cisco SAML gateway, with the authenticator that "
                    + "fills in its own one-time code. Apple frameworks only. No account, no "
                    + "sync, and no telemetry of any kind."
            )

            sourceSection
            systemSection

            SettingsFootnote(
                text: "Secrets stay in this Mac's Keychain and never leave it. Because the "
                    + "corporate password and the TOTP seed are both here, this Mac alone "
                    + "satisfies both factors: keep it locked."
            )
        }
        // Spawning openconnect takes milliseconds, but it is still a process, and the pane must
        // not be waiting on one. Re-runs if the configured path changes underneath it.
        .task(id: openconnectPath) {
            let path = openconnectPath
            openconnectVersion = await Task.detached { OpenConnectVersion.read(at: path) }.value
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
            }
            .padding(.horizontal, SettingsMetrics.rowHPadding)
            .padding(.vertical, 12)
        }
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

        SettingsFootnote(
            text: "The tunnel itself is openconnect, a separate program under the LGPL. This app "
                + "launches the copy installed on this Mac; it does not bundle or modify it."
        )
    }

    /// The three lines a report needs, and the button that takes all three at once.
    @ViewBuilder
    private var systemSection: some View {
        SettingsSectionHeader(text: "This Mac")
            .padding(.top, 10)

        SettingsCard {
            SettingsRow(title: "macOS") {
                Text(systemVersion)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            SettingsDivider()
            SettingsRow(title: "openconnect") {
                Text(openconnectVersion.map { "Version \($0)" } ?? "Not installed")
                    .font(.system(size: 12))
                    .foregroundStyle(openconnectVersion == nil ? .orange : .secondary)
            }
            SettingsDivider()
            SettingsRow(title: "Version details") {
                SettingsCopyButton(title: "Copy", value: diagnostics)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - What to show

    private static let repository = URL(string: "https://github.com/sirpooya/osx-auth-qr")!
    private static let issues = URL(string: "https://github.com/sirpooya/osx-auth-qr/issues")!

    /// Read from the bundle rather than compiled in, so `make-app.sh` stamping a version is the
    /// single place a version number lives. `swift run` has no Info.plist at all, and saying so
    /// is more use than a number that would be a guess.
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

    private var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The slice actually running, not what the build produced. The app is universal, so on an
    /// Intel Mac and under Rosetta this says x86_64 where `uname -m` from a terminal may not.
    private var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private var diagnostics: String {
        let openconnect = openconnectVersion.map { "openconnect \($0)" }
            ?? "openconnect not installed"
        return """
            AutoConnect \(appVersion)
            macOS \(systemVersion) (\(architecture))
            \(openconnect) at \(openconnectPath)
            """
    }
}
