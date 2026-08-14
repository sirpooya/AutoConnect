import Foundation
import Security

/// Persists the VPN profile and its password.
///
/// The split is deliberate: the profile is configuration and lives in `UserDefaults`, while the
/// password is a secret and lives in the Keychain. Nothing secret is ever written to a plist.
public struct VPNSettingsStore {

    private let defaultsKey: String
    private let listKey: String
    private let selectionKey: String
    private let keychainService: String
    private let defaults: UserDefaults

    public init(
        defaultsKey: String = "macauth.vpnProfile",
        keychainService: String = "com.pooya.MacAuth.vpn",
        defaults: UserDefaults = .standard
    ) {
        self.defaultsKey = defaultsKey
        self.listKey = defaultsKey + "s"
        self.selectionKey = defaultsKey + ".selected"
        self.keychainService = keychainService
        self.defaults = defaults
    }

    // MARK: - Connections

    /// Every configured connection, oldest first.
    ///
    /// A single profile saved by an earlier build is migrated into a one-element list on first
    /// read, keeping its identity and therefore its Keychain item.
    public func loadProfiles() -> [VPNProfile] {
        if let data = defaults.data(forKey: listKey),
           let profiles = try? JSONDecoder().decode([VPNProfile].self, from: data) {
            return profiles
        }

        guard let migrated = loadProfile() else { return [] }
        save(profiles: [migrated])
        return [migrated]
    }

    public func save(profiles: [VPNProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: listKey)

        // Keep the single-profile key in step with the selected connection, so anything still
        // reading it sees the connection in use rather than a stale one.
        if let selected = profiles.first(where: { $0.id == selectedProfileID }) ?? profiles.first {
            save(profile: selected)
        }
    }

    /// Which connection the menu bar acts on. Nil until one is chosen.
    public var selectedProfileID: UUID? {
        get { defaults.string(forKey: selectionKey).flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: selectionKey) }
    }

    /// The selected connection, falling back to the first one so the app is never pointed at
    /// nothing while connections exist.
    public func selectedProfile() -> VPNProfile? {
        let profiles = loadProfiles()
        return profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    /// Inserts or replaces one connection, leaving the others alone.
    public func upsert(_ profile: VPNProfile) {
        var profiles = loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        save(profiles: profiles)
    }

    /// Removes a connection and the password stored for it.
    public func delete(profileID: UUID) {
        let profiles = loadProfiles()
        guard let removed = profiles.first(where: { $0.id == profileID }) else { return }

        try? deletePassword(account: removed.credentialAccount)
        save(profiles: profiles.filter { $0.id != profileID })

        if selectedProfileID == profileID {
            selectedProfileID = loadProfiles().first?.id
        }
    }

    // MARK: - Profile

    public func loadProfile() -> VPNProfile? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(VPNProfile.self, from: data)
    }

    public func save(profile: VPNProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: defaultsKey)
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
