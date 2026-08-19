import XCTest
@testable import AutoConnectCore

/// The rename from MacAuth to AutoConnect moved every storage identifier, so this covers the one
/// job that keeps that from reading as data loss.
///
/// Both the source domain and the Keychain services are injected: a test that re-tagged the real
/// `com.pooya.MacAuth.accounts` items would be rewriting this Mac's actual secrets.
final class LegacyMigrationTests: XCTestCase {

    private var suiteName = ""
    private var legacyDomain = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        suiteName = "autoconnect.tests.\(id)"
        legacyDomain = "autoconnect.tests.legacy.\(id)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.removePersistentDomain(forName: legacyDomain)
        super.tearDown()
    }

    private func seedLegacy(_ contents: [String: Any]) {
        defaults.setPersistentDomain(contents, forName: legacyDomain)
    }

    // MARK: - Defaults

    func testCarriesPrefixedKeysUnderTheNewPrefix() {
        seedLegacy([
            "macauth.autoReconnect": true,
            "macauth.vpnProfile.selected": "a-uuid",
        ])

        XCTAssertTrue(LegacyMigration.migrateDefaults(in: defaults, from: legacyDomain))

        XCTAssertTrue(defaults.bool(forKey: "autoconnect.autoReconnect"))
        XCTAssertEqual(defaults.string(forKey: "autoconnect.vpnProfile.selected"), "a-uuid")
    }

    /// The profile is stored as encoded JSON, so the value has to survive as `Data` rather than
    /// being coerced into a string along the way.
    func testCarriesDataValuesIntact() {
        var profile = VPNProfile.newConnection()
        profile.host = "vpn.example.com"
        let encoded = try! JSONEncoder().encode([profile])
        seedLegacy(["macauth.vpnProfiles": encoded])

        LegacyMigration.migrateDefaults(in: defaults, from: legacyDomain)

        let carried = defaults.data(forKey: "autoconnect.vpnProfiles")
        let decoded = try? JSONDecoder().decode([VPNProfile].self, from: XCTUnwrap(carried))
        XCTAssertEqual(decoded?.first?.host, "vpn.example.com")
        XCTAssertEqual(decoded?.first?.id, profile.id, "the identity keys the Keychain item")
    }

    func testLeavesUnprefixedKeysAlone() {
        seedLegacy(["NSQuitAlwaysKeepsWindows": true, "unrelated": "value"])

        XCTAssertFalse(LegacyMigration.migrateDefaults(in: defaults, from: legacyDomain))
        XCTAssertNil(defaults.object(forKey: "autoconnect.unrelated"))
        XCTAssertNil(defaults.object(forKey: "unrelated"))
    }

    /// A setting chosen since the rename outranks the stale one it replaced.
    func testDoesNotOverwriteAValueAlreadySet() {
        seedLegacy(["macauth.autoReconnect": true])
        defaults.set(false, forKey: "autoconnect.autoReconnect")

        XCTAssertFalse(LegacyMigration.migrateDefaults(in: defaults, from: legacyDomain))
        XCTAssertFalse(defaults.bool(forKey: "autoconnect.autoReconnect"))
    }

    func testMissingLegacyDomainIsNotAnError() {
        XCTAssertFalse(LegacyMigration.migrateDefaults(in: defaults, from: legacyDomain))
    }

    // MARK: - Running once

    func testRunsOnceThenReportsNothingToDo() {
        seedLegacy(["macauth.autoReconnect": true])

        XCTAssertTrue(LegacyMigration.runIfNeeded(
            defaults: defaults,
            legacyDomain: legacyDomain,
            keychainServices: []
        ))
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.completionKey))

        // Second launch: the old domain still exists, but the work is done.
        defaults.removeObject(forKey: "autoconnect.autoReconnect")
        XCTAssertFalse(LegacyMigration.runIfNeeded(
            defaults: defaults,
            legacyDomain: legacyDomain,
            keychainServices: []
        ))
        XCTAssertNil(defaults.object(forKey: "autoconnect.autoReconnect"))
    }

    /// A Mac that never ran the old app still has to come out of this marked done, so the check
    /// is not repeated on every launch forever.
    func testMarksCompleteEvenWithNothingToCarry() {
        XCTAssertFalse(LegacyMigration.runIfNeeded(
            defaults: defaults,
            legacyDomain: legacyDomain,
            keychainServices: []
        ))
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.completionKey))
    }

    // MARK: - Keychain

    /// Re-tagging is what preserves the secret and its access control, so the item found under
    /// the new service must be the same item, data included.
    func testRetagsAKeychainItemInPlace() throws {
        let old = "com.pooya.AutoConnect.tests.old.\(UUID().uuidString)"
        let new = "com.pooya.AutoConnect.tests.new.\(UUID().uuidString)"
        let account = UUID().uuidString
        let secret = Data("a-totp-seed".utf8)

        let added = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: old,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
        ] as CFDictionary, nil)
        try XCTSkipUnless(added == errSecSuccess, "no writable Keychain in this environment")

        addTeardownBlock {
            for service in [old, new] {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                ] as CFDictionary)
            }
        }

        XCTAssertTrue(LegacyMigration.migrateKeychainItems([(old: old, new: new)]))

        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: new,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ] as CFDictionary, &result)

        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(result as? Data, secret)
    }

    // MARK: - Keychain labels

    /// The label is what macOS quotes in the panel asking permission to read an item, so a stale
    /// one has the app asking for something under a name the user does not recognise.
    func testRewritesTheLabelPrefixKeepingTheRest() throws {
        let service = "com.pooya.AutoConnect.tests.label.\(UUID().uuidString)"
        let account = UUID().uuidString

        let added = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "MacAuth: DigikalaMFA (p.kamel@digikala.com)",
            kSecValueData as String: Data("a-totp-seed".utf8),
        ] as CFDictionary, nil)
        try XCTSkipUnless(added == errSecSuccess, "no writable Keychain in this environment")

        addTeardownBlock {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        XCTAssertTrue(LegacyMigration.migrateKeychainDisplayNames([service]).renamed)

        XCTAssertEqual(
            try label(ofService: service, account: account),
            "AutoConnect: DigikalaMFA (p.kamel@digikala.com)",
            "only the prefix changes, since the rest names the account"
        )
    }

    /// Addressing is by service and account, and the secret is never fetched, so neither may move.
    func testRelabellingLeavesTheSecretAndTheAddressAlone() throws {
        let service = "com.pooya.AutoConnect.tests.label.\(UUID().uuidString)"
        let account = UUID().uuidString
        let secret = Data("a-totp-seed".utf8)

        let added = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "MacAuth: VPN password (vpn.example.com)",
            kSecValueData as String: secret,
        ] as CFDictionary, nil)
        try XCTSkipUnless(added == errSecSuccess, "no writable Keychain in this environment")

        addTeardownBlock {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        LegacyMigration.migrateKeychainDisplayNames([service])

        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ] as CFDictionary, &result)

        XCTAssertEqual(status, errSecSuccess, "still addressed by the same service and account")
        XCTAssertEqual(result as? Data, secret)
    }

    /// Each item keeps its own suffix. A single `SecItemUpdate` over the service would give them
    /// all the same label, which is why they are rewritten one at a time.
    func testEachItemKeepsItsOwnName() throws {
        let service = "com.pooya.AutoConnect.tests.label.\(UUID().uuidString)"
        let names = ["MacAuth: One (a@example.com)", "MacAuth: Two (b@example.com)"]
        var accounts: [String] = []

        for name in names {
            let account = UUID().uuidString
            accounts.append(account)
            let added = SecItemAdd([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrLabel as String: name,
                kSecValueData as String: Data(account.utf8),
            ] as CFDictionary, nil)
            try XCTSkipUnless(added == errSecSuccess, "no writable Keychain in this environment")
        }

        addTeardownBlock {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        LegacyMigration.migrateKeychainDisplayNames([service])

        XCTAssertEqual(try label(ofService: service, account: accounts[0]),
                       "AutoConnect: One (a@example.com)")
        XCTAssertEqual(try label(ofService: service, account: accounts[1]),
                       "AutoConnect: Two (b@example.com)")
    }

    /// An item already carrying the new name is left exactly as it is, so a second launch is a
    /// no-op rather than producing "AutoConnect: AutoConnect: ...".
    func testLeavesAlreadyRenamedLabelsAlone() throws {
        let service = "com.pooya.AutoConnect.tests.label.\(UUID().uuidString)"
        let account = UUID().uuidString

        let added = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "AutoConnect: DigikalaMFA (p.kamel@digikala.com)",
            kSecValueData as String: Data("a-totp-seed".utf8),
        ] as CFDictionary, nil)
        try XCTSkipUnless(added == errSecSuccess, "no writable Keychain in this environment")

        addTeardownBlock {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        let outcome = LegacyMigration.migrateKeychainDisplayNames([service])
        XCTAssertFalse(outcome.renamed, "nothing to do, so it reports no change")
        XCTAssertFalse(outcome.failed, "and nothing to retry")
        XCTAssertEqual(try label(ofService: service, account: account),
                       "AutoConnect: DigikalaMFA (p.kamel@digikala.com)")
    }

    /// The first migration shipped without the relabelling, so the flag recording that migration
    /// finished must not be allowed to skip it.
    func testRelabellingStillRunsOnAMacThatAlreadyMigrated() throws {
        let service = "com.pooya.AutoConnect.tests.label.\(UUID().uuidString)"
        let account = UUID().uuidString

        let added = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "MacAuth: DigikalaMFA (p.kamel@digikala.com)",
            kSecValueData as String: Data("a-totp-seed".utf8),
        ] as CFDictionary, nil)
        try XCTSkipUnless(added == errSecSuccess, "no writable Keychain in this environment")

        addTeardownBlock {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        defaults.set(true, forKey: LegacyMigration.completionKey)

        LegacyMigration.runIfNeeded(
            defaults: defaults,
            legacyDomain: legacyDomain,
            keychainServices: [(old: service, new: service)]
        )

        XCTAssertEqual(try label(ofService: service, account: account),
                       "AutoConnect: DigikalaMFA (p.kamel@digikala.com)")
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.renameKey))
    }

    /// The description is the "Kind" column in Keychain Access, and it carried the old name too,
    /// so the rule is a leading word rather than the label's `MacAuth: ` prefix.
    func testRewritesTheDescriptionAsWell() throws {
        let service = "com.pooya.AutoConnect.tests.label.\(UUID().uuidString)"
        let account = UUID().uuidString

        let added = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "MacAuth: DigikalaMFA (p.kamel@digikala.com)",
            kSecAttrDescription as String: "MacAuth TOTP secret",
            kSecValueData as String: Data("a-totp-seed".utf8),
        ] as CFDictionary, nil)
        try XCTSkipUnless(added == errSecSuccess, "no writable Keychain in this environment")

        addTeardownBlock {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        XCTAssertTrue(LegacyMigration.migrateKeychainDisplayNames([service]).renamed)

        XCTAssertEqual(try attribute(kSecAttrDescription, ofService: service, account: account),
                       "AutoConnect TOTP secret")
        XCTAssertEqual(try label(ofService: service, account: account),
                       "AutoConnect: DigikalaMFA (p.kamel@digikala.com)")
    }

    private func label(ofService service: String, account: String) throws -> String {
        try attribute(kSecAttrLabel, ofService: service, account: account)
    }

    private func attribute(
        _ attribute: CFString,
        ofService service: String,
        account: String
    ) throws -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &result)
        XCTAssertEqual(status, errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        return try XCTUnwrap(attributes[attribute as String] as? String)
    }

    func testNothingUnderTheOldServiceIsNotAnError() {
        let absent = "com.pooya.AutoConnect.tests.absent.\(UUID().uuidString)"
        XCTAssertFalse(LegacyMigration.migrateKeychainItems([(old: absent, new: absent + ".new")]))
    }
}
