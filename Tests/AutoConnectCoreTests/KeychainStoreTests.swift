import XCTest
@testable import AutoConnectCore

/// Exercises the real macOS Keychain against a throwaway service name, so it never touches
/// the accounts the shipping app stores.
final class KeychainStoreTests: XCTestCase {

    private var store: KeychainStore!

    override func setUpWithError() throws {
        store = KeychainStore(service: "com.pooya.AutoConnect.tests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? store.deleteAll()
        store = nil
    }

    func testStartsEmpty() throws {
        XCTAssertEqual(try store.loadAccounts(), [])
    }

    func testRoundTripsAnAccountAndItsSecret() throws {
        let account = Account(issuer: "DigikalaMFA", label: "p.kamel@digikala.com")
        let secret = Data("12345678901234567890".utf8)

        try store.add(account, secret: secret)

        let loaded = try store.loadAccounts()
        XCTAssertEqual(loaded, [account])
        XCTAssertEqual(try store.secret(for: account.id), secret)
    }

    /// The whole point of storing metadata in an attribute: listing must not read secrets.
    func testNonDefaultSettingsSurviveARoundTrip() throws {
        let account = Account(
            issuer: "Example",
            label: "x@y.z",
            algorithm: .sha512,
            digits: 8,
            period: 60
        )

        try store.add(account, secret: Data("secret-bytes".utf8))

        let loaded = try XCTUnwrap(try store.loadAccounts().first)
        XCTAssertEqual(loaded.algorithm, .sha512)
        XCTAssertEqual(loaded.digits, 8)
        XCTAssertEqual(loaded.period, 60)
        XCTAssertEqual(loaded.id, account.id)
    }

    func testKeepsAccountsInInsertionOrder() throws {
        let first = Account(issuer: "First", label: "a")
        let second = Account(issuer: "Second", label: "b")
        let third = Account(issuer: "Third", label: "c")

        for account in [first, second, third] {
            try store.add(account, secret: Data("s".utf8))
        }

        XCTAssertEqual(try store.loadAccounts().map(\.issuer), ["First", "Second", "Third"])
    }

    func testRejectsDuplicateIDs() throws {
        let account = Account(issuer: "A", label: "b")
        try store.add(account, secret: Data("s".utf8))

        XCTAssertThrowsError(try store.add(account, secret: Data("s".utf8))) { error in
            guard case .duplicate = error as? KeychainStore.StoreError else {
                return XCTFail("expected duplicate, got \(error)")
            }
        }
    }

    /// Two accounts for the same issuer is the normal case, not a duplicate.
    func testAllowsTwoAccountsWithTheSameIssuer() throws {
        try store.add(
            Account(issuer: "DigikalaMFA", label: "p.kamel@digikala.com"),
            secret: Data("one".utf8)
        )
        try store.add(
            Account(issuer: "DigikalaMFA", label: "design@digikala.com"),
            secret: Data("two".utf8)
        )

        XCTAssertEqual(try store.loadAccounts().count, 2)
    }

    func testUpdatesMetadataWithoutDisturbingTheSecret() throws {
        var account = Account(issuer: "Old", label: "old@example.com")
        let secret = Data("12345678901234567890".utf8)
        try store.add(account, secret: secret)

        account.issuer = "New"
        account.label = "new@example.com"
        account.digits = 8
        try store.update(account)

        let loaded = try XCTUnwrap(try store.loadAccounts().first)
        XCTAssertEqual(loaded.issuer, "New")
        XCTAssertEqual(loaded.label, "new@example.com")
        XCTAssertEqual(loaded.digits, 8)
        XCTAssertEqual(try store.secret(for: account.id), secret)
    }

    func testUpdatesSecret() throws {
        let account = Account(issuer: "A", label: "b")
        try store.add(account, secret: Data("before".utf8))

        try store.updateSecret(for: account.id, secret: Data("after".utf8))

        XCTAssertEqual(try store.secret(for: account.id), Data("after".utf8))
    }

    func testDeleteRemovesAccountAndSecret() throws {
        let account = Account(issuer: "A", label: "b")
        try store.add(account, secret: Data("s".utf8))

        try store.delete(id: account.id)

        XCTAssertEqual(try store.loadAccounts(), [])
        XCTAssertThrowsError(try store.secret(for: account.id)) { error in
            guard case .notFound = error as? KeychainStore.StoreError else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func testDeletingATwiceIsNotAnError() throws {
        let account = Account(issuer: "A", label: "b")
        try store.add(account, secret: Data("s".utf8))

        try store.delete(id: account.id)
        XCTAssertNoThrow(try store.delete(id: account.id))
    }

    func testMissingSecretThrowsNotFound() {
        XCTAssertThrowsError(try store.secret(for: UUID())) { error in
            guard case .notFound = error as? KeychainStore.StoreError else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func testReorderPersistsNewOrder() throws {
        let first = Account(issuer: "First", label: "a")
        let second = Account(issuer: "Second", label: "b")
        try store.add(first, secret: Data("s".utf8))
        try store.add(second, secret: Data("s".utf8))

        try store.reorder([second, first])

        XCTAssertEqual(try store.loadAccounts().map(\.issuer), ["Second", "First"])
    }

    /// End to end: a scanned URI becomes a stored account whose code matches the RFC vector.
    func testScannedURIProducesTheExpectedCode() throws {
        let parsed = try OTPAuthURI.parse(
            "otpauth://totp/DigikalaMFA:p.kamel@digikala.com"
                + "?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=DigikalaMFA"
        )

        try store.add(parsed.account, secret: parsed.secret)

        let loaded = try XCTUnwrap(try store.loadAccounts().first)
        let code = TOTP.generate(
            secret: try store.secret(for: loaded.id),
            at: Date(timeIntervalSince1970: 59),
            algorithm: loaded.algorithm,
            digits: 8,
            period: loaded.period
        )

        XCTAssertEqual(code, "94287082")
    }
}
