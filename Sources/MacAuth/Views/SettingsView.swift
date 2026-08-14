import MacAuthCore
import SwiftUI

/// Settings for the VPN connection, split into three tabs: where to connect, who
/// to connect as, and how the app behaves. Nothing here is hardcoded: the
/// gateway, the group, the username, the password and which authenticator
/// account supplies the OTP are all chosen here and persisted, so the same build
/// works for any Cisco SAML gateway.
///
/// All of the edited fields live in this shell rather than in the tab views, so
/// switching tabs never discards a half-typed value. There is no Save button:
/// every field writes through as you edit it, the way a macOS settings pane is
/// expected to behave. The password is the one exception, since a half-typed
/// password is not worth storing: it commits when the field loses focus or you
/// press Return.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var vpn: VPNController

    private let store = VPNSettingsStore()

    @State private var tab: Tab = .gateway

    @State private var host = ""
    @State private var tunnelGroup = ""
    @State private var username = ""
    @State private var password = ""
    @State private var passwordIsStored = false
    @State private var otpAccountID: UUID?
    @State private var certificateSHA1 = ""
    @State private var openconnectPath = ""
    @State private var status: String?
    @State private var launchAtLogin = false
    /// Guards the write-through: `load` assigns every field, and those assignments
    /// would otherwise each look like an edit and save the profile straight back.
    @State private var isLoaded = false

    @FocusState private var passwordFocused: Bool

    enum Tab: Hashable {
        case gateway, signIn, behaviour
    }

    var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $tab)
            Divider().overlay(Color.primary.opacity(0.03))

            Group {
                switch tab {
                case .gateway:
                    gatewayTab
                case .signIn:
                    signInTab
                case .behaviour:
                    behaviourTab
                }
            }
            .frame(minHeight: SettingsMetrics.bodyHeight, maxHeight: .infinity, alignment: .top)
        }
        // The window owns the size (see SettingsWindow); the content just fills it.
        .frame(
            minWidth: SettingsMetrics.windowWidth,
            minHeight: SettingsMetrics.windowHeight
        )
        .onAppear(perform: load)
        .onChange(of: host) { _, _ in persist() }
        .onChange(of: tunnelGroup) { _, _ in persist() }
        .onChange(of: username) { _, _ in persist() }
        .onChange(of: certificateSHA1) { _, _ in persist() }
        .onChange(of: openconnectPath) { _, _ in persist() }
        .onChange(of: otpAccountID) { _, _ in persist() }
        .onChange(of: passwordFocused) { _, focused in
            if !focused { savePassword() }
        }
        .onDisappear {
            savePassword()
            WindowActivation.release()
        }
    }

    // MARK: - Tabs

    private var gatewayTab: some View {
        SettingsTabBody {
            SettingsSectionHeader(text: "Gateway")
            SettingsCard {
                SettingsFieldRow(
                    title: "Address",
                    placeholder: "vpn.example.com:443",
                    text: $host
                )
                SettingsDivider()
                SettingsFieldRow(
                    title: "Group",
                    placeholder: "MFA-VPN",
                    text: $tunnelGroup
                )
            }
            SettingsFootnote(text: "The tunnel group the gateway offers on its login page.")

            SettingsSectionHeader(text: "Security")
                .padding(.top, 10)
            SettingsCard {
                SettingsFieldRow(
                    title: "Certificate SHA1",
                    placeholder: "optional",
                    text: $certificateSHA1,
                    monospaced: true
                )
            }
            SettingsFootnote(
                text: "Pins the gateway certificate. Leave it empty to fall back to the "
                    + "system trust store."
            )
        }
    }

    private var signInTab: some View {
        SettingsTabBody {
            SettingsSectionHeader(text: "Credentials")
            SettingsCard {
                SettingsFieldRow(
                    title: "Username",
                    placeholder: "you@example.com",
                    text: $username
                )
                SettingsDivider()
                SettingsRow(title: "Password") {
                    HStack(spacing: 6) {
                        SecureField(
                            passwordIsStored ? "Stored in Keychain" : "Not set",
                            text: $password
                        )
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 13))
                        .focused($passwordFocused)
                        .onSubmit { savePassword() }

                        if passwordIsStored {
                            Button("Remove") { removePassword() }
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: SettingsMetrics.fieldWidth)
                }
            }

            SettingsSectionHeader(text: "One-time code")
                .padding(.top, 10)
            SettingsCard {
                SettingsRow(title: "OTP from") {
                    Picker("", selection: $otpAccountID) {
                        Text("Type it manually").tag(UUID?.none)
                        ForEach(state.accounts) { account in
                            Text(accountLabel(account)).tag(UUID?.some(account.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: SettingsMetrics.fieldWidth)
                }
            }

            if state.accounts.isEmpty {
                SettingsFootnote(
                    text: "Add an account in the menu to use its code automatically."
                )
            }

            SettingsFootnote(
                text: status ?? "The password and the OTP secret both live in this Mac's "
                    + "Keychain. Storing them together means this Mac alone satisfies both "
                    + "factors."
            )
            .padding(.top, 4)
        }
    }

    private var behaviourTab: some View {
        SettingsTabBody {
            SettingsSectionHeader(text: "Connection")
            SettingsCard {
                SettingsRow(title: "Reconnect automatically") {
                    Toggle("", isOn: $vpn.autoReconnect)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            SettingsFootnote(
                text: "Renews the session five minutes before the gateway expires it, and "
                    + "restores the tunnel if it drops or the network changes. Never connects "
                    + "on its own before you have connected once."
            )

            SettingsSectionHeader(text: "Startup")
                .padding(.top, 10)
            SettingsCard {
                SettingsRow(title: "Launch at login") {
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, enabled in
                            if let message = LaunchAtLogin.set(enabled) {
                                status = message
                                // Reflect what macOS actually did, not what was asked for.
                                launchAtLogin = LaunchAtLogin.isEnabled
                            }
                        }
                }
            }

            SettingsSectionHeader(text: "openconnect")
                .padding(.top, 10)
            SettingsCard {
                SettingsFieldRow(
                    title: "Binary",
                    placeholder: "/opt/homebrew/bin/openconnect",
                    text: $openconnectPath,
                    monospaced: true
                )
            }

            if !binaryExists {
                SettingsFootnote(text: "Not found. Install with: brew install openconnect")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Save bar

    private var saveBar: some View {
        HStack {
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - State

    private var binaryExists: Bool {
        FileManager.default.isExecutableFile(atPath: openconnectPath)
    }

    private func accountLabel(_ account: Account) -> String {
        account.displaySubtitle.isEmpty
            ? account.displayTitle
            : "\(account.displayTitle): \(account.displaySubtitle)"
    }

    private func load() {
        let profile = vpn.profile
        host = profile.host
        tunnelGroup = profile.tunnelGroup
        username = profile.username
        certificateSHA1 = profile.certificateSHA1 ?? ""
        openconnectPath = profile.openconnectPath
        otpAccountID = profile.otpAccountID
        passwordIsStored = store.hasPassword(account: profile.credentialAccount)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private func save() {
        var profile = vpn.profile
        profile.host = host.trimmingCharacters(in: .whitespaces)
        profile.tunnelGroup = tunnelGroup.trimmingCharacters(in: .whitespaces)
        profile.username = username.trimmingCharacters(in: .whitespaces)
        profile.certificateSHA1 = certificateSHA1.isEmpty ? nil : certificateSHA1
        profile.openconnectPath = openconnectPath.trimmingCharacters(in: .whitespaces)
        profile.otpAccountID = otpAccountID

        if !password.isEmpty {
            do {
                try store.savePassword(password, account: profile.credentialAccount)
                // Drop the plaintext as soon as the Keychain has it.
                password = ""
                passwordIsStored = true
            } catch {
                status = "Could not save the password: \(error)"
                return
            }
        }

        store.save(profile: profile)
        vpn.profile = profile
        status = "Saved"

        Task {
            try? await Task.sleep(for: .seconds(2))
            status = nil
        }
    }

    private func removePassword() {
        do {
            try store.deletePassword(account: vpn.profile.credentialAccount)
            passwordIsStored = false
            status = "Password removed"
        } catch {
            status = "Could not remove the password: \(error)"
        }
    }
}

// MARK: - Top tab bar

private struct TabBar: View {
    @Binding var selection: SettingsView.Tab

    var body: some View {
        HStack(spacing: 8) {
            TabButton(title: "Gateway", systemImage: "network",
                      isSelected: selection == .gateway) { selection = .gateway }
            TabButton(title: "Sign-in", systemImage: "person.badge.key.fill",
                      isSelected: selection == .signIn) { selection = .signIn }
            TabButton(title: "Behaviour", systemImage: "switch.2",
                      isSelected: selection == .behaviour) { selection = .behaviour }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private struct TabButton: View {
        let title: String
        let systemImage: String
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: 3) {
                    Image(systemName: systemImage)
                        .font(.system(size: 18))
                    Text(title)
                        .font(.system(size: 11))
                }
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 78)
                .padding(.vertical, 7)
                .background(
                    // Neutral grey pill behind the selected tab; the accent lives in
                    // the icon and label, not the fill.
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Color.primary.opacity(0.06) : .clear)
                )
                // The whole pill is clickable, not just the glyphs.
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
