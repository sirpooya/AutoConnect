import XCTest
@testable import AutoConnectCore

/// Storage of the connection list. Each test gets its own `UserDefaults` suite so nothing here
/// touches the real settings, and no Keychain call is made: passwords are covered elsewhere.
final class VPNSettingsStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: VPNSettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "autoconnect.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = VPNSettingsStore(defaultsKey: "profile", defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - List

    func testStartsWithNoConnections() {
        XCTAssertTrue(store.loadProfiles().isEmpty)
        XCTAssertNil(store.selectedProfile())
    }

    func testUpsertAddsThenReplacesInPlace() {
        var work = VPNProfile.newConnection()
        work.host = "vpn.example.com"
        store.upsert(work)

        var lab = VPNProfile.newConnection()
        lab.host = "lab.example.com"
        store.upsert(lab)

        XCTAssertEqual(
            store.loadProfiles().map(\.displayName),
            ["vpn.example.com", "lab.example.com"]
        )

        work.host = "vpn2.example.com"
        store.upsert(work)

        // Edited in place: still two connections, still in the same order.
        XCTAssertEqual(store.loadProfiles().count, 2)
        XCTAssertEqual(store.loadProfiles().first?.host, "vpn2.example.com")
    }

    func testSelectionSurvivesAReload() {
        let work = VPNProfile.newConnection()
        let lab = VPNProfile.newConnection()
        store.upsert(work)
        store.upsert(lab)

        store.selectedProfileID = lab.id

        XCTAssertEqual(store.selectedProfile()?.id, lab.id)
    }

    /// Nothing selected, or a selection pointing at a connection that was deleted, must still
    /// leave the app pointed at something usable.
    func testSelectionFallsBackToTheFirstConnection() {
        let work = VPNProfile.newConnection()
        store.upsert(work)

        XCTAssertEqual(store.selectedProfile()?.id, work.id)

        store.selectedProfileID = UUID()
        XCTAssertEqual(store.selectedProfile()?.id, work.id)
    }

    func testDeleteRemovesAndMovesTheSelection() {
        var work = VPNProfile.newConnection()
        work.host = "vpn.example.com"
        var lab = VPNProfile.newConnection()
        lab.host = "lab.example.com"
        store.upsert(work)
        store.upsert(lab)
        store.selectedProfileID = work.id

        store.delete(profileID: work.id)

        XCTAssertEqual(store.loadProfiles().map(\.displayName), ["lab.example.com"])
        XCTAssertEqual(store.selectedProfileID, lab.id)
    }

    /// Two connections must never share a Keychain item, or deleting one takes the other's
    /// password with it.
    func testEachConnectionGetsItsOwnKeychainAccount() {
        let first = VPNProfile.newConnection()
        let second = VPNProfile.newConnection()

        XCTAssertNotEqual(first.credentialAccount, second.credentialAccount)
        XCTAssertTrue(first.credentialAccount.contains(first.id.uuidString))
    }

    // MARK: - Migration

    /// A profile saved by a build that only had one gets carried into the list, keeping its
    /// identity and therefore its stored password.
    func testASingleSavedProfileBecomesTheFirstConnection() {
        let old = VPNProfile.example
        store.save(profile: old)

        let migrated = store.loadProfiles()

        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated.first?.id, old.id)
        XCTAssertEqual(migrated.first?.credentialAccount, old.credentialAccount)

        // And it is written to the list, so the migration happens once rather than on every read.
        XCTAssertNotNil(defaults.data(forKey: "profiles"))
    }

    /// Older saved JSON has none of the keys added since. Decoding must fill them in rather than
    /// throwing away the whole profile, which would read as settings vanishing on upgrade.
    func testOlderJSONDecodesWithDefaults() throws {
        let json = """
        {"host":"vpn.example.com:443","tunnelGroup":"OLD","username":"me@example.com",
         "credentialAccount":"vpn-password","openconnectPath":"/usr/local/bin/openconnect"}
        """

        let profile = try JSONDecoder().decode(VPNProfile.self, from: Data(json.utf8))

        XCTAssertEqual(profile.host, "vpn.example.com:443")
        XCTAssertEqual(profile.tunnelGroup, "OLD")
        XCTAssertEqual(profile.credentialAccount, "vpn-password")
        XCTAssertEqual(profile.passwordSource, .stored)
        XCTAssertNil(profile.certificateSHA1)
        XCTAssertEqual(profile.displayName, "vpn.example.com")
    }

    // MARK: - Credentials

    /// Credentials were briefly a list of their own. Anything saved that way is folded back
    /// into the connection that used it, Keychain account name included, so the password that
    /// was already stored is still the one found.
    func testStandaloneCredentialsFoldBackIntoTheirConnection() throws {
        let credential = Credential(
            username: "me@example.com",
            passwordSource: .loginKeychain,
            passwordKeychainServer: "sso.example.com"
        )
        defaults.set(try JSONEncoder().encode([credential]), forKey: "profile.credentials")

        var profile = VPNProfile.newConnection()
        profile.host = "vpn.example.com"
        profile.credentialID = credential.id
        store.save(profiles: [profile])

        store.foldCredentialsIntoConnections()

        let folded = try XCTUnwrap(store.loadProfiles().first)
        XCTAssertEqual(folded.username, "me@example.com")
        XCTAssertEqual(folded.passwordSource, .loginKeychain)
        XCTAssertEqual(folded.passwordKeychainServer, "sso.example.com")
        XCTAssertEqual(folded.credentialAccount, credential.keychainAccount)
        XCTAssertNil(folded.credentialID)

        // And the list is gone, so the fold happens once.
        XCTAssertNil(defaults.data(forKey: "profile.credentials"))
    }

    func testFoldingIsHarmlessWithNothingToFold() {
        var profile = VPNProfile.newConnection()
        profile.host = "vpn.example.com"
        profile.username = "me@example.com"
        store.save(profiles: [profile])

        store.foldCredentialsIntoConnections()

        XCTAssertEqual(store.loadProfiles().first?.username, "me@example.com")
    }

    // MARK: - Naming

    /// A connection has no name of its own: the address is what identifies it, minus the port,
    /// which is noise in a title.
    func testDisplayNameIsTheHostWithoutItsPort() {
        var profile = VPNProfile.newConnection()
        profile.host = "mfa-vpn.example.com:28015"

        XCTAssertEqual(profile.displayName, "mfa-vpn.example.com")
    }

    func testAnEmptyConnectionSaysSo() {
        XCTAssertEqual(VPNProfile.newConnection().displayName, "New connection")
    }
}
