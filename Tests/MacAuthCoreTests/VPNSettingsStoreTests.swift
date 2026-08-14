import XCTest
@testable import MacAuthCore

/// Storage of the connection list. Each test gets its own `UserDefaults` suite so nothing here
/// touches the real settings, and no Keychain call is made: passwords are covered elsewhere.
final class VPNSettingsStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: VPNSettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "macauth.tests.\(UUID().uuidString)"
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
        var work = VPNProfile.newConnection(name: "Work")
        work.host = "vpn.example.com"
        store.upsert(work)

        let lab = VPNProfile.newConnection(name: "Lab")
        store.upsert(lab)

        XCTAssertEqual(store.loadProfiles().map(\.displayName), ["Work", "Lab"])

        work.host = "vpn2.example.com"
        store.upsert(work)

        // Edited in place: still two connections, still in the same order.
        XCTAssertEqual(store.loadProfiles().count, 2)
        XCTAssertEqual(store.loadProfiles().first?.host, "vpn2.example.com")
    }

    func testSelectionSurvivesAReload() {
        let work = VPNProfile.newConnection(name: "Work")
        let lab = VPNProfile.newConnection(name: "Lab")
        store.upsert(work)
        store.upsert(lab)

        store.selectedProfileID = lab.id

        XCTAssertEqual(store.selectedProfile()?.id, lab.id)
    }

    /// Nothing selected, or a selection pointing at a connection that was deleted, must still
    /// leave the app pointed at something usable.
    func testSelectionFallsBackToTheFirstConnection() {
        let work = VPNProfile.newConnection(name: "Work")
        store.upsert(work)

        XCTAssertEqual(store.selectedProfile()?.id, work.id)

        store.selectedProfileID = UUID()
        XCTAssertEqual(store.selectedProfile()?.id, work.id)
    }

    func testDeleteRemovesAndMovesTheSelection() {
        let work = VPNProfile.newConnection(name: "Work")
        let lab = VPNProfile.newConnection(name: "Lab")
        store.upsert(work)
        store.upsert(lab)
        store.selectedProfileID = work.id

        store.delete(profileID: work.id)

        XCTAssertEqual(store.loadProfiles().map(\.displayName), ["Lab"])
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
        var old = VPNProfile.example
        old.name = "Old"
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
        XCTAssertEqual(profile.name, "")
        XCTAssertEqual(profile.displayName, "vpn.example.com")
    }

    // MARK: - Credentials

    func testCredentialsAreAddedEditedAndRemoved() {
        var work = Credential(name: "Work", username: "me@example.com")
        store.upsert(work)
        XCTAssertEqual(store.loadCredentials().map(\.displayName), ["Work"])

        work.username = "me2@example.com"
        store.upsert(work)
        XCTAssertEqual(store.loadCredentials().count, 1)
        XCTAssertEqual(store.loadCredentials().first?.username, "me2@example.com")

        store.delete(credentialID: work.id)
        XCTAssertTrue(store.loadCredentials().isEmpty)
    }

    /// Deleting a credential must not leave a connection pointing at one that is gone, or the
    /// connect would fail with nothing on screen to explain why.
    func testDeletingACredentialClearsTheConnectionsUsingIt() {
        let credential = Credential(username: "me@example.com")
        store.upsert(credential)

        var profile = VPNProfile.newConnection(name: "Work")
        profile.host = "vpn.example.com"
        profile.credentialID = credential.id
        store.upsert(profile)

        store.delete(credentialID: credential.id)

        XCTAssertNil(store.loadProfiles().first?.credentialID)
    }

    func testEachCredentialGetsItsOwnKeychainAccount() {
        let first = Credential()
        let second = Credential()

        XCTAssertNotEqual(first.keychainAccount, second.keychainAccount)
        XCTAssertTrue(first.keychainAccount.contains(first.id.uuidString))
    }

    /// The username and password settings used to live inside each connection. They become
    /// standalone credentials, keeping the old Keychain account name so the saved password is
    /// still found rather than silently lost.
    func testInlineCredentialsMigrateOutOfTheConnections() {
        var old = VPNProfile.example
        old.username = "me@example.com"
        old.passwordSource = .loginKeychain
        old.passwordKeychainServer = "sso.example.com"
        store.save(profiles: [old])

        let credentials = store.loadCredentials()

        XCTAssertEqual(credentials.count, 1)
        XCTAssertEqual(credentials.first?.username, "me@example.com")
        XCTAssertEqual(credentials.first?.passwordSource, .loginKeychain)
        XCTAssertEqual(credentials.first?.passwordKeychainServer, "sso.example.com")
        XCTAssertEqual(credentials.first?.keychainAccount, old.credentialAccount)

        // And the connection now points at it.
        XCTAssertEqual(store.loadProfiles().first?.credentialID, credentials.first?.id)
    }

    /// Two connections sharing a username share the one credential, rather than making a
    /// duplicate whose password would have to be typed again.
    func testTwoConnectionsWithOneUsernameShareACredential() {
        var work = VPNProfile.newConnection(name: "Work")
        work.host = "a.example.com"
        work.username = "me@example.com"

        var lab = VPNProfile.newConnection(name: "Lab")
        lab.host = "b.example.com"
        lab.username = "me@example.com"

        store.save(profiles: [work, lab])

        XCTAssertEqual(store.loadCredentials().count, 1)
        let ids = store.loadProfiles().map(\.credentialID)
        XCTAssertEqual(ids.first, ids.last)
        XCTAssertNotNil(ids.first ?? nil)
    }

    func testCredentialNameFallsBackToTheUsername() {
        var credential = Credential(username: "me@example.com")
        XCTAssertEqual(credential.displayName, "me@example.com")
        XCTAssertEqual(credential.displaySubtitle, "Save it here")

        credential.name = "Work"
        XCTAssertEqual(credential.displayName, "Work")
        XCTAssertEqual(credential.displaySubtitle, "me@example.com")
    }

    // MARK: - Naming

    func testDisplayNameFallsBackToTheHostWithoutItsPort() {
        var profile = VPNProfile.newConnection()
        profile.host = "mfa-vpn.example.com:28015"

        XCTAssertEqual(profile.displayName, "mfa-vpn.example.com")

        profile.name = "  Work  "
        XCTAssertEqual(profile.displayName, "Work")
    }

    func testAnEmptyConnectionSaysSo() {
        XCTAssertEqual(VPNProfile.newConnection().displayName, "New connection")
    }
}
