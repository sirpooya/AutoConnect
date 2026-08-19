import AutoConnectCore
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
    @EnvironmentObject private var notifier: VPNStatusNotifier

    private let store = VPNSettingsStore()

    /// Which tab is showing. Given at init so the panel can open the pane straight on
    /// Connections when there is nothing to connect to yet.
    @State private var tab: Tab

    init(tab: Tab = .general) {
        _tab = State(initialValue: tab)
    }

    @State private var otpAccountID: UUID?
    @State private var openconnectPath = ""
    @State private var status: String?
    @State private var launchAtLogin = false
    /// Guards the write-through: `load` assigns every field, and those assignments
    /// would otherwise each look like an edit and save the profile straight back.
    @State private var isLoaded = false

    /// The account whose details are open, and whether the manual add form is up. Both are
    /// presented as sheets over the pane and mirrored into `AppState.route`, which is what
    /// those views' own Cancel and Done buttons reset.
    @State private var detailedAccount: Account?
    @State private var isAddingAccount = false
    @State private var accountPendingDeletion: Account?


    /// Connection being edited or created, each presented as its own sheet.
    @State private var editingConnection: VPNProfile?
    @State private var newConnection: VPNProfile?
    @State private var connectionPendingDeletion: VPNProfile?

    enum Tab: Hashable {
        case general, connections, authenticator, about
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
                case .connections:
                    connectionsTab
                case .authenticator:
                    authenticatorTab
                case .about:
                    // The one tab that edits nothing, so it owns its own state and takes only
                    // the path it reports on.
                    AboutTab(openconnectPath: openconnectPath)
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
            .onChange(of: openconnectPath) { _, _ in persist() }
            .onChange(of: otpAccountID) { _, _ in persist() }
            .onDisappear { WindowActivation.release() }
    }

    private func sheets<Content: View>(_ content: Content) -> some View {
        content
            // AccountFormView ends by routing the panel back to its list. That is also the
            // signal that its sheet here is finished with.
            .onChange(of: state.route) { _, route in
                if route == .list {
                    detailedAccount = nil
                    isAddingAccount = false
                }
            }
            .sheet(item: $detailedAccount) { account in
                AccountDetailsView(account: account)
                    .frame(width: 320)
            }
            .sheet(isPresented: $isAddingAccount) {
                AccountFormView()
                    .frame(width: 320)
            }
            .sheet(item: $editingConnection) { connection in
                ConnectionEditorView(
                    profile: connection,
                    isNew: false,
                    accounts: state.accounts,
                    store: store
                ) { save(connection: $0) }
            }
            .sheet(item: $newConnection) { connection in
                ConnectionEditorView(
                    profile: connection,
                    isNew: true,
                    accounts: state.accounts,
                    store: store
                ) { save(connection: $0) }
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

    private var connectionsTab: some View {
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
                if vpn.profiles.count > 1 {
                    SettingsFootnote(
                        text: "The selected connection is the one the menu bar connects."
                    )
                }
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
        // With one connection there is nothing to choose between, so the radio reads as
        // decoration. Show it only once a second connection exists.
        let showsSelection = vpn.profiles.count > 1

        return HStack(spacing: 8) {
            // The radio is its own target, so choosing which connection the menu bar uses
            // stays separate from opening the one you clicked.
            if showsSelection {
                Button {
                    vpn.select(profileID: item.id)
                } label: {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isSelected ? "The connection the menu bar uses"
                                 : "Use this connection in the menu bar")
            }

            // Clicking the row edits it, the way a list of settings objects usually behaves.
            // Edit... stays in the menu beside Delete... so the pair is still discoverable.
            Button {
                editingConnection = item
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName)
                            .font(.system(size: 13))

                        // Who the connection signs in as. The address was tried here once and
                        // only repeated the title with a port on the end; the username is the
                        // one thing about a connection the title cannot tell you.
                        if !item.username.isEmpty {
                            Text(item.username)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
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

    private func save(connection: VPNProfile) {
        store.upsert(connection)
        vpn.reloadProfiles()

        // A first connection becomes the active one; otherwise the selection is left alone.
        if vpn.profiles.count == 1 { vpn.select(profileID: connection.id) }
        if connection.id == vpn.profile.id { vpn.profile = connection }
        load()
    }


    /// Split into one property per section. As one ViewBuilder it was both over the ten-child
    /// limit and slow enough to type-check to be worth avoiding.
    private var generalTab: some View {
        SettingsTabBody {
            reconnectSection
            notificationsSection
            startupSection
            openconnectSection

            if let status, tab == .general {
                SettingsFootnote(text: status)
            }
        }
    }

    @ViewBuilder
    private var reconnectSection: some View {
        SettingsSectionHeader(text: "Reconnect")
        SettingsCard {
            SettingsRow(title: "Reconnect automatically") {
                SettingsSwitch(isOn: $vpn.autoReconnect)
            }
        }
        SettingsFootnote(
            text: "Renews the session before expiry and restores the tunnel if it drops or "
                + "the network changes. Never connects on its own until you have connected once."
        )
    }

    /// Banners for what the tunnel did while you were looking elsewhere.
    ///
    /// One master switch, then a row per kind. The three kinds only appear once the master switch
    /// is on: with notifications off they are three controls that do nothing, and hiding them is
    /// what makes the first row read as the decision it is.
    @ViewBuilder
    private var notificationsSection: some View {
        SettingsSectionHeader(text: "Notifications")
            .padding(.top, 10)

        SettingsCard {
            SettingsRow(title: "Notify on status change") {
                SettingsSwitch(isOn: $notifier.isEnabled)
            }

            if notifier.isEnabled {
                SettingsDivider()
                SettingsRow(title: "Connected") {
                    SettingsSwitch(isOn: $notifier.notifiesOnConnect)
                }
                SettingsDivider()
                SettingsRow(title: "Disconnected") {
                    SettingsSwitch(isOn: $notifier.notifiesOnDisconnect)
                }
                SettingsDivider()
                SettingsRow(title: "Reconnecting or failed") {
                    SettingsSwitch(isOn: $notifier.notifiesOnProblem)
                }
                SettingsDivider()
                // Otherwise the only way to find out whether permission was ever granted is to
                // connect the VPN and hope.
                SettingsRow(title: "Send a test notification") {
                    Button("Send") { notifier.sendTest() }
                        .controlSize(.small)
                }
            }
        }

        if let note = notifier.authorizationNote {
            SettingsFootnote(text: note)
                .foregroundStyle(.orange)
        } else {
            SettingsFootnote(
                text: "A banner when the tunnel comes up, goes down, or gets into trouble. "
                    + "Never for the steps in between."
            )
        }
    }

    @ViewBuilder
    private var startupSection: some View {
        SettingsSectionHeader(text: "Startup")
            .padding(.top, 10)
        SettingsCard {
            SettingsRow(title: "Launch at login") {
                SettingsSwitch(isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if let message = LaunchAtLogin.set(enabled) {
                            status = message
                            // Reflect what macOS actually did, not what was asked for.
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var openconnectSection: some View {
        SettingsSectionHeader(text: "openconnect")
            .padding(.top, 10)
        SettingsCard {
            SettingsFieldRow(
                title: "Binary",
                placeholder: "/opt/homebrew/bin/openconnect",
                text: $openconnectPath,
                monospaced: true
            )

            // Only when it is missing: with a working tunnel binary there is nothing to install
            // and nothing to find, and the row would be an instruction for a problem nobody has.
            if !binaryExists {
                SettingsDivider()
                SettingsRow(title: "Install") {
                    HStack(spacing: 6) {
                        Button("Locate\u{2026}") { locateBinary() }
                        if let command = installAdvice.command {
                            SettingsCopyButton(title: "Copy Command", value: command)
                        } else if let link = installAdvice.link {
                            Button("Get Homebrew") { NSWorkspace.shared.open(link) }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }

        if !binaryExists {
            SettingsFootnote(text: installAdvice.message)
                .foregroundStyle(.orange)
        }

        SettingsSectionHeader(text: "Administrator rights")
            .padding(.top, 10)
        SettingsCard {
            SettingsRow(
                title: "Passwordless sudo rule",
                help: "Covers only the openconnect binary above and the signal that stops it."
            ) {
                SettingsCopyButton(
                    title: "Copy Command",
                    value: SetupCommands.sudoersInstallCommand(
                        user: NSUserName(),
                        binaryPath: profileBinaryPath
                    )
                )
                .controlSize(.small)
            }
        }
        SettingsFootnote(
            text: """
                openconnect needs root to create the tunnel device, so without this rule every \
                connect asks for your password. Installing it means anything running as you can \
                start the VPN. Remove it any time with: \(SetupCommands.sudoersRemoveCommand)
                """
        )
    }

    /// Lets someone point the app at an openconnect Homebrew did not put where this app looks,
    /// which is every Intel Mac, MacPorts, and any custom prefix.
    private func locateBinary() {
        let panel = NSOpenPanel()
        panel.title = "Choose the openconnect binary"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // /usr/local and /opt are hidden in the standard sidebar, and the binary lives in one of
        // them on most machines, so both the flag and a sensible starting directory are needed.
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(
            fileURLWithPath: (openconnectPath as NSString).deletingLastPathComponent
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openconnectPath = url.path
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
            // Clicking the row opens the details sheet, matching the connection rows.
            //
            // No live code, no countdown and no Copy Code: this tab is where accounts are added
            // and deleted, and the menu bar panel is where a code is there to be taken. A second
            // place to read one meant two tickers for the same secret and a row that changed
            // under the cursor while you were aiming at Delete.
            Button {
                showDetails(account)
            } label: {
                HStack(spacing: 6) {
                    // The account name alone. The issuer is in the details sheet, and with two
                    // accounts from the same issuer it is the name that tells them apart.
                    Text(account.displaySubtitle.isEmpty
                         ? account.displayTitle
                         : account.displaySubtitle)
                        .font(.system(size: 13))

                    Spacer(minLength: 10)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Details...") { showDetails(account) }
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

    private func showDetails(_ account: Account) {
        state.route = .details(account)
        detailedAccount = account
    }

    // MARK: - State

    private var binaryExists: Bool {
        FileManager.default.isExecutableFile(atPath: openconnectPath)
    }

    /// Which advice is true on this machine: openconnect comes from Homebrew, and telling someone
    /// without Homebrew to run `brew install` sends them to "command not found".
    private var installAdvice: SetupCommands.InstallAdvice {
        SetupCommands.openconnectInstall(homebrewInstalled: SetupCommands.homebrewPath() != nil)
    }

    /// The path the sudo rule has to name, which is the one the runner will launch. The field is
    /// the live value, and falling back to the placeholder keeps the command valid while it is
    /// empty rather than offering a rule with a hole in it.
    private var profileBinaryPath: String {
        let typed = openconnectPath.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? VPNProfile.empty.openconnectPath : typed
    }

    private func accountLabel(_ account: Account) -> String {
        account.displaySubtitle.isEmpty
            ? account.displayTitle
            : "\(account.displayTitle): \(account.displaySubtitle)"
    }

    private func load() {
        let profile = vpn.profile
        openconnectPath = profile.openconnectPath
        otpAccountID = profile.otpAccountID
        launchAtLogin = LaunchAtLogin.isEnabled
        // Permission may have been granted in System Settings since the app launched, and this
        // pane is where the warning about it is shown.
        notifier.refreshAuthorization()
        isLoaded = true
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
        profile.openconnectPath = openconnectPath.trimmingCharacters(in: .whitespaces)
        profile.otpAccountID = otpAccountID

        store.upsert(profile)
        vpn.profile = profile
        vpn.reloadProfiles()
    }

    private func flash(_ message: String) {
        status = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if status == message { status = nil }
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
            TabButton(title: "Connections", systemImage: "network",
                      isSelected: selection == .connections) { selection = .connections }
            TabButton(title: "Authenticator", systemImage: "qrcode",
                      isSelected: selection == .authenticator) { selection = .authenticator }
            TabButton(title: "About", systemImage: "info.circle",
                      isSelected: selection == .about) { selection = .about }
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
