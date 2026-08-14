import MacAuthCore
import SwiftUI

/// Adds or edits one connection: a name, a gateway address, and whatever the gateway itself
/// tells us about its tunnel groups and certificate.
///
/// Two typed fields and a button. Everything else appears only once the gateway has answered,
/// because until then there is nothing true to say about its groups or its certificate. The
/// form idiom (label above a bordered field) matches AccountFormView, so the parts you type
/// look typeable, which the settings-row style does not.
struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// The connection as edited. Committed to the store only by Done.
    @State private var profile: VPNProfile
    @State private var discoveredGroups: [ConfigAuth.TunnelGroupOption] = []
    @State private var isProbing = false
    @State private var probeError: String?
    @FocusState private var addressFocused: Bool

    private let isNew: Bool
    private let credentials: [Credential]
    private let accounts: [Account]
    private let onSave: (VPNProfile) -> Void

    init(
        profile: VPNProfile,
        isNew: Bool,
        credentials: [Credential] = [],
        accounts: [Account] = [],
        onSave: @escaping (VPNProfile) -> Void
    ) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
        self.credentials = credentials
        self.accounts = accounts
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Connection" : "Edit Connection")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 3) {
                Text("Gateway address")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    TextField("vpn.example.com:443", text: $profile.host)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .focused($addressFocused)
                        .onSubmit { detect() }

                    Button(isProbing ? "Checking..." : "Detect") { detect() }
                        .controlSize(.small)
                        .disabled(isProbing || address.isEmpty)

                    if isProbing {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            gatewayFindings

            // A connection is a gateway plus who signs in and what supplies the code. Both are
            // chosen here, and both are shown even when their lists are empty: hiding them made
            // it look as though there was nowhere to choose.
            Divider()

            picker("Sign in as", selection: $profile.credentialID) {
                Text(credentials.isEmpty ? "No credentials yet" : "Ask at sign-in")
                    .tag(UUID?.none)
                ForEach(credentials) { credential in
                    Text(credential.displayName).tag(UUID?.some(credential.id))
                }
            }

            picker("One-time code", selection: $profile.otpAccountID) {
                Text(accounts.isEmpty ? "No accounts yet" : "Type it manually")
                    .tag(UUID?.none)
                ForEach(accounts) { account in
                    Text(account.displayHeading).tag(UUID?.some(account.id))
                }
            }

            if credentials.isEmpty {
                note("Add one in the Sign-in tab to have the username and password filled in.")
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Done") {
                    onSave(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.isEmpty)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            // Nothing takes the caret. A sheet full of text fields hands the first one focus by
            // itself, which puts a selected address one keystroke away from being replaced, so
            // it is given up again once the sheet has settled.
            DispatchQueue.main.async { addressFocused = false }
        }
    }

    // MARK: - What the gateway said

    /// Nothing until the gateway has been asked, then the group it offers and the fingerprint
    /// that will be pinned. There is no honest value to show before that.
    @ViewBuilder
    private var gatewayFindings: some View {
        if let probeError {
            notice(probeError, icon: "exclamationmark.triangle.fill", tint: .orange)
        } else if profile.tunnelGroup.isEmpty && fingerprint.isEmpty {
            Text("Detect asks the gateway which tunnel groups it offers and pins the certificate "
                 + "it presents. Nothing else needs typing.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !discoveredGroups.isEmpty || !profile.tunnelGroup.isEmpty {
                    HStack(spacing: 8) {
                        Text("Group")
                            .font(.system(size: 11))
                            .frame(width: 74, alignment: .leading)

                        if discoveredGroups.count > 1 {
                            Picker("", selection: $profile.tunnelGroup) {
                                ForEach(discoveredGroups) { group in
                                    Text(group.label).tag(group.value)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                        } else {
                            Text(profile.tunnelGroup)
                                .font(.system(size: 11, weight: .medium))
                        }

                        Spacer(minLength: 0)
                    }
                }

                if !fingerprint.isEmpty {
                    HStack(spacing: 8) {
                        Text("Certificate")
                            .font(.system(size: 11))
                            .frame(width: 74, alignment: .leading)

                        Text(shortFingerprint)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .help(fingerprint)

                        Spacer(minLength: 0)

                        Button("Forget") {
                            profile.certificateSHA1 = nil
                            discoveredGroups = []
                        }
                        .controlSize(.mini)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.settingsCardFill)
            )
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func notice(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(tint)

            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func picker<Content: View>(
        _ title: String,
        selection: Binding<UUID?>,
        @ViewBuilder options: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .frame(width: 92, alignment: .leading)

            Picker("", selection: selection, content: options)
                .labelsHidden()
                .controlSize(.small)

            Spacer(minLength: 0)
        }
    }

    private func field(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }

    // MARK: - Values

    private var address: String { profile.host.trimmingCharacters(in: .whitespaces) }
    private var fingerprint: String { profile.certificateSHA1 ?? "" }

    /// First and last eight characters: enough to compare by eye, with the full value in the
    /// tooltip and selectable for a real comparison.
    private var shortFingerprint: String {
        let value = fingerprint.uppercased()
        guard value.count > 20 else { return value }
        return "\(value.prefix(8))...\(value.suffix(8))"
    }

    private var trimmed: VPNProfile {
        var result = profile
        result.host = address
        result.tunnelGroup = profile.tunnelGroup.trimmingCharacters(in: .whitespaces)
        return result
    }

    private func detect() {
        guard !address.isEmpty, !isProbing else { return }

        isProbing = true
        probeError = nil

        Task {
            var probeProfile = trimmed
            let client = GatewayClient(
                profile: probeProfile,
                // Learn the fingerprint only while there is none to check against. Once pinned,
                // a detect refuses a certificate that changed, like every other request.
                trustPolicy: probeProfile.normalizedCertificateSHA1 == nil
                    ? .learnFingerprint
                    : .pinned
            )

            do {
                let probe = try await client.probe()
                discoveredGroups = probe.groups

                if !probe.groups.contains(where: { $0.value == probeProfile.tunnelGroup }) {
                    probeProfile.tunnelGroup = probe.defaultGroup ?? ""
                }
                if probeProfile.normalizedCertificateSHA1 == nil,
                   let learned = client.observedCertificateSHA1 {
                    probeProfile.certificateSHA1 = learned
                }
                profile = probeProfile
            } catch {
                probeError = "\(error)"
            }

            isProbing = false
        }
    }
}
