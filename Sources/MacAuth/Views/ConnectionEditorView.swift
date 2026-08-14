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
                        // Grey, like the placeholder in every other field here, so an unset
                        // username does not read as loudly as a chosen one.
                        Text("Not set").foregroundStyle(.secondary).tag("")
                        ForEach(usernameChoices, id: \.self) { choice in
                            Text(choice).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .font(.system(size: 11))
                    // Small, to stand the same height as the bordered fields above and below it.
                    // At regular size it was the tallest control in the sheet, which gave the
                    // emptiest value the strongest voice.
                    .controlSize(.small)
                    // A menu picker sizes to its widest choice and will not stretch, so the
                    // width cannot match the fields. Pin it to the same left edge instead, which
                    // is what makes the three of them read as one column.
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 8) {
                certificateHeader
                certificateDetails
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.settingsCardFill)
            )
        }
    }

    /// Who the certificate claims to be, and who vouched for it. A self-signed certificate
    /// naming the gateway is the expected case here, and saying so is the point: it is why a pin
    /// is doing the work a public CA would normally do.
    private var certificateHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            SystemCertificateIcon(size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(certificateTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(fingerprint.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let issuer = pinned?.issuer {
                    Text(issuer == pinned?.commonName
                         ? "Self-signed, so only the pin vouches for it"
                         : "Issued by \(issuer)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if !fingerprint.isEmpty {
                // Unpinning drops the only thing that proves this is the right gateway, so
                // it reads as the destructive act it is rather than a tidy-up.
                Button("Forget") {
                    profile.certificateSHA1 = nil
                    profile.certificate = nil
                    discoveredGroups = []
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.red)
            }
        }
    }

    /// The facts worth keeping, as a label column and a value column, which is the shape
    /// Keychain Access uses for the same certificate.
    ///
    /// Expiry earns its place: when the gateway renews, the pin stops matching and the failure
    /// looks like an attack unless the date said the renewal was coming. Both digests are here
    /// because SHA-1 is the one enforced today and SHA-256 is the one worth comparing by eye.
    @ViewBuilder
    private var certificateDetails: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            if !profile.tunnelGroup.isEmpty || discoveredGroups.count > 1 {
                GridRow {
                    detailLabel("Group")

                    if discoveredGroups.count > 1 {
                        Picker("", selection: $profile.tunnelGroup) {
                            ForEach(discoveredGroups) { group in
                                Text(group.label).tag(group.value)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.mini)
                        .fixedSize()
                        .gridColumnAlignment(.leading)
                    } else {
                        detailValue(profile.tunnelGroup)
                    }
                }
            }

            if fingerprint.isEmpty {
                GridRow {
                    detailLabel("Certificate")
                    detailValue("Not pinned yet")
                }
            } else {
                if let pinned {
                    if let expiry = expiryDescription {
                        GridRow {
                            detailLabel("Expires")
                            detailValue(expiry.text, tint: expiry.tint)
                        }
                    }

                    // Only when it adds something the title has not already said: a second name,
                    // or the fact that none of them is the gateway being dialled.
                    if let names = subjectNames {
                        GridRow {
                            detailLabel("Names")
                            detailValue(names.text, tint: names.tint)
                        }
                    }

                    GridRow {
                        detailLabel("SHA-256")
                        fingerprintValue(pinned.sha256)
                    }
                }

                GridRow {
                    detailLabel("SHA-1")
                    fingerprintValue(fingerprint.uppercased())
                }

                GridRow {
                    detailLabel("Pinned")
                    // A first-contact pin proves only that nothing has changed since that day,
                    // so the day is the claim, stated rather than implied.
                    detailValue(pinned.map { dayFormatted($0.pinnedAt) }
                                ?? "Before this app recorded certificate details")
                }
            }
        }
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .gridColumnAlignment(.trailing)
    }

    private func detailValue(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(tint ?? .secondary)
            .fixedSize(horizontal: false, vertical: true)
            // Claims the rest of the card. Without it the column takes only its ideal width and
            // a fingerprint wraps inside a narrow gutter with the card half empty beside it.
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridColumnAlignment(.leading)
    }

    /// Grouped in fours and wrapped rather than elided: a fingerprint you cannot select in full
    /// is a fingerprint you cannot check against Keychain Access, which is its only use.
    private func fingerprintValue(_ value: String) -> some View {
        Text(PinnedCertificate.groupedHex(value))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridColumnAlignment(.leading)
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

    /// Details only while they still describe the pinned fingerprint. A profile pinned by an
    /// older build has none, and shows its hash alone rather than a guess.
    private var pinned: PinnedCertificate? { profile.pinnedCertificate }

    private var certificateTitle: String {
        if fingerprint.isEmpty { return "No certificate pinned" }
        return pinned?.commonName ?? profile.displayName
    }

    /// The expiry line, tinted by how close it is. Inside the last month it turns amber, because
    /// that is when the renewal that will break the pin is worth expecting.
    ///
    /// The countdown is spelled out only while it means something. A ten-year certificate
    /// reading "in 3,427 days" is a number nobody converts back into a date, and it crowds out
    /// the date itself, which is the part worth remembering.
    private var expiryDescription: (text: String, tint: Color)? {
        guard let pinned, let notAfter = pinned.notAfter else { return nil }
        let day = dayFormatted(notAfter)

        switch pinned.expiry() {
        case .expired(let daysAgo):
            return ("\(day), \(daysAgo) \(plural(daysAgo)) ago. Detect again to pin the new one.", .red)
        case .soon(let daysLeft):
            return ("\(day), in \(daysLeft) \(plural(daysLeft)). The pin stops matching then.", .orange)
        case .valid(let daysLeft) where daysLeft <= 90:
            return ("\(day), in \(daysLeft) \(plural(daysLeft))", .secondary)
        case .valid, .unknown:
            return (day, .secondary)
        }
    }

    private func plural(_ days: Int) -> String { days == 1 ? "day" : "days" }

    /// The names the certificate was issued for, when that is not already obvious from the title.
    ///
    /// A certificate naming only itself needs no row. A second name is worth listing, and a
    /// certificate that names no form of this gateway is worth saying out loud: it is one reused
    /// from somewhere else, which the pin will happily accept because a pin only knows sameness.
    private var subjectNames: (text: String, tint: Color)? {
        guard let pinned else { return nil }
        let names = pinned.subjectAltNames

        if !pinned.covers(host: profile.host) {
            let listed = names.isEmpty ? (pinned.commonName ?? "nothing") : names.joined(separator: ", ")
            return ("\(listed). Not \(profile.displayName), so this certificate names another host.", .orange)
        }

        guard names.count > 1 || (names.first.map { $0 != pinned.commonName } ?? false) else {
            return nil
        }
        return (names.joined(separator: ", "), .secondary)
    }

    private func dayFormatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
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
                // Recorded even when the pin was already known, so a connection pinned by a build
                // that stored nothing but the hash gains its certificate's details on the next
                // Detect. The pin itself is untouched: this only describes it.
                if var observed = client.observedCertificate,
                   observed.sha1 == probeProfile.normalizedCertificateSHA1 {
                    // Re-detecting the same certificate must not restate when it was trusted.
                    // The date's whole worth is that it says how long nothing has changed.
                    if let existing = probeProfile.certificate, existing.sha1 == observed.sha1 {
                        observed.pinnedAt = existing.pinnedAt
                    }
                    probeProfile.certificate = observed
                }
                profile = probeProfile
            } catch {
                probeError = "\(error)"
            }

            isProbing = false
        }
    }
}
