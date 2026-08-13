import Foundation
import Security

/// Persists accounts as macOS Keychain generic-password items, one item per account.
///
/// Layout of each item:
/// - `kSecAttrService`  the app's service name, so all items can be enumerated
/// - `kSecAttrAccount`  the account UUID, the stable identity
/// - `kSecAttrComment`  JSON metadata (issuer, label, algorithm, digits, period)
/// - `kSecValueData`    the raw TOTP secret
///
/// Metadata sits in an attribute rather than in the payload so listing accounts can request
/// attributes only. The secret is then never loaded except at the moment a code is generated.
public struct KeychainStore {

    public enum StoreError: Error, CustomStringConvertible {
        case duplicate
        case notFound
        case malformedMetadata
        case unexpected(OSStatus)

        public var description: String {
            switch self {
            case .duplicate:
                return "That account already exists in the Keychain."
            case .notFound:
                return "That account is no longer in the Keychain."
            case .malformedMetadata:
                return "A Keychain item could not be read; its metadata is malformed."
            case .unexpected(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return "Keychain error \(status): \(message ?? "unknown")."
            }
        }
    }

    /// Metadata persisted alongside the secret. Separate from `Account` so the stored shape can
    /// evolve without changing the model the UI uses.
    private struct Metadata: Codable {
        var issuer: String
        var label: String
        var algorithm: TOTP.Algorithm
        var digits: Int
        var period: Int
        /// Position in the menu, so the list order is stable and reorderable later.
        var sortIndex: Int
    }

    public let service: String

    public init(service: String = "com.pooya.MacAuth.accounts") {
        self.service = service
    }

    // MARK: - Reading

    /// All stored accounts, in menu order. Does not touch any secret.
    public func loadAccounts() throws -> [Account] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw StoreError.unexpected(status) }
        guard let items = result as? [[String: Any]] else { return [] }

        let decoded: [(account: Account, sortIndex: Int)] = items.compactMap { item in
            guard
                let idString = item[kSecAttrAccount as String] as? String,
                let id = UUID(uuidString: idString),
                let comment = item[kSecAttrComment as String] as? String,
                let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(comment.utf8))
            else {
                // Skip anything we cannot read rather than failing the whole list.
                return nil
            }

            let account = Account(
                id: id,
                issuer: metadata.issuer,
                label: metadata.label,
                algorithm: metadata.algorithm,
                digits: metadata.digits,
                period: metadata.period
            )
            return (account, metadata.sortIndex)
        }

        return decoded
            .sorted { left, right in
                if left.sortIndex != right.sortIndex { return left.sortIndex < right.sortIndex }
                return left.account.displayTitle.localizedCaseInsensitiveCompare(
                    right.account.displayTitle
                ) == .orderedAscending
            }
            .map(\.account)
    }

    /// Fetches one secret. Callers should use it immediately and not retain it.
    public func secret(for id: UUID) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { throw StoreError.notFound }
        guard status == errSecSuccess else { throw StoreError.unexpected(status) }
        guard let data = result as? Data else { throw StoreError.notFound }

        return data
    }

    // MARK: - Writing

    /// Adds a new account. Throws `.duplicate` if the id is already present.
    public func add(_ account: Account, secret: Data, sortIndex: Int? = nil) throws {
        let index = try sortIndex ?? (nextSortIndex())

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.id.uuidString,
            kSecAttrLabel as String: keychainLabel(for: account),
            kSecAttrComment as String: try metadataJSON(for: account, sortIndex: index),
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        attributes[kSecAttrDescription as String] = "MacAuth TOTP secret"

        let status = SecItemAdd(attributes as CFDictionary, nil)

        if status == errSecDuplicateItem { throw StoreError.duplicate }
        guard status == errSecSuccess else { throw StoreError.unexpected(status) }
    }

    /// Updates the metadata of an existing account, leaving the secret untouched.
    public func update(_ account: Account) throws {
        let existingIndex = try sortIndex(for: account.id) ?? 0

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.id.uuidString,
        ]

        let changes: [String: Any] = [
            kSecAttrLabel as String: keychainLabel(for: account),
            kSecAttrComment as String: try metadataJSON(for: account, sortIndex: existingIndex),
        ]

        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)

        if status == errSecItemNotFound { throw StoreError.notFound }
        guard status == errSecSuccess else { throw StoreError.unexpected(status) }
    }

    /// Replaces the secret of an existing account.
    public func updateSecret(for id: UUID, secret: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]

        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: secret] as CFDictionary
        )

        if status == errSecItemNotFound { throw StoreError.notFound }
        guard status == errSecSuccess else { throw StoreError.unexpected(status) }
    }

    /// Deletes an account and its secret. Deleting something already gone is not an error.
    public func delete(id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecItemNotFound || status == errSecSuccess { return }
        throw StoreError.unexpected(status)
    }

    /// Persists a new menu order.
    public func reorder(_ accounts: [Account]) throws {
        for (index, account) in accounts.enumerated() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account.id.uuidString,
            ]
            let changes: [String: Any] = [
                kSecAttrComment as String: try metadataJSON(for: account, sortIndex: index)
            ]
            let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw StoreError.unexpected(status)
            }
        }
    }

    /// Removes every item this store owns. Used by tests and by a future "reset" action.
    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess { return }
        throw StoreError.unexpected(status)
    }

    // MARK: - Helpers

    private func metadataJSON(for account: Account, sortIndex: Int) throws -> String {
        let metadata = Metadata(
            issuer: account.issuer,
            label: account.label,
            algorithm: account.algorithm,
            digits: account.digits,
            period: account.period,
            sortIndex: sortIndex
        )

        let data = try JSONEncoder().encode(metadata)
        guard let json = String(data: data, encoding: .utf8) else {
            throw StoreError.malformedMetadata
        }
        return json
    }

    /// Human-readable name shown in Keychain Access. Never contains the secret.
    private func keychainLabel(for account: Account) -> String {
        let title = account.issuer.isEmpty ? account.label : account.issuer
        let detail = account.issuer.isEmpty ? "" : " (\(account.label))"
        return "MacAuth: \(title)\(detail)"
    }

    private func nextSortIndex() throws -> Int {
        let existing = try loadAccounts()
        return existing.count
    }

    private func sortIndex(for id: UUID) throws -> Int? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let comment = item[kSecAttrComment as String] as? String,
              let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(comment.utf8))
        else {
            return nil
        }

        return metadata.sortIndex
    }
}
