import XCTest
@testable import AutoConnectCore

/// Ranking is the part worth testing: it decides which saved website password Settings offers
/// first. The lookup itself talks to the real login Keychain, which a test must not depend on.
final class LoginKeychainTests: XCTestCase {

    private func items(_ servers: String...) -> [LoginKeychain.Item] {
        servers.map { LoginKeychain.Item(server: $0, account: "you@example.com") }
    }

    func testExactHostWins() {
        let ranked = LoginKeychain.rank(
            items("accounts.google.com", "sso.example.com", "mail.example.com"),
            preferring: "sso.example.com"
        )

        XCTAssertEqual(ranked.first?.server, "sso.example.com")
    }

    func testSameDomainBeatsAStranger() {
        let ranked = LoginKeychain.rank(
            items("accounts.google.com", "login.example.com"),
            preferring: "sso.example.com"
        )

        XCTAssertEqual(ranked.map(\.server), ["login.example.com", "accounts.google.com"])
    }

    /// A shared last label is not a shared domain: `.com` must not make two unrelated sites look
    /// like the same organisation.
    func testASharedTopLevelDomainIsNotAMatch() {
        let ranked = LoginKeychain.rank(
            items("bank.com", "sso.example.com"),
            preferring: "unrelated.org"
        )

        XCTAssertEqual(ranked.map(\.server), ["bank.com", "sso.example.com"])
    }

    func testOrderIsKeptWhenNothingIsPreferred() {
        let given = items("b.example.com", "a.example.com")

        XCTAssertEqual(LoginKeychain.rank(given, preferring: nil), given)
        XCTAssertEqual(LoginKeychain.rank(given, preferring: ""), given)
    }

    func testRankingIsStableAmongEqualMatches() {
        let ranked = LoginKeychain.rank(
            items("one.example.com", "two.example.com"),
            preferring: "sso.example.com"
        )

        XCTAssertEqual(ranked.map(\.server), ["one.example.com", "two.example.com"])
    }

    /// An empty account name would otherwise match every internet password on the machine.
    func testBlankAccountFindsNothing() {
        XCTAssertTrue(LoginKeychain.items(account: "").isEmpty)
        XCTAssertTrue(LoginKeychain.items(account: "   ").isEmpty)
    }
}
