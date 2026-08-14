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

    @State private var password = ""
    @State private var passwordIsStored: Bool
    @State private var keychainItems: [LoginKeychain.Item] = []

    private let isNew: Bool
    private let accounts: [Account]
    private let store: VPNSettingsStore
    private let onSave: (VPNProfile) -> Void

    init(
        profile: VPNProfile,
        isNew: Bool,
        accounts: [Account] = [],
        store: VPNSettingsStore = VPNSettingsStore(),
        onSave: @escaping (VPNProfile) -> Void
    ) {
        _profile = State(initialValue: profile)
        _passwordIsStored = State(
            initialValue: store.hasPassword(account: profile.credentialAccount)
        )
        self.isNew = isNew
        self.accounts = accounts
        self.store = store
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

                    // Regular size, not small: a small button is shorter than the rounded-border
                    // field beside it and the pair reads as misaligned.
                    Button(isProbing ? "Checking..." : "Detect") { detect() }
                        .font(.system(size: 11))
                        .disabled(isProbing || address.isEmpty)

                    if isProbing {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            gatewayFindings

            // A connection is a gateway plus who signs in and what supplies the code, so all
            // three live in this one sheet. They were briefly a separate credentials list,
            // which for one person with one gateway was an entity to keep straight rather than
            // a saving.
            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("Username")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                // Your authenticator accounts are already labelled with the address you sign in
                // with, so this picks from them rather than asking for it to be typed again.
                // A gateway with no such account to draw on still gets a field.
                if usernameChoices.isEmpty {
                    TextField("you@example.com", text: $profile.username)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onChange(of: profile.username) { _, _ in
                            refreshKeychainItems()
                            syncOTPAccount()
                        }
                } else {
                    Picker("", selection: $profile.username) {
                        Text("Not set").tag("")
                        ForEach(usernameChoices, id: \.self) { choice in
                            Text(choice).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .font(.system(size: 11))
                    .onChange(of: profile.username) { _, _ in
                            refreshKeychainItems()
                            syncOTPAccount()
                        }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                passwordDetail
            }

            if let matched = accountMatchingUsername {
                note("Its one-time code comes from your \(matched.displayTitle) account.")
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Done") {
                    commit()
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
            // Your authenticator account is already labelled with the address you sign in
            // with, so a new connection starts from it and only the password is left to type.
            if isNew, profile.username.isEmpty,
               let suggestion = accounts.first(where: { $0.label.contains("@") }) {
                profile.username = suggestion.label
            }
            refreshKeychainItems()
            syncOTPAccount()
            // Nothing takes the caret. A sheet full of text fields hands the first one focus by
            // itself, which puts a selected address one keystroke away from being replaced, so
            // it is given up again once the sheet has settled.
            DispatchQueue.main.async { addressFocused = false }
        }
    }

    // MARK: - Password

    /// The Keychain is the answer nearly always, so it is the whole control. Typing nothing is
    /// the same as being asked at sign-in time, which the placeholder says rather than costing
    /// an option nobody would pick deliberately. Reusing a website login the browser already
    /// saved is offered only when this Mac actually has one for the username.
    @ViewBuilder
    private var passwordDetail: some View {
        if profile.passwordSource == .loginKeychain, !keychainItems.isEmpty {
            HStack(spacing: 6) {
                Picker("", selection: $profile.passwordKeychainServer) {
                    ForEach(keychainItems) { item in
                        Text(item.server).tag(String?.some(item.server))
                    }
                }
                .labelsHidden()
                .controlSize(.small)

                Button("Type it instead") { profile.passwordSource = .stored }
                    .controlSize(.small)
            }

            note("Read from the login Keychain at connect time, so macOS asks permission once. "
                 + "Nothing is copied into this app's Keychain.")
        } else {
            HStack(spacing: 6) {
                SecureField(
                    passwordIsStored ? "Stored in Keychain" : "Leave blank to be asked",
                    text: $password
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

                if passwordIsStored {
                    Button("Remove") { removeStoredPassword() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }

            if let match = keychainItems.first {
                HStack(spacing: 4) {
                    note("This Mac already has a saved login for \(match.server).")

                    Button("Use it") {
                        profile.passwordSource = .loginKeychain
                        profile.passwordKeychainServer = match.server
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            }
        }
    }

    /// The code comes from the account the username belongs to. Choosing the username is
    /// therefore the whole choice, which is why there is no second picker for it.
    private func syncOTPAccount() {
        if let matched = accountMatchingUsername {
            profile.otpAccountID = matched.id
        } else if profile.otpAccountID != nil,
                  !accounts.contains(where: { $0.id == profile.otpAccountID }) {
            profile.otpAccountID = nil
        }
    }

    private func refreshKeychainItems() {
        keychainItems = LoginKeychain.rank(
            LoginKeychain.items(account: profile.username),
            preferring: profile.idpHost
        )

        if let chosen = profile.passwordKeychainServer,
           !keychainItems.contains(where: { $0.server == chosen }) {
            profile.passwordKeychainServer = nil
        }
        if profile.passwordKeychainServer == nil {
            profile.passwordKeychainServer = keychainItems.first?.server
        }
    }

    private func removeStoredPassword() {
        try? store.deletePassword(account: profile.credentialAccount)
        passwordIsStored = false
        password = ""
    }

    // MARK: - What the gateway said

    /// Nothing until the gateway has been asked, then what it answered: the group it offers and
    /// the certificate that will be pinned. There is no honest value to show before that.
    ///
    /// The certificate is drawn the way Keychain Access draws one, with the system's own
    /// artwork, so a fingerprint compared against Keychain Access is compared against something
    /// that looks like the same object.
    @ViewBuilder
    private var gatewayFindings: some View {
        if let probeError {
            notice(probeError, icon: "exclamationmark.triangle.fill", tint: .orange)
        } else if profile.tunnelGroup.isEmpty && fingerprint.isEmpty {
            note("Detect asks the gateway which tunnel groups it offers and pins the certificate "
                 + "it presents. Nothing else needs typing.")
        } else {
            HStack(alignment: .top, spacing: 10) {
                SystemCertificateIcon(size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    if !profile.tunnelGroup.isEmpty || discoveredGroups.count > 1 {
                        HStack(spacing: 6) {
                            Text("Group")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            if discoveredGroups.count > 1 {
                                Picker("", selection: $profile.tunnelGroup) {
                                    ForEach(discoveredGroups) { group in
                                        Text(group.label).tag(group.value)
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.mini)
                                .fixedSize()
                            } else {
                                Text(profile.tunnelGroup)
                                    .font(.system(size: 11))
                            }
                        }
                    }

                    if fingerprint.isEmpty {
                        Text("No certificate pinned")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(shortFingerprint)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .help(fingerprint)

                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.green)

                            Text("Pinned. The gateway must present this certificate.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)

                if !fingerprint.isEmpty {
                    // Unpinning drops the only thing that proves this is the right gateway, so
                    // it reads as the destructive act it is rather than a tidy-up.
                    Button("Forget") {
                        profile.certificateSHA1 = nil
                        discoveredGroups = []
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
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

    // MARK: - Values

    /// Addresses from the authenticator accounts, plus whatever the connection already had, so
    /// a username typed by an older build is never silently dropped.
    private var usernameChoices: [String] {
        var choices = accounts.map(\.label).filter { $0.contains("@") }
        let current = profile.username.trimmingCharacters(in: .whitespaces)
        if !current.isEmpty, !choices.contains(current) { choices.append(current) }

        return choices.reduce(into: [String]()) { unique, choice in
            if !unique.contains(choice) { unique.append(choice) }
        }
    }

    /// The authenticator account this username belongs to, which is therefore the one whose
    /// code fills the OTP field.
    private var accountMatchingUsername: Account? {
        accounts.first { $0.label == profile.username }
    }

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
        result.username = profile.username.trimmingCharacters(in: .whitespaces)
        return result
    }

    /// Writes the password, then hands the connection back. The password waits for Done rather
    /// than being written as it is typed: each write is a Keychain round trip, and a half-typed
    /// password is not worth one.
    private func commit() {
        var result = trimmed

        // A login-Keychain source with no item chosen is really just the Keychain field, which
        // is what the sheet was showing.
        if result.passwordSource == .loginKeychain, result.passwordKeychainServer == nil {
            result.passwordSource = .stored
        }
        if result.passwordSource != .loginKeychain {
            result.passwordKeychainServer = nil
            if !password.isEmpty {
                try? store.savePassword(password, account: result.credentialAccount)
                password = ""
            }
        }

        onSave(result)
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
