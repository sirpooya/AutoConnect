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

    /// The old product name, as it still appears at the front of stored display attributes, and
    /// what replaces it.
    ///
    /// These attributes are the ones macOS quotes back to the user: the label names the item in
    /// the panel asking permission to read it, and the description is the "Kind" column in
    /// Keychain Access. Leaving them stale means the app asks for something under a name the user
    /// no longer recognises.
    static let legacyName = "MacAuth"
    static let currentName = "AutoConnect"

    /// `MacAuth: Issuer (account)` for the label, `MacAuth TOTP secret` for the description, so
    /// the rule is a leading word rather than a fixed prefix.
    static let renamedAttributes = [kSecAttrLabel as String, kSecAttrDescription as String]

    /// Written into the new domain, so a second launch skips the work.
    static let completionKey = "autoconnect.migratedFromMacAuth"

    /// Recorded separately from `completionKey`, so a Mac that already migrated before these
    /// attributes were noticed still gets them rewritten.
    static let renameKey = "autoconnect.renamedKeychainItems"

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
        var changed = false

        if !defaults.bool(forKey: completionKey) {
            // Defaults first: the Keychain step is the one that can fail on a locked Keychain, and
            // the settings should land either way.
            let movedSettings = migrateDefaults(in: defaults, from: legacyDomain)
            let movedSecrets = migrateKeychainItems(keychainServices)
            defaults.set(true, forKey: completionKey)
            changed = movedSettings || movedSecrets
        }

        // Deliberately outside that branch, and keyed separately. The first migration shipped
        // without it, so every Mac that has already run one is sitting on items still labelled
        // with the old name, and the flag saying migration is done would keep it that way.
        //
        // It runs after the re-tagging above, which is what puts the items under the new service
        // names this reads.
        if !defaults.bool(forKey: renameKey) {
            let result = migrateKeychainDisplayNames(keychainServices.map(\.new))
            // Rewriting a label needs the item's access control, so this is one of the few things
            // here a person can refuse, and a locked Keychain refuses it too. Record it as done
            // only when nothing was left behind, or a single Deny would strand the old name for
            // good.
            if !result.failed {
                defaults.set(true, forKey: renameKey)
            }
            changed = changed || result.renamed
        }

        return changed
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

    /// Rewrites the leading `MacAuth` in each item's label and description to `AutoConnect`.
    ///
    /// Cosmetic in the sense that nothing reads it: the item is addressed by service and account,
    /// and both of those are already correct by the time this runs. It is not cosmetic to the
    /// person being asked to approve access, who is shown the label and nothing else.
    ///
    /// One item at a time, unlike the service re-tag, because each keeps its own suffix and a
    /// single `SecItemUpdate` would give every matching item the same new label. Only the label
    /// is written, so the secret, the creation date and the access control are untouched.
    /// - `renamed`: at least one item was rewritten.
    /// - `failed`: at least one item still carries the old name, so this must run again.
    struct NameMigration {
        var renamed = false
        var failed = false
    }

    @discardableResult
    static func migrateKeychainDisplayNames(_ services: [String]) -> NameMigration {
        var outcome = NameMigration()

        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                // Attributes only. Asking for the data would make this prompt for the very
                // permission the stale label is confusing people into refusing.
                kSecReturnAttributes as String: true,
            ]

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let items = result as? [[String: Any]] else {
                // Nothing stored is the ordinary case and is not a failure. Anything else means
                // the Keychain could not be read, so this should be tried again next launch.
                if status != errSecItemNotFound { outcome.failed = true }
                continue
            }

            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String else { continue }

                var changes: [String: Any] = [:]
                for attribute in renamedAttributes {
                    guard let value = item[attribute] as? String,
                          value.hasPrefix(legacyName) else { continue }
                    changes[attribute] = currentName + value.dropFirst(legacyName.count)
                }
                guard !changes.isEmpty else { continue }

                let itemQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                ]

                if SecItemUpdate(itemQuery as CFDictionary, changes as CFDictionary) == errSecSuccess {
                    outcome.renamed = true
                } else {
                    outcome.failed = true
                }
            }
        }

        return outcome
    }
}
