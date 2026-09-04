import XCTest
@testable import AutoConnectCore

/// The rule these cover is "a secret goes to the gateway or to the identity provider, and
/// nowhere else". The case that matters most is the last one: a flow that reaches a third,
/// unrelated host must be refused however it got there.
final class LoginOriginPolicyTests: XCTestCase {

    private let gateway = "mfa-vpn.example.com"

    // MARK: - The gateway anchor

    func testGatewayIsTrustedBeforeAnythingIsObserved() {
        let policy = LoginOriginPolicy(gatewayHost: gateway)
        XCTAssertTrue(policy.allows(host: gateway))
    }

    func testGatewaySubdomainsAreTrusted() {
        let policy = LoginOriginPolicy(gatewayHost: gateway)
        XCTAssertTrue(policy.allows(host: "sso.example.com"))
    }

    func testHostComparisonIgnoresCase() {
        let policy = LoginOriginPolicy(gatewayHost: gateway)
        XCTAssertTrue(policy.allows(host: "MFA-VPN.EXAMPLE.COM"))
    }

    func testUnrelatedHostIsRefusedWithNoIdPLearned() {
        let policy = LoginOriginPolicy(gatewayHost: gateway)
        XCTAssertFalse(policy.allows(host: "evil.test"))
    }

    // MARK: - Learning the identity provider

    func testFirstHostOutsideTheGatewayBecomesTheIdentityProvider() {
        var policy = LoginOriginPolicy(gatewayHost: gateway)
        policy.observe(host: "login.idp.test")

        XCTAssertEqual(policy.identityProviderHost, "login.idp.test")
        XCTAssertTrue(policy.allows(host: "login.idp.test"))
        // And the gateway is still trusted; learning an IdP does not replace the first anchor.
        XCTAssertTrue(policy.allows(host: gateway))
    }

    func testIdentityProviderSubdomainsAreTrusted() {
        var policy = LoginOriginPolicy(gatewayHost: gateway)
        policy.observe(host: "login.idp.test")

        XCTAssertTrue(policy.allows(host: "auth.idp.test"))
    }

    func testHostsInsideTheGatewayDomainDoNotConsumeTheIdPSlot() {
        var policy = LoginOriginPolicy(gatewayHost: gateway)
        // A redirect within the gateway's own domain is not the hand-off to an IdP.
        policy.observe(host: "sso.example.com")
        XCTAssertNil(policy.identityProviderHost)

        policy.observe(host: "login.idp.test")
        XCTAssertEqual(policy.identityProviderHost, "login.idp.test")
    }

    // MARK: - The refusal this exists for

    func testASecondUnrelatedHostIsRefused() {
        var policy = LoginOriginPolicy(gatewayHost: gateway)
        policy.observe(host: "login.idp.test")

        // An open redirect at the identity provider, or a compromised page in the chain. The
        // old set-of-every-host-seen accepted this; the whole point is that it must not.
        policy.observe(host: "evil.test")

        XCTAssertEqual(policy.identityProviderHost, "login.idp.test")
        XCTAssertFalse(policy.allows(host: "evil.test"))
    }

    func testObservingAnUnrelatedHostDoesNotUnseatTheIdentityProvider() {
        var policy = LoginOriginPolicy(gatewayHost: gateway)
        policy.observe(host: "login.idp.test")
        policy.observe(host: "evil.test")
        policy.observe(host: "evil.test")

        XCTAssertTrue(policy.allows(host: "login.idp.test"))
        XCTAssertFalse(policy.allows(host: "evil.test"))
    }

    func testALookalikeSuffixIsNotAMatch() {
        let policy = LoginOriginPolicy(gatewayHost: gateway)
        // Sharing one trailing label is not sharing a domain.
        XCTAssertFalse(policy.allows(host: "example.com.evil.com"))
        XCTAssertFalse(policy.allows(host: "notexample.com"))
    }

    // MARK: - Degenerate input

    func testNilAndEmptyHostsAreNeverTrusted() {
        var policy = LoginOriginPolicy(gatewayHost: gateway)
        XCTAssertFalse(policy.allows(host: nil))
        XCTAssertFalse(policy.allows(host: ""))
        XCTAssertFalse(policy.allows(host: "   "))

        policy.observe(host: nil)
        policy.observe(host: "")
        XCTAssertNil(policy.identityProviderHost)
    }

    func testWithNoGatewayNothingIsTrustedUntilAnIdPIsLearned() {
        var policy = LoginOriginPolicy(gatewayHost: nil)
        XCTAssertFalse(policy.allows(host: "anything.test"))

        policy.observe(host: "login.idp.test")
        XCTAssertTrue(policy.allows(host: "login.idp.test"))
        XCTAssertFalse(policy.allows(host: "evil.test"))
    }

    func testAnchorsListsWhatASecretMayReach() {
        var policy = LoginOriginPolicy(gatewayHost: gateway)
        XCTAssertEqual(policy.anchors, [gateway])

        policy.observe(host: "login.idp.test")
        XCTAssertEqual(policy.anchors, [gateway, "login.idp.test"])
    }
}
