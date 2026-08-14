import AppKit
import Combine
import Foundation
import MacAuthCore

/// Which screen the menu bar panel is showing.
enum PanelRoute: Equatable {
    case list
    case add
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

        copiedAccountID = account.id
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.copiedAccountID = nil
        }
    }

    // MARK: - Writing

    func add(_ parsed: OTPAuthURI.Parsed) {
        do {
            try store.add(parsed.account, secret: parsed.secret)
            reload()
            route = .list
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Adds an account from manually typed fields.
    func addManual(
        issuer: String,
        label: String,
        secret rawSecret: String,
        algorithm: TOTP.Algorithm,
        digits: Int,
        period: Int
    ) {
        do {
            let secret = try Base32.decode(rawSecret)
            let account = Account(
                issuer: issuer.trimmingCharacters(in: .whitespaces),
                label: label.trimmingCharacters(in: .whitespaces),
                algorithm: algorithm,
                digits: digits,
                period: period
            )
            try store.add(account, secret: secret)
            reload()
            route = .list
        } catch {
            errorMessage = describe(error)
        }
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

    private func performScan(_ scan: () throws -> OTPAuthURI.Parsed) {
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
