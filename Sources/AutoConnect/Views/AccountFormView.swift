import AutoConnectCore
import SwiftUI

/// Add an account by hand, for a service that offers a secret rather than a QR code.
///
/// There is no edit counterpart: an existing account is read-only (see AccountDetailsView),
/// because every field here changes what code comes out.
struct AccountFormView: View {
    @EnvironmentObject private var state: AppState

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

        return hasName && !secret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Account")
                .font(.system(size: 12, weight: .semibold))

            field("Issuer", text: $issuer, prompt: "DigikalaMFA")
            field("Account", text: $label, prompt: "you@example.com")

            VStack(alignment: .leading, spacing: 3) {
                Text("Secret")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                SecureField("Base32 secret", text: $secret)
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

                Button("Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(14)
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

    private func save() {
        state.addManual(
            issuer: issuer,
            label: label,
            secret: secret,
            algorithm: algorithm,
            digits: digits,
            period: period
        )
    }
}
