import MacAuthCore
import SwiftUI

/// Add or edit an account by hand. In edit mode the secret field is left blank and only
/// replaces the stored secret if the user types something, so metadata can be fixed without
/// having the original secret to hand.
struct AccountFormView: View {
    enum Mode: Equatable {
        case add
        case edit(Account)

        var isEditing: Bool {
            if case .edit = self { return true }
            return false
        }
    }

    @EnvironmentObject private var state: AppState

    let mode: Mode

    @State private var issuer = ""
    @State private var label = ""
    @State private var secret = ""
    @State private var algorithm: TOTP.Algorithm = .sha1
    @State private var digits = TOTP.defaultDigits
    @State private var period = TOTP.defaultPeriod
    @State private var showAdvanced = false

    private var canSave: Bool {
        let hasName = !issuer.trimmingCharacters(in: .whitespaces).isEmpty
            || !label.trimmingCharacters(in: .whitespaces).isEmpty

        switch mode {
        case .add:
            return hasName && !secret.trimmingCharacters(in: .whitespaces).isEmpty
        case .edit:
            return hasName
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode.isEditing ? "Edit Account" : "Add Account")
                .font(.system(size: 12, weight: .semibold))

            field("Issuer", text: $issuer, prompt: "DigikalaMFA")
            field("Account", text: $label, prompt: "you@example.com")

            VStack(alignment: .leading, spacing: 3) {
                Text(mode.isEditing ? "New Secret (optional)" : "Secret")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                SecureField(
                    mode.isEditing ? "Leave blank to keep the current secret" : "Base32 secret",
                    text: $secret
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Algorithm", selection: $algorithm) {
                        ForEach(TOTP.Algorithm.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }

                    Picker("Digits", selection: $digits) {
                        Text("6").tag(6)
                        Text("7").tag(7)
                        Text("8").tag(8)
                    }

                    HStack {
                        Text("Period")
                        Spacer()
                        TextField("30", value: $period, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 54)
                        Text("sec").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .padding(.top, 6)
            } label: {
                Text("Advanced")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("Almost every service uses SHA1, 6 digits, 30 seconds. "
                 + "Only change these if the issuer told you to.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { state.route = .list }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(mode.isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(14)
        .onAppear(perform: loadExistingValues)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }

    private func loadExistingValues() {
        guard case .edit(let account) = mode else { return }
        issuer = account.issuer
        label = account.label
        algorithm = account.algorithm
        digits = account.digits
        period = account.period
        showAdvanced = account.usesNonDefaultSettings
    }

    private func save() {
        switch mode {
        case .add:
            state.addManual(
                issuer: issuer,
                label: label,
                secret: secret,
                algorithm: algorithm,
                digits: digits,
                period: period
            )

        case .edit(let existing):
            var updated = existing
            updated.issuer = issuer.trimmingCharacters(in: .whitespaces)
            updated.label = label.trimmingCharacters(in: .whitespaces)
            updated.algorithm = algorithm
            updated.digits = digits
            updated.period = max(1, period)
            state.update(updated, newSecret: secret)
        }
    }
}
