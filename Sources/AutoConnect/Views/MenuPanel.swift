import AutoConnectCore
import SwiftUI
import UniformTypeIdentifiers

/// Root of the menu bar panel. Routes between the account list, the add/edit form, and the
/// delete confirmation, all inside the same popover so no extra windows are needed.
struct MenuPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            switch state.route {
            case .list:
                AccountListView()
            case .add:
                AccountFormView()
            case .details(let account):
                AccountDetailsView(account: account)
            case .confirmDelete(let account):
                DeleteConfirmationView(account: account)
            }
        }
        .frame(width: 320)
        .overlay(alignment: .bottom) {
            if let message = state.errorMessage {
                ErrorBanner(message: message) { state.errorMessage = nil }
            }
        }
    }
}

/// Every way an account can be added, declared once so the Add menu and the empty state cannot
/// drift apart, and so the empty state's copy can never describe a path it fails to offer.
enum AddMethod: String, CaseIterable, Identifiable {
    case scanScreen
    case openImage
    case pasteLink
    case manual

    var id: String { rawValue }

    /// Full wording, for the Add menu.
    var menuTitle: String {
        switch self {
        case .scanScreen: "Scan QR Code"
        case .openImage: "Open QR Image..."
        case .pasteLink: "Paste otpauth:// Link"
        case .manual: "Enter Secret Manually..."
        }
    }

    @MainActor
    func run(_ state: AppState) {
        switch self {
        case .scanScreen: state.scanScreenRegion()
        case .openImage: state.scanImageFile()
        case .pasteLink: state.scanClipboard()
        case .manual: state.route = .add
        }
    }
}

struct AccountListView: View {
    @EnvironmentObject private var state: AppState
    /// Needed to hand the settings window the same objects the panel uses.
    @EnvironmentObject private var vpn: VPNController
    @EnvironmentObject private var notifier: VPNStatusNotifier

    /// Opens the app's own settings window. Deliberately not SwiftUI's `Settings` scene, which
    /// macOS opens by itself at launch.
    private func openSettings() {
        SettingsWindow.shared.show(state: state, vpn: vpn, notifier: notifier)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The VPN is the reason this app exists, so it sits above the codes.
            VPNSection()

            Divider()

            // No section title: the codes are self-evidently codes, and the panel is small
            // enough that a heading would cost more room than it explains.
            if state.accounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(state.accounts) { account in
                            AccountRow(account: account)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 420)
            }

            Divider()

            footer
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(AddMethod.allCases) { method in
                // Manual entry is the odd one out: it takes a form rather than reading a
                // code from somewhere, so it sits below a separator.
                if method == .manual { Divider() }
                Button(method.menuTitle) { method.run(state) }
            }
        } label: {
            Label("Add", systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add an account")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "qrcode")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No accounts yet")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Button(AddMethod.openImage.menuTitle) { AddMethod.openImage.run(state) }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            // Adding lives down here with the other actions rather than in a title bar of its
            // own, which lets the list start at the top of the panel.
            addMenu

            Spacer()

            Button("Settings") { openSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            #if DEBUG
            Button("Playground") { PlaygroundWindow.shared.show() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            #endif

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// Dropping a QR image onto the panel adds the account.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in state.addFromDroppedFile(url) }
        }
        return true
    }
}

struct DeleteConfirmationView: View {
    @EnvironmentObject private var state: AppState

    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete this account?")
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                if !account.displaySubtitle.isEmpty {
                    Text(account.displaySubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            Text("Its secret is removed from the Keychain and cannot be recovered. "
                 + "You would need to re-enrol this account.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { state.route = .list }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Delete") { state.delete(account) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(14)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))

            Text(message)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .padding(8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
