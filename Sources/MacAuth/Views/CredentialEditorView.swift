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
    /// An authenticator account whose label is already an email address, used to fill the
    /// username in rather than making it be typed a second time.
    private let suggestion: Account?
    private let onSave: (Credential) -> Void

    init(
        credential: Credential,
        isNew: Bool,
        store: VPNSettingsStore,
        idpHost: String? = nil,
        suggestion: Account? = nil,
        onSave: @escaping (Credential) -> Void
    ) {
        self.suggestion = suggestion
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

                if let suggestion, credential.username == suggestion.label {
                    note("Taken from your \(suggestion.displayTitle) code. Change it if you "
                         + "sign in under a different name.")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                passwordDetail
            }

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
            // Your authenticator account is already labelled with the address you sign in
            // with, so a new credential starts from it and only the password is left to type.
            if isNew, credential.username.isEmpty, let suggestion {
                credential.username = suggestion.label
            }
            refreshKeychainItems()
            usernameFocused = isNew
        }
    }

    // MARK: - Password

    /// The Keychain is the answer nearly always, so it is the whole control rather than one
    /// choice among three. Typing nothing is the same as being asked at sign-in time, which is
    /// what the hint says instead of costing a third option nobody would pick deliberately.
    ///
    /// Reusing a website login the browser already saved is the one real alternative, and it is
    /// offered only when this Mac actually has such an item for the username.
    @ViewBuilder
    private var passwordDetail: some View {
        if credential.passwordSource == .loginKeychain, !keychainItems.isEmpty {
            HStack(spacing: 6) {
                Picker("", selection: $credential.passwordKeychainServer) {
                    ForEach(keychainItems) { item in
                        Text(item.server).tag(String?.some(item.server))
                    }
                }
                .labelsHidden()
                .controlSize(.small)

                Button("Type it instead") { credential.passwordSource = .stored }
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
                .onSubmit { commit() }

                if passwordIsStored {
                    Button("Remove") { removeStoredPassword() }
                        .controlSize(.small)
                }
            }

            if let suggestion = keychainItems.first {
                HStack(spacing: 4) {
                    note("This Mac already has a saved login for \(suggestion.server).")

                    Button("Use it") {
                        credential.passwordSource = .loginKeychain
                        credential.passwordKeychainServer = suggestion.server
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            } else {
                note("Kept in this Mac's Keychain, under this credential alone.")
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

        // The editor only ever shows two states, so anything else settles into the one the
        // fields were actually offering: a login-Keychain source with no item chosen, or an
        // "ask" carried over from an older build, is really just the Keychain field.
        if result.passwordSource == .loginKeychain, result.passwordKeychainServer == nil {
            result.passwordSource = .stored
        }
        if result.passwordSource == .ask, !password.isEmpty {
            result.passwordSource = .stored
        }
        // A server is only meaningful for the source that uses one.
        if result.passwordSource != .loginKeychain { result.passwordKeychainServer = nil }

        if result.passwordSource != .loginKeychain, !password.isEmpty {
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
