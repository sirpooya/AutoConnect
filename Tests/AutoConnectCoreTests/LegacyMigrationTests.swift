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

    func testNothingUnderTheOldServiceIsNotAnError() {
        let absent = "com.pooya.AutoConnect.tests.absent.\(UUID().uuidString)"
        XCTAssertFalse(LegacyMigration.migrateKeychainItems([(old: absent, new: absent + ".new")]))
    }
}
