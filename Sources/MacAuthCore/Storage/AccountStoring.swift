import Foundation

/// What `AppState` needs from storage. Extracted so the account list can be driven by fake data
/// in the playground and in tests without touching the real Keychain.
public protocol AccountStoring {
    func loadAccounts() throws -> [Account]
    func secret(for id: UUID) throws -> Data
    func add(_ account: Account, secret: Data, sortIndex: Int?) throws
    func update(_ account: Account) throws
    func updateSecret(for id: UUID, secret: Data) throws
    func delete(id: UUID) throws
    func reorder(_ accounts: [Account]) throws
}

extension AccountStoring {
    public func add(_ account: Account, secret: Data) throws {
        try add(account, secret: secret, sortIndex: nil)
    }
}

extension KeychainStore: AccountStoring {}

/// Volatile store for playgrounds and tests. Never persists, so nothing it holds can leak into
/// the user's Keychain.
public final class InMemoryAccountStore: AccountStoring {

    private var accounts: [Account] = []
    private var secrets: [UUID: Data] = [:]

    public init() {}

    /// Seeds plausible-looking accounts. The secret is the RFC 6238 test seed, so the codes it
    /// produces are real TOTP codes, just not anyone's.
    public convenience init(demoAccounts: [(issuer: String, label: String)]) {
        self.init()
        let secret = Data("12345678901234567890".utf8)
        for entry in demoAccounts {
            try? add(
                Account(issuer: entry.issuer, label: entry.label),
                secret: secret,
                sortIndex: nil
            )
        }
    }

    public func loadAccounts() throws -> [Account] { accounts }

    public func secret(for id: UUID) throws -> Data {
        guard let secret = secrets[id] else { throw KeychainStore.StoreError.notFound }
        return secret
    }

    public func add(_ account: Account, secret: Data, sortIndex: Int?) throws {
        guard !accounts.contains(where: { $0.id == account.id }) else {
            throw KeychainStore.StoreError.duplicate
        }
        if let sortIndex, sortIndex <= accounts.count {
            accounts.insert(account, at: sortIndex)
        } else {
            accounts.append(account)
        }
        secrets[account.id] = secret
    }

    public func update(_ account: Account) throws {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            throw KeychainStore.StoreError.notFound
        }
        accounts[index] = account
    }

    public func updateSecret(for id: UUID, secret: Data) throws {
        guard secrets[id] != nil else { throw KeychainStore.StoreError.notFound }
        secrets[id] = secret
    }

    public func delete(id: UUID) throws {
        accounts.removeAll { $0.id == id }
        secrets[id] = nil
    }

    public func reorder(_ reordered: [Account]) throws {
        accounts = reordered
    }
}
