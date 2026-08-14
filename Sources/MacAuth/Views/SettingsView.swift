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

    @State private var tab: Tab = .general

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

    /// The account being edited, and whether the manual add form is up. Both are
    /// presented as sheets over the pane and mirrored into `AppState.route`, which
    /// is what AccountFormView's own Cancel and Save buttons reset.
    @State private var editingAccount: Account?
    @State private var isAddingAccount = false
    @State private var accountPendingDeletion: Account?

    @State private var passwordSource: VPNProfile.PasswordSource = .stored
    @State private var passwordKeychainServer: String?
    /// Login-Keychain items matching the username. Metadata only, so listing them prompts for
    /// nothing; the password itself is read at connect time.
    @State private var keychainItems: [LoginKeychain.Item] = []

    /// Connection being edited or created, each presented as its own sheet.
    @State private var editingConnection: VPNProfile?
    @State private var newConnection: VPNProfile?
    @State private var connectionPendingDeletion: VPNProfile?

    enum Tab: Hashable {
        case general, gateway, signIn, authenticator
    }

    var body: some View {
        // Split into three pieces on purpose. As one chain, the modifier stack got long enough
        // that the type checker gave up on it ("unable to type-check this expression in
        // reasonable time"), and the fix is fewer modifiers per expression, not simpler UI.
        sheets(writeThrough(shell))
    }

    private var shell: some View {
        VStack(spacing: 0) {
            TabBar(selection: $tab)
            Divider().overlay(Color.primary.opacity(0.03))

            Group {
                switch tab {
                case .general:
                    generalTab
                case .gateway:
                    gatewayTab
                case .signIn:
                    signInTab
                case .authenticator:
                    authenticatorTab
                }
            }
            .frame(minHeight: SettingsMetrics.bodyHeight, maxHeight: .infinity, alignment: .top)
        }
        // The window owns the size (see SettingsWindow); the content just fills it.
        .frame(
            minWidth: SettingsMetrics.windowWidth,
            minHeight: SettingsMetrics.windowHeight
        )
    }

    /// Every field writes through as it is edited; the password waits for blur or Return.
    private func writeThrough<Content: View>(_ content: Content) -> some View {
        content
            .onAppear(perform: load)
            .onChange(of: username) { _, _ in
                persist()
                refreshKeychainItems()
            }
            .onChange(of: passwordSource) { _, _ in persist() }
            .onChange(of: passwordKeychainServer) { _, _ in persist() }
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

    private func sheets<Content: View>(_ content: Content) -> some View {
        content
            // AccountFormView ends by routing the panel back to its list. That is also the
            // signal that its sheet here is finished with.
            .onChange(of: state.route) { _, route in
                if route == .list {
                    editingAccount = nil
                    isAddingAccount = false
                }
            }
            .sheet(item: $editingAccount) { account in
                AccountFormView(mode: .edit(account))
                    .frame(width: 320)
            }
            .sheet(isPresented: $isAddingAccount) {
                AccountFormView(mode: .add)
                    .frame(width: 320)
            }
            .sheet(item: $editingConnection) { connection in
                ConnectionEditorView(profile: connection, isNew: false) { save(connection: $0) }
            }
            .sheet(item: $newConnection) { connection in
                ConnectionEditorView(profile: connection, isNew: true) { save(connection: $0) }
            }
            .confirmationDialog(
                "Delete this connection?",
                isPresented: presenting($connectionPendingDeletion),
                presenting: connectionPendingDeletion
            ) { connection in
                Button("Delete", role: .destructive) { delete(connection: connection) }
                Button("Cancel", role: .cancel) {}
            } message: { connection in
                Text("\(connection.displayName)\n\nIts saved password is removed from the "
                     + "Keychain too. Authenticator accounts are not touched.")
            }
            .confirmationDialog(
                "Delete this account?",
                isPresented: presenting($accountPendingDeletion),
                presenting: accountPendingDeletion
            ) { account in
                Button("Delete", role: .destructive) { state.delete(account) }
                Button("Cancel", role: .cancel) {}
            } message: { account in
                Text("\(accountLabel(account))\n\nIts secret is removed from the Keychain and "
                     + "cannot be recovered. You would need to re-enrol this account.")
            }
    }

    /// Turns "is something pending?" into the Bool binding confirmationDialog wants.
    private func presenting<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    private func delete(connection: VPNProfile) {
        store.delete(profileID: connection.id)
        vpn.reloadProfiles()
        load()
    }

    // MARK: - Tabs

    private var gatewayTab: some View {
        SettingsTabBody {
            SettingsSectionHeader(text: "Connections")

            if vpn.profiles.isEmpty {
                SettingsCard {
                    SettingsRow(title: "No connections yet") { EmptyView() }
                }
                SettingsFootnote(
                    text: "Add one with the gateway address your company gave you. Everything "
                        + "else about it is read from the gateway."
                )
            } else {
                SettingsCard {
                    ForEach(Array(vpn.profiles.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { SettingsDivider() }
                        connectionRow(item)
                    }
                }
                SettingsFootnote(
                    text: "The selected connection is the one the menu bar connects, and the one "
                        + "the Sign-in tab sets credentials for."
                )
            }

            HStack {
                Button("Add Connection...") { addConnection() }
                    .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, SettingsMetrics.rowHPadding)
            .padding(.top, 2)
        }
    }

    private func connectionRow(_ item: VPNProfile) -> some View {
        let isSelected = item.id == vpn.profile.id

        return HStack(spacing: 8) {
            // The whole left side selects, so switching connection is one click on the row
            // rather than a hunt for a radio button.
            Button {
                vpn.select(profileID: item.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName)
                            .font(.system(size: 13))
                        Text(item.host.isEmpty ? "No address" : item.host)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 10)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !item.isComplete {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Not ready to connect: run Detect to fill in the group and certificate.")
            }

            Menu {
                Button("Edit...") { editingConnection = item }
                Button("Duplicate") { duplicate(item) }
                Divider()
                Button("Delete...", role: .destructive) { connectionPendingDeletion = item }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, SettingsMetrics.rowHPadding)
        .frame(minHeight: 42)
    }

    private func addConnection() {
        newConnection = .newConnection()
    }

    private func duplicate(_ item: VPNProfile) {
        var copy = item
        // A copy is a different connection: new identity, and its own Keychain item rather than
        // a second name for the original's password.
        copy.id = UUID()
        copy.name = "\(item.displayName) copy"
        copy.credentialAccount = "vpn-password-\(copy.id.uuidString)"
        store.upsert(copy)
        vpn.reloadProfiles()
    }

    private func save(connection: VPNProfile) {
        store.upsert(connection)
        vpn.reloadProfiles()

        // A first connection becomes the active one; otherwise the selection is left alone.
        if vpn.profiles.count == 1 { vpn.select(profileID: connection.id) }
        if connection.id == vpn.profile.id { vpn.profile = connection }
        load()
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
                SettingsRow(title: "Password from") {
                    Picker("", selection: $passwordSource) {
                        ForEach(VPNProfile.PasswordSource.allCases, id: \.self) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: SettingsMetrics.fieldWidth)
                }

                switch passwordSource {
                case .stored:
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

                case .loginKeychain:
                    SettingsDivider()
                    SettingsRow(title: "Keychain item") {
                        if keychainItems.isEmpty {
                            Text(username.isEmpty ? "Enter a username first" : "No match")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                        } else {
                            Picker("", selection: $passwordKeychainServer) {
                                ForEach(keychainItems) { item in
                                    Text(item.server).tag(String?.some(item.server))
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(maxWidth: SettingsMetrics.fieldWidth)
                        }
                    }

                case .ask:
                    EmptyView()
                }
            }

            if passwordSource == .loginKeychain {
                SettingsFootnote(text: keychainItems.isEmpty
                    ? "Looks for a website password saved under this username. Safari and iCloud "
                        + "Keychain entries are visible here; Chrome and Firefox keep theirs in "
                        + "their own stores, which this cannot read."
                    : "Read at connect time, so macOS asks permission once. Nothing is copied "
                        + "into this app's Keychain.")
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

    private var generalTab: some View {
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

            if let status, tab == .general {
                SettingsFootnote(text: status)
            }
        }
    }

    // MARK: - Authenticator

    private var authenticatorTab: some View {
        SettingsTabBody {
            SettingsSectionHeader(text: "Accounts")

            if state.accounts.isEmpty {
                SettingsCard {
                    SettingsRow(title: "No accounts yet") {
                        EmptyView()
                    }
                }
            } else {
                SettingsCard {
                    ForEach(Array(state.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { SettingsDivider() }
                        accountRow(account)
                    }
                }
            }

            HStack {
                Menu("Add Account") {
                    ForEach(AddMethod.allCases) { method in
                        // Manual entry is the odd one out: it takes a form rather than
                        // reading a code from somewhere, so it sits below a separator.
                        if method == .manual { Divider() }
                        Button(method.menuTitle) { add(method) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, SettingsMetrics.rowHPadding)
            .padding(.top, 2)

            SettingsFootnote(
                text: "Codes are generated on this Mac from secrets in its Keychain. "
                    + "Deleting an account removes its secret for good."
            )
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 6) {
            // Account first, issuer beneath it. One line of "Issuer: account" fits the cramped
            // menu panel, but here there is room to put the name you actually scan for on top.
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displaySubtitle.isEmpty
                     ? account.displayTitle
                     : account.displaySubtitle)
                    .font(.system(size: 13))

                if !account.displaySubtitle.isEmpty {
                    Text(account.displayTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 10)

            Text(state.formattedCode(for: account))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Text("\(state.secondsRemaining(for: account))s")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                // A fixed width so the row does not twitch as the count drops from two
                // digits to one.
                .frame(width: 22, alignment: .trailing)

            Menu {
                Button("Copy Code") { state.copy(account) }
                Button("Edit...") { edit(account) }
                Divider()
                Button("Delete...", role: .destructive) {
                    accountPendingDeletion = account
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, SettingsMetrics.rowHPadding)
        .frame(minHeight: 42)
    }

    private func add(_ method: AddMethod) {
        if method == .manual {
            state.route = .add
            isAddingAccount = true
        } else {
            // The scanners run against the screen, a file, or the clipboard and add
            // the account themselves. Nothing to present here.
            method.run(state)
        }
    }

    private func edit(_ account: Account) {
        state.route = .edit(account)
        editingAccount = account
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
        username = profile.username
        openconnectPath = profile.openconnectPath
        otpAccountID = profile.otpAccountID
        passwordIsStored = store.hasPassword(account: profile.credentialAccount)
        passwordSource = profile.passwordSource
        passwordKeychainServer = profile.passwordKeychainServer
        launchAtLogin = LaunchAtLogin.isEnabled
        isLoaded = true
        refreshKeychainItems()
    }

    /// Re-runs the login-Keychain lookup for the current username. Metadata only: no prompt.
    private func refreshKeychainItems() {
        keychainItems = LoginKeychain.rank(
            LoginKeychain.items(account: username),
            preferring: vpn.profile.idpHost
        )

        // Keep a chosen item only while it still exists; otherwise take the best match, so the
        // picker never shows a server this Mac no longer has a password for.
        if let chosen = passwordKeychainServer,
           !keychainItems.contains(where: { $0.server == chosen }) {
            passwordKeychainServer = nil
        }
        if passwordKeychainServer == nil {
            passwordKeychainServer = keychainItems.first?.server
        }
    }

    /// Writes the edited fields through to the profile. Called on every edit, so it
    /// stays cheap: UserDefaults and an in-memory profile, no Keychain work.
    private func persist() {
        guard isLoaded else { return }

        // Only the fields these tabs own. The gateway, group and pin belong to the connection
        // editor, and reading them from `vpn.profile` here is what keeps an edit made there
        // from being written back over.
        var profile = vpn.profile
        // Trim only on the way out. Trimming the bound state instead would stop the
        // field accepting a space you are about to type over.
        profile.username = username.trimmingCharacters(in: .whitespaces)
        profile.openconnectPath = openconnectPath.trimmingCharacters(in: .whitespaces)
        profile.otpAccountID = otpAccountID
        profile.passwordSource = passwordSource
        profile.passwordKeychainServer = passwordSource == .loginKeychain
            ? passwordKeychainServer
            : nil

        store.upsert(profile)
        vpn.profile = profile
        vpn.reloadProfiles()
    }

    /// The password commits on blur or Return rather than on every keystroke: each
    /// write is a Keychain round trip, and a half-typed password is not worth one.
    private func savePassword() {
        guard !password.isEmpty else { return }

        do {
            try store.savePassword(password, account: vpn.profile.credentialAccount)
            // Drop the plaintext as soon as the Keychain has it.
            password = ""
            passwordIsStored = true
            flash("Password saved to the Keychain")
        } catch {
            status = "Could not save the password: \(error)"
        }
    }

    private func flash(_ message: String) {
        status = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if status == message { status = nil }
        }
    }

    private func removePassword() {
        do {
            try store.deletePassword(account: vpn.profile.credentialAccount)
            passwordIsStored = false
            flash("Password removed")
        } catch {
            status = "Could not remove the password: \(error)"
        }
    }
}

// MARK: - Top tab bar

private struct TabBar: View {
    @Binding var selection: SettingsView.Tab

    var body: some View {
        HStack(spacing: 4) {
            TabButton(title: "General", systemImage: "gearshape.fill",
                      isSelected: selection == .general) { selection = .general }
            TabButton(title: "Gateway", systemImage: "network",
                      isSelected: selection == .gateway) { selection = .gateway }
            TabButton(title: "Authenticator", systemImage: "qrcode",
                      isSelected: selection == .authenticator) { selection = .authenticator }
            TabButton(title: "Sign-in", systemImage: "person.badge.key.fill",
                      isSelected: selection == .signIn) { selection = .signIn }
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
                // Wide enough for "Authenticator" without wrapping, and four of these
                // still fit the window width.
                .frame(width: 96)
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
