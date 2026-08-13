import MacAuthCore
import SwiftUI

/// Settings for the VPN connection. Nothing here is hardcoded: the gateway, the group, the
/// username, the password and which authenticator account supplies the OTP are all chosen here
/// and persisted, so the same build works for any Cisco SAML gateway.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var vpn: VPNController

    private let store = VPNSettingsStore()

    @State private var host = ""
    @State private var tunnelGroup = ""
    @State private var username = ""
    @State private var password = ""
    @State private var passwordIsStored = false
    @State private var otpAccountID: UUID?
    @State private var certificateSHA1 = ""
    @State private var openconnectPath = ""
    @State private var status: String?

    var body: some View {
        Form {
            Section("Gateway") {
                LabeledContent("Address") {
                    TextField("vpn.example.com:443", text: $host)
                }
                LabeledContent("Group") {
                    TextField("MFA-VPN", text: $tunnelGroup)
                }
                LabeledContent("Certificate SHA1") {
                    TextField("optional, pins the gateway", text: $certificateSHA1)
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            Section("Sign-in") {
                LabeledContent("Username") {
                    TextField("you@example.com", text: $username)
                }

                LabeledContent("Password") {
                    HStack(spacing: 6) {
                        SecureField(
                            passwordIsStored ? "Stored in Keychain" : "Not set",
                            text: $password
                        )

                        if passwordIsStored {
                            Button("Remove") { removePassword() }
                                .controlSize(.small)
                        }
                    }
                }

                Picker("OTP from", selection: $otpAccountID) {
                    Text("Type it manually").tag(UUID?.none)
                    ForEach(state.accounts) { account in
                        Text(accountLabel(account)).tag(UUID?.some(account.id))
                    }
                }

                if state.accounts.isEmpty {
                    Text("Add an account in the menu to use its code automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("openconnect") {
                LabeledContent("Binary") {
                    TextField("/opt/homebrew/bin/openconnect", text: $openconnectPath)
                        .font(.system(size: 11, design: .monospaced))
                }

                if !binaryExists {
                    Label(
                        "Not found. Install with: brew install openconnect",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section {
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
            } footer: {
                Text("The password and the OTP secret both live in this Mac's Keychain. "
                     + "Storing them together means this Mac alone satisfies both factors.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
        .onDisappear { WindowActivation.release() }
    }

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
