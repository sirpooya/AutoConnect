import MacAuthCore
import SwiftUI

/// Adds or edits one sign-in identity: a username and where its password comes from.
///
/// The password is written to the Keychain by Done, not while typing, so a half-typed password
/// never lands there. Choosing an existing login-Keychain item stores nothing at all: the item
/// is read at connect time, which is also when macOS asks permission for it.
struct CredentialEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var credential: Credential
    @State private var password = ""
    @State private var passwordIsStored: Bool
    @State private var keychainItems: [LoginKeychain.Item] = []
    @FocusState private var usernameFocused: Bool

    private let isNew: Bool
    private let store: VPNSettingsStore
    private let idpHost: String?
    private let onSave: (Credential) -> Void

    init(
        credential: Credential,
        isNew: Bool,
        store: VPNSettingsStore,
        idpHost: String? = nil,
        onSave: @escaping (Credential) -> Void
    ) {
        _credential = State(initialValue: credential)
        _passwordIsStored = State(
            initialValue: store.hasPassword(account: credential.keychainAccount)
        )
        self.isNew = isNew
        self.store = store
        self.idpHost = idpHost
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Credential" : "Edit Credential")
                .font(.system(size: 13, weight: .semibold))

            field("Name (optional)", prompt: "Work account", text: $credential.name)

            VStack(alignment: .leading, spacing: 3) {
                Text("Username")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("you@example.com", text: $credential.username)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .focused($usernameFocused)
                    .onChange(of: credential.username) { _, _ in refreshKeychainItems() }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Password")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("", selection: $credential.passwordSource) {
                    ForEach(Credential.PasswordSource.allCases, id: \.self) { source in
                        Text(source.title).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            passwordDetail

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Done") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(credential.username.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            refreshKeychainItems()
            usernameFocused = isNew
        }
    }

    // MARK: - Password

    @ViewBuilder
    private var passwordDetail: some View {
        switch credential.passwordSource {
        case .ask:
            note("The sign-in window opens with the password blank. Nothing is stored.")

        case .stored:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SecureField(
                        passwordIsStored ? "Stored in Keychain" : "Type it once",
                        text: $password
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { commit() }

                    if passwordIsStored {
                        Button("Remove") { removeStoredPassword() }
                            .controlSize(.small)
                    }
                }

                note("Kept in this Mac's Keychain, under this credential alone.")
            }

        case .loginKeychain:
            VStack(alignment: .leading, spacing: 6) {
                if keychainItems.isEmpty {
                    note(credential.username.isEmpty
                         ? "Enter the username first, then its saved website logins appear here."
                         : "No website password saved under that username. Safari and iCloud "
                            + "Keychain entries show up here; Chrome and Firefox keep theirs in "
                            + "their own stores, which this cannot read.")
                } else {
                    Picker("", selection: $credential.passwordKeychainServer) {
                        ForEach(keychainItems) { item in
                            Text(item.server).tag(String?.some(item.server))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)

                    note("Read at connect time, so macOS asks permission once. Nothing is "
                         + "copied into this app's Keychain.")
                }
            }
        }
    }

    private func refreshKeychainItems() {
        keychainItems = LoginKeychain.rank(
            LoginKeychain.items(account: credential.username),
            preferring: idpHost
        )

        if let chosen = credential.passwordKeychainServer,
           !keychainItems.contains(where: { $0.server == chosen }) {
            credential.passwordKeychainServer = nil
        }
        if credential.passwordKeychainServer == nil {
            credential.passwordKeychainServer = keychainItems.first?.server
        }
    }

    private func removeStoredPassword() {
        try? store.deletePassword(account: credential.keychainAccount)
        passwordIsStored = false
        password = ""
    }

    private func commit() {
        var result = credential
        result.name = credential.name.trimmingCharacters(in: .whitespaces)
        result.username = credential.username.trimmingCharacters(in: .whitespaces)
        // A server is only meaningful for the source that uses one.
        if result.passwordSource != .loginKeychain { result.passwordKeychainServer = nil }

        if result.passwordSource == .stored, !password.isEmpty {
            try? store.savePassword(password, account: result.keychainAccount)
            // Drop the plaintext as soon as the Keychain has it.
            password = ""
        }

        onSave(result)
        dismiss()
    }

    // MARK: - Pieces

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
}
