import Foundation
import Security

/// Persists the VPN profile and its password.
///
/// The split is deliberate: the profile is configuration and lives in `UserDefaults`, while the
/// password is a secret and lives in the Keychain. Nothing secret is ever written to a plist.
public struct VPNSettingsStore {

    private let defaultsKey: String
    private let keychainService: String

    public init(
        defaultsKey: String = "macauth.vpnProfile",
        keychainService: String = "com.pooya.MacAuth.vpn"
    ) {
        self.defaultsKey = defaultsKey
        self.keychainService = keychainService
    }

    // MARK: - Profile

    public func loadProfile() -> VPNProfile? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(VPNProfile.self, from: data)
    }

    public func save(profile: VPNProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Password

    /// Stores or replaces the IdP password for a named account.
    public func savePassword(_ password: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]

        let data = Data(password.utf8)
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if update == errSecSuccess { return }

        guard update == errSecItemNotFound else {
            throw KeychainStore.StoreError.unexpected(update)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "MacAuth: VPN password (\(account))"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStore.StoreError.unexpected(status) }
    }

    public func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Whether a password is stored, without reading it. Lets the UI say "saved" without
    /// pulling the secret into memory.
    public func hasPassword(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    public func deletePassword(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess { return }
        throw KeychainStore.StoreError.unexpected(status)
    }
}
