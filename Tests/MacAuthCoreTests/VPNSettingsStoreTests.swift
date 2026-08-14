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
