import AutoConnectCore
import SwiftUI

/// What an authenticator account is, with nothing to change.
///
/// There is deliberately no edit: the secret and its settings decide what code comes out, and a
/// wrong one produces plausible but useless codes with nothing on screen to say why. Renaming
/// the labels would be harmless, but an account is identified by what the issuer enrolled, so
/// the whole thing reads rather than edits. Changing any of it means deleting the account and
/// scanning the new QR code.
struct AccountDetailsView: View {
    @EnvironmentObject private var state: AppState

    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account Details")
                .font(.system(size: 12, weight: .semibold))

            VStack(spacing: 0) {
                row("Issuer", account.issuer.isEmpty ? "None" : account.issuer)
                SettingsDivider()
                row("Account", account.label.isEmpty ? "None" : account.label)
                SettingsDivider()
                row("Algorithm", account.algorithm.rawValue)
                SettingsDivider()
                row("Digits", "\(account.digits)")
                SettingsDivider()
                row("Period", "\(account.period)s")
                SettingsDivider()
                row("Secret", "Stored in the Keychain")
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.settingsCardFill)
            )

            Text("To change any of this, delete the account and scan its QR code again.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { state.route = .list }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11))
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
    }
}
