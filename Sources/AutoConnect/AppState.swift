import AppKit
import Combine
import Foundation
import AutoConnectCore

/// Which screen the menu bar panel is showing.
enum PanelRoute: Equatable {
    case list
    case details(Account)
    case confirmDelete(Account)
}

@MainActor
final class AppState: ObservableObject {

    @Published private(set) var accounts: [Account] = []
    @Published var route: PanelRoute = .list
    @Published private(set) var now: Date = Date()

    /// Set briefly after a copy so the row can confirm it.
    @Published private(set) var copiedAccountID: UUID?
    @Published var errorMessage: String?

    private let store: AccountStoring
    private var ticker: AnyCancellable?
    private var copyResetTask: Task<Void, Never>?

    /// Generated codes, keyed by account, valid for one time step. Keeps the Keychain read
    /// down to once per period per account instead of once per second, and means a decoded
    /// secret is only ever held for the moment a code is computed.
    private var codeCache: [UUID: (counter: UInt64, code: String)] = [:]

    init(store: AccountStoring = KeychainStore()) {
        self.store = store
        reload()

        ticker = Timer.publish(every: 1, tolerance: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.now = date
            }
    }

    // MARK: - Reading

    func reload() {
        do {
            accounts = try store.loadAccounts()
        } catch {
            errorMessage = describe(error)
        }
    }

    /// The code currently valid for an account, formatted for display.
    func code(for account: Account) -> String {
        let counter = TOTP.counter(at: now, period: account.period)

        if let cached = codeCache[account.id], cached.counter == counter {
            return cached.code
        }

        do {
            let secret = try store.secret(for: account.id)
            let code = TOTP.generate(
                secret: secret,
                counter: counter,
                algorithm: account.algorithm,
                digits: account.digits
            )
            codeCache[account.id] = (counter, code)
            return code
        } catch {
            // A missing secret should be visible, not silently rendered as a plausible code.
            return String(repeating: "-", count: account.digits)
        }
    }

    /// Groups a code into halves so it is easier to read and to type: "948825" to "948 825".
    func formattedCode(for account: Account) -> String {
        let code = code(for: account)
        guard code.count >= 6, !code.contains("-") else { return code }

        let midpoint = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[code.startIndex..<midpoint]) \(code[midpoint...])"
    }

    func secondsRemaining(for account: Account) -> Int {
        Int(ceil(TOTP.secondsRemaining(at: now, period: account.period)))
    }

    func remainingFraction(for account: Account) -> Double {
        TOTP.remainingFraction(at: now, period: account.period)
    }

    // MARK: - Clipboard

    func copy(_ account: Account) {
        let code = code(for: account)
        guard !code.contains("-") else {
            errorMessage = "That account's secret is missing from the Keychain."
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        // Declared concealed, the way a password manager declares a password. Clipboard managers
        // that honour the convention leave it out of their history, which matters more here than
        // it looks: the code is good for thirty seconds, and a history entry outlives it by
        // however long the history is kept.
        NSPasteboard.general.setString("", forType: .init("org.nspasteboard.ConcealedType"))

        copiedAccountID = account.id
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.copiedAccountID = nil
        }
    }

    // MARK: - Writing

    /// Stores everything one scan produced. A Google Authenticator export is many accounts at
    /// once, so this takes a list: an entry that fails to store is reported, but the ones
    /// already written stay written rather than being rolled back out of the Keychain.
    func add(_ result: QRScanner.ScanResult) {
        var failure: String?

        for entry in result.entries {
            do {
                try store.add(entry.account, secret: entry.secret)
            } catch {
                failure = describe(error)
                break
            }
        }

        reload()
        route = .list
        // The note is only the export's own caveats, so a real failure outranks it.
        errorMessage = failure ?? result.note
    }

    func delete(_ account: Account) {
        do {
            try store.delete(id: account.id)
            codeCache[account.id] = nil
            reload()
            route = .list
        } catch {
            errorMessage = describe(error)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        var reordered = accounts
        reordered.move(fromOffsets: source, toOffset: destination)

        do {
            try store.reorder(reordered)
            reload()
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Scanning

    func scanScreenRegion() {
        performScan { try QRScanner.scanScreenRegion() }
    }

    func scanImageFile() {
        performScan { try QRScanner.scanImageFile() }
    }

    func scanClipboard() {
        performScan { try QRScanner.parseClipboard() }
    }

    func addFromDroppedFile(_ url: URL) {
        performScan { try QRScanner.parse(imageAt: url) }
    }

    /// Opens the camera scanner. The odd one out: the other paths block until they have an
    /// answer, while a camera runs until it sees something, so the pin is taken here and given
    /// back when the window is done rather than around a single call.
    func scanCamera() {
        PanelPin.acquire()

        CameraScanWindow.shared.show { [weak self] result in
            PanelPin.release()
            guard let self else { return }

            switch result {
            case .success(let scan):
                self.add(scan)
            case .failure(QRScanner.ScanError.cancelled):
                // Closing the window is not an error worth reporting.
                break
            case .failure(let error):
                self.errorMessage = self.describe(error)
            }
        }
    }

    private func performScan(_ scan: () throws -> QRScanner.ScanResult) {
        do {
            // Pinned because the picker and the capture overlay would otherwise dismiss the
            // panel, hiding the account the scan just added.
            add(try PanelPin.pinned(scan))
        } catch QRScanner.ScanError.cancelled {
            // Backing out of a scan is not an error worth reporting.
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Helpers

    private func describe(_ error: Error) -> String {
        if let scanError = error as? QRScanner.ScanError {
            return scanError.errorDescription ?? "\(scanError)"
        }
        if let parseError = error as? OTPAuthURI.ParseError {
            return parseError.description
        }
        if let base32Error = error as? Base32.DecodeError {
            return base32Error.description
        }
        if let storeError = error as? KeychainStore.StoreError {
            return storeError.description
        }
        return error.localizedDescription
    }
}
