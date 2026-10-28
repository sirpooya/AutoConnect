import Foundation
import Security
import XCTest

@testable import AutoConnectCore

/// A gateway renewing its certificate used to stop every connect until the pin was forgotten
/// and detected again by hand. A renewal a public authority vouches for is now re-pinned; nothing
/// else is.
final class PinRenewalTests: XCTestCase {

    private let pinned = "0123456789ABCDEF0123456789ABCDEF01234567"
    private let other = "FEDCBA9876543210FEDCBA9876543210FEDCBA98"

    func testMatchingPinIsAccepted() {
        XCTAssertEqual(
            GatewayClient.decide(presented: pinned, pinned: pinned, policy: .pinned, publiclyTrusted: false),
            .accept
        )
    }

    func testMismatchVouchedForPubliclyIsARenewal() {
        XCTAssertEqual(
            GatewayClient.decide(presented: other, pinned: pinned, policy: .pinned, publiclyTrusted: true),
            .acceptRenewal
        )
    }

    func testMismatchNobodyVouchesForIsRefused() {
        XCTAssertEqual(
            GatewayClient.decide(presented: other, pinned: pinned, policy: .pinned, publiclyTrusted: false),
            .reject
        )
    }

    func testPublicTrustIsOnlyAskedOnAMismatch() {
        var asked = false
        func trusted() -> Bool { asked = true; return true }
        _ = GatewayClient.decide(presented: pinned, pinned: pinned, policy: .pinned, publiclyTrusted: trusted())
        XCTAssertFalse(asked)
    }

    func testLearningAcceptsAnything() {
        XCTAssertEqual(
            GatewayClient.decide(presented: other, pinned: nil, policy: .learnFingerprint, publiclyTrusted: false),
            .accept
        )
    }

    func testNoPinFallsBackToSystemTrust() {
        XCTAssertEqual(
            GatewayClient.decide(presented: other, pinned: nil, policy: .pinned, publiclyTrusted: true),
            .systemTrust
        )
    }

    /// The self-signed fixture from `PinnedCertificateTests`, under the very name it was issued
    /// for: still not publicly trusted, so a gateway like it can never be re-pinned silently.
    func testSelfSignedCertificateIsNotPubliclyTrusted() throws {
        let der = try XCTUnwrap(Data(base64Encoded: PinnedCertificateTests.fixtureBase64))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        XCTAssertFalse(GatewayClient.isPubliclyTrusted([certificate], host: "mfa-vpn.example.com"))
    }

    func testEmptyChainIsNotPubliclyTrusted() {
        XCTAssertFalse(GatewayClient.isPubliclyTrusted([], host: "mfa-vpn.example.com"))
    }

    func testRefusalNoLongerReadsAsUnreachable() {
        let error = GatewayClient.ClientError.certificateRejected(expected: pinned, actual: other)
        XCTAssertFalse(error.description.contains("Could not reach"))
        XCTAssertTrue(error.description.contains(other))
        XCTAssertTrue(error.description.contains("Forget"))
    }

    func testRenewalBannerNamesIssuer() {
        let text = StatusNotificationPolicy.certificateRenewed(
            gateway: "mfa-vpn.example.com",
            issuer: "Certum DV TLS G2 R39 CA",
            expires: Date(timeIntervalSince1970: 1_810_000_000)
        )
        XCTAssertEqual(text.title, "VPN certificate renewed")
        XCTAssertTrue(text.body.contains("mfa-vpn.example.com"))
        XCTAssertTrue(text.body.contains("Certum DV TLS G2 R39 CA"))
    }
}
