import MacAuthCore
import SwiftUI

/// Adds or edits one connection: a name, a gateway address, and whatever the gateway itself
/// tells us about its tunnel groups and certificate.
///
/// Only the address is typed. Detect asks the gateway which groups it offers and records its
/// certificate fingerprint, so nothing about a particular company is typed twice or compiled in.
struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// The connection as edited. Committed to the store only by Done.
    @State private var profile: VPNProfile
    @State private var discoveredGroups: [ConfigAuth.TunnelGroupOption] = []
    @State private var isProbing = false
    @State private var probeStatus: String?

    private let isNew: Bool
    private let onSave: (VPNProfile) -> Void

    init(profile: VPNProfile, isNew: Bool, onSave: @escaping (VPNProfile) -> Void) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isNew ? "New Connection" : "Edit Connection")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, SettingsMetrics.rowHPadding)

            SettingsCard {
                SettingsFieldRow(
                    title: "Name",
                    placeholder: "Work",
                    text: $profile.name
                )
                SettingsDivider()
                SettingsFieldRow(
                    title: "Address",
                    placeholder: "vpn.example.com:443",
                    text: $profile.host
                )
                SettingsDivider()
                SettingsRow(title: "Group") {
                    if discoveredGroups.isEmpty {
                        Text(profile.tunnelGroup.isEmpty ? "Detect to fill" : profile.tunnelGroup)
                            .font(.system(size: 13))
                            .foregroundStyle(profile.tunnelGroup.isEmpty ? .tertiary : .secondary)
                    } else {
                        Picker("", selection: $profile.tunnelGroup) {
                            ForEach(discoveredGroups) { group in
                                Text(group.label).tag(group.value)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: SettingsMetrics.fieldWidth)
                    }
                }
                SettingsDivider()
                SettingsRow(title: "Certificate") {
                    HStack(spacing: 8) {
                        Text(fingerprint.isEmpty ? "Not pinned yet" : shortFingerprint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(fingerprint.isEmpty ? .tertiary : .secondary)
                            .help(fingerprint)

                        if !fingerprint.isEmpty {
                            Button("Forget") {
                                profile.certificateSHA1 = nil
                                discoveredGroups = []
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button(isProbing ? "Checking..." : "Detect") { detect() }
                    .controlSize(.small)
                    .disabled(isProbing || profile.host.trimmingCharacters(in: .whitespaces).isEmpty)

                if isProbing { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.horizontal, SettingsMetrics.rowHPadding)

            SettingsFootnote(
                text: probeStatus ?? "Detect asks the gateway which tunnel groups it offers and "
                    + "pins the certificate it presents. The first check has to trust whatever "
                    + "answers, so compare the fingerprint if you have it from elsewhere."
            )

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Done") {
                    onSave(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, SettingsMetrics.rowHPadding)
            .padding(.top, 4)
        }
        .padding(.vertical, 16)
        .frame(width: 420)
    }

    private var fingerprint: String { profile.certificateSHA1 ?? "" }

    /// First and last eight characters: enough to compare by eye, and the full value is in the
    /// tooltip. Forty monospaced characters plus a button does not fit the row.
    private var shortFingerprint: String {
        let value = fingerprint.uppercased()
        guard value.count > 20 else { return value }
        return "\(value.prefix(8))...\(value.suffix(8))"
    }

    private var trimmed: VPNProfile {
        var result = profile
        result.name = profile.name.trimmingCharacters(in: .whitespaces)
        result.host = profile.host.trimmingCharacters(in: .whitespaces)
        result.tunnelGroup = profile.tunnelGroup.trimmingCharacters(in: .whitespaces)
        return result
    }

    private func detect() {
        isProbing = true
        probeStatus = nil

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

                let names = probe.groups.map(\.label).joined(separator: ", ")
                probeStatus = probe.groups.count == 1
                    ? "Found one group: \(names)."
                    : "Found \(probe.groups.count) groups: \(names)."
            } catch {
                probeStatus = "\(error)"
            }

            isProbing = false
        }
    }
}
