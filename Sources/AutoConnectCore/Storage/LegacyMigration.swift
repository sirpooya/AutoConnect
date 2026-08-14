import Foundation
import Security

/// Carries this Mac's data across the rename from MacAuth to AutoConnect.
///
/// Three identifiers had the old name baked into them, and all three decide where data lives
/// rather than merely what it is called:
///
/// - the Keychain services holding the TOTP secrets and the VPN password,
/// - the bundle identifier, which picks the preferences domain `UserDefaults.standard` reads,
/// - the `macauth.` prefix on every defaults key.
///
/// Renaming all three at once would leave a working app pointing at empty storage: the accounts
/// would appear deleted and the gateway would need configuring again. This moves what the old
/// names hold onto the new ones, once, and records that it has.
///
/// Delete this once no machine is still carrying MacAuth-era data.
public enum LegacyMigration {

    /// The bundle identifier the app shipped under, and therefore the preferences domain that
    /// still holds the settings written before the rename.
    public static let legacyBundleIdentifier = "com.pooya.MacAuth"

    static let legacyDefaultsPrefix = "macauth."
    static let defaultsPrefix = "autoconnect."

    /// Keychain services to re-tag, old name to new.
    public static let services: [(old: String, new: String)] = [
        ("com.pooya.MacAuth.accounts", KeychainStore.defaultService),
        ("com.pooya.MacAuth.vpn", VPNSettingsStore.defaultKeychainService),
    ]

    /// Written into the new domain, so a second launch skips the work.
    static let completionKey = "autoconnect.migratedFromMacAuth"

    /// Moves anything the old names still hold. Safe to call more than once, and a no-op on a
    /// Mac that never ran the app under its old name.
    ///
    /// Must run before any store is constructed, since the whole point is to fill in what those
    /// stores are about to read.
    /// The Keychain services and legacy domain are parameters so tests can exercise the logic
    /// without re-tagging this Mac's real items.
    @discardableResult
    public static func runIfNeeded(
        defaults: UserDefaults = .standard,
        legacyDomain: String = legacyBundleIdentifier,
        keychainServices: [(old: String, new: String)] = services
    ) -> Bool {
        guard !defaults.bool(forKey: completionKey) else { return false }

        // Defaults first: the Keychain step is the one that can fail on a locked Keychain, and
        // the settings should land either way.
        let movedSettings = migrateDefaults(in: defaults, from: legacyDomain)
        let movedSecrets = migrateKeychainItems(keychainServices)

        defaults.set(true, forKey: completionKey)
        return movedSettings || movedSecrets
    }

    // MARK: - Defaults

    /// Copies every `macauth.`-prefixed key from the old preferences domain into this one under
    /// the new prefix. Existing values win, so a setting already chosen since the rename is not
    /// overwritten by its stale predecessor.
    @discardableResult
    static func migrateDefaults(
        in defaults: UserDefaults,
        from legacyDomain: String = legacyBundleIdentifier
    ) -> Bool {
        guard let legacy = defaults.persistentDomain(forName: legacyDomain) else {
            return false
        }

        var moved = false
        for (key, value) in legacy where key.hasPrefix(legacyDefaultsPrefix) {
            let renamed = defaultsPrefix + key.dropFirst(legacyDefaultsPrefix.count)
            guard defaults.object(forKey: renamed) == nil else { continue }
            defaults.set(value, forKey: renamed)
            moved = true
        }
        return moved
    }

    // MARK: - Keychain

    /// Re-tags each item's `kSecAttrService` in place.
    ///
    /// In place matters: rewriting the attribute keeps the item's secret, its creation date and
    /// its access control exactly as they were, where copying to a new item and deleting the old
    /// one would briefly hold every secret in memory and lose the ACL if it failed halfway.
    @discardableResult
    static func migrateKeychainItems(_ services: [(old: String, new: String)] = services) -> Bool {
        var moved = false

        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service.old,
            ]
            let changes: [String: Any] = [kSecAttrService as String: service.new]

            // errSecItemNotFound is the normal answer: nothing was stored under the old name.
            if SecItemUpdate(query as CFDictionary, changes as CFDictionary) == errSecSuccess {
                moved = true
            }
        }

        return moved
    }
}
