import Foundation
import Security
import XCTest

@testable import AutoConnectCore

/// The parser exists to handle the bytes a real certificate is made of, so the fixture is one:
/// a self-signed certificate generated with openssl, whose every field is known independently.
///
/// ```
/// openssl req -x509 -newkey rsa:2048 -nodes -subj \
///   "/C=IR/O=Example Services/CN=mfa-vpn.example.com" \
///   -addext "subjectAltName=DNS:mfa-vpn.example.com,DNS:*.vpn.example.com" \
///   -not_before 20260101000000Z -not_after 20360101000000Z
/// ```
///
/// It names no real gateway and its private key was thrown away.
final class PinnedCertificateTests: XCTestCase {

    // MARK: - Reading a real certificate

    func testReadsBothFingerprints() throws {
        let certificate = try fixture()
        let read = PinnedCertificate.read(certificate)

        // Cross-checked against `openssl x509 -fingerprint -sha1` and `-sha256`.
        XCTAssertEqual(read.sha1, "5EB5AB342E5D25D0B1606EE6B2585A6F87453E22")
        XCTAssertEqual(
            read.sha256,
            "347CC287E485BF5AF3FF983A1FFA87E19BE972981899"
                + "64D9BCA0CD21A98AE63E"
        )
    }

    func testReadsSubjectAndIssuer() throws {
        let read = PinnedCertificate.read(try fixture())

        XCTAssertEqual(read.commonName, "mfa-vpn.example.com")
        // Self-signed, so the issuer is the subject. That equality is what the editor turns into
        // "only the pin vouches for it".
        XCTAssertEqual(read.issuer, "mfa-vpn.example.com")
    }

    func testReadsSubjectAltNames() throws {
        let read = PinnedCertificate.read(try fixture())

        XCTAssertEqual(read.subjectAltNames, ["mfa-vpn.example.com", "*.vpn.example.com"])
    }

    /// Validity dates come back as `CFAbsoluteTime`, seconds from 2001 rather than 1970. Reading
    /// them as a Unix timestamp lands 31 years early and looks plausible, so the test pins the
    /// exact instants openssl was asked for.
    func testReadsValidityDates() throws {
        let read = PinnedCertificate.read(try fixture())

        XCTAssertEqual(read.notBefore, utc(year: 2026), "notBefore")
        XCTAssertEqual(read.notAfter, utc(year: 2036), "notAfter")
    }

    func testPinnedAtIsTheDateGiven() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(PinnedCertificate.read(try fixture(), pinnedAt: when).pinnedAt, when)
    }

    // MARK: - Expiry

    func testExpiryIsUnknownWithoutAValidityDate() {
        XCTAssertEqual(sample(notAfter: nil).expiry(), .unknown)
    }

    func testExpiryCountsWholeDaysRemaining() {
        let cert = sample(notAfter: day(100))
        XCTAssertEqual(cert.expiry(asOf: day(0)), .valid(daysLeft: 100))
    }

    func testExpiryWarnsInsideTheWindow() {
        let cert = sample(notAfter: day(30))

        XCTAssertEqual(cert.expiry(asOf: day(0)), .soon(daysLeft: 30))
        XCTAssertEqual(cert.expiry(asOf: day(-1)), .valid(daysLeft: 31), "one day outside")
    }

    /// Part of a day left still reads as a day left, not as none.
    func testExpiryRoundsPartialDaysUp() {
        let cert = sample(notAfter: day(0).addingTimeInterval(3600 * 11))
        XCTAssertEqual(cert.expiry(asOf: day(0)), .soon(daysLeft: 1))
    }

    func testExpiredReportsHowLongAgo() {
        let cert = sample(notAfter: day(-5))

        XCTAssertEqual(cert.expiry(asOf: day(0)), .expired(daysAgo: 5))
    }

    func testJustExpiredIsAtLeastOneDayAgo() {
        let cert = sample(notAfter: day(0).addingTimeInterval(-60))
        XCTAssertEqual(cert.expiry(asOf: day(0)), .expired(daysAgo: 1))
    }

    // MARK: - Host coverage

    func testCoversTheHostItNames() {
        let cert = sample(altNames: ["mfa-vpn.example.com"])

        XCTAssertTrue(cert.covers(host: "mfa-vpn.example.com"))
        XCTAssertTrue(cert.covers(host: "MFA-VPN.example.com"), "case insensitive")
        XCTAssertTrue(cert.covers(host: "mfa-vpn.example.com:28015"), "port ignored")
        XCTAssertFalse(cert.covers(host: "vpn.example.com"))
        XCTAssertFalse(cert.covers(host: ""))
    }

    func testWildcardCoversExactlyOneLabel() {
        let cert = sample(altNames: ["*.vpn.example.com"])

        XCTAssertTrue(cert.covers(host: "mfa.vpn.example.com"))
        XCTAssertFalse(cert.covers(host: "vpn.example.com"), "the bare domain is not covered")
        XCTAssertFalse(cert.covers(host: "a.b.vpn.example.com"), "one label only")
    }

    /// The common name is the fallback for certificates old enough to carry no SANs, and must
    /// not be consulted for one that does: a SAN list is the authoritative answer.
    func testCommonNameIsOnlyAFallback() {
        let withSANs = sample(commonName: "old.example.com", altNames: ["new.example.com"])
        XCTAssertFalse(withSANs.covers(host: "old.example.com"))
        XCTAssertTrue(withSANs.covers(host: "new.example.com"))

        let withoutSANs = sample(commonName: "old.example.com", altNames: [])
        XCTAssertTrue(withoutSANs.covers(host: "old.example.com"))
    }

    // MARK: - Presentation

    func testGroupedHexMatchesKeychainAccessShape() {
        XCTAssertEqual(PinnedCertificate.groupedHex("0123456789AB"), "0123 4567 89AB")
        // A trailing group shorter than the rest is kept whole, not padded.
        XCTAssertEqual(PinnedCertificate.groupedHex("0123456789"), "0123 4567 89")
        XCTAssertEqual(PinnedCertificate.groupedHex(""), "")
    }

    // MARK: - Storage

    /// Stored inside `VPNProfile`, which is decoded key by key so an older save survives. A
    /// certificate written by a newer build must round-trip through that path unchanged.
    func testSurvivesAProfileRoundTrip() throws {
        var profile = VPNProfile.example
        profile.certificateSHA1 = "5EB5AB342E5D25D0B1606EE6B2585A6F87453E22"
        profile.certificate = PinnedCertificate.read(
            try fixture(),
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(VPNProfile.self, from: data)

        XCTAssertEqual(decoded.certificate, profile.certificate)
        XCTAssertEqual(decoded.pinnedCertificate, profile.certificate)
    }

    /// A profile saved before certificates were recorded still decodes, with no details.
    func testProfileWithoutACertificateStillDecodes() throws {
        let json = """
            {"id":"\(UUID().uuidString)","host":"vpn.example.com","tunnelGroup":"G",\
            "username":"","credentialAccount":"vpn-password","passwordSource":"stored",\
            "openconnectPath":"/opt/homebrew/bin/openconnect"}
            """

        let decoded = try JSONDecoder().decode(VPNProfile.self, from: Data(json.utf8))
        XCTAssertNil(decoded.certificate)
        XCTAssertNil(decoded.pinnedCertificate)
    }

    /// Details that no longer hash to the pinned fingerprint describe a certificate this
    /// connection would refuse, so they are withheld rather than shown as current.
    func testDetailsAreWithheldWhenTheyDoNotMatchThePin() throws {
        var profile = VPNProfile.example
        profile.certificate = PinnedCertificate.read(try fixture())
        profile.certificateSHA1 = "0000000000000000000000000000000000000000"

        XCTAssertNotNil(profile.certificate)
        XCTAssertNil(profile.pinnedCertificate)
    }

    // MARK: - Helpers

    private func fixture() throws -> SecCertificate {
        let der = try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
    }

    private func sample(
        commonName: String? = "mfa-vpn.example.com",
        altNames: [String] = [],
        notAfter: Date? = nil
    ) -> PinnedCertificate {
        PinnedCertificate(
            sha1: "5EB5AB342E5D25D0B1606EE6B2585A6F87453E22",
            sha256: "347CC287E485BF5AF3FF983A1FFA87E19BE97298189964D9BCA0CD21A98AE63E",
            commonName: commonName,
            subjectAltNames: altNames,
            notAfter: notAfter
        )
    }

    /// A fixed clock, so nothing here depends on the day the suite runs.
    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000)
            .addingTimeInterval(TimeInterval(offset) * 86_400)
    }

    private func utc(year: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private static let fixtureBase64 = """
        MIIDojCCAoqgAwIBAgIUcXTI2f7A5ciya1UaU4CD1kuE+qAwDQYJKoZIhvcNAQELBQAwRjELMAkG\
        A1UEBhMCSVIxGTAXBgNVBAoMEEV4YW1wbGUgU2VydmljZXMxHDAaBgNVBAMME21mYS12cG4uZXhh\
        bXBsZS5jb20wHhcNMjYwMTAxMDAwMDAwWhcNMzYwMTAxMDAwMDAwWjBGMQswCQYDVQQGEwJJUjEZ\
        MBcGA1UECgwQRXhhbXBsZSBTZXJ2aWNlczEcMBoGA1UEAwwTbWZhLXZwbi5leGFtcGxlLmNvbTCC\
        ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALHSHvSlbFuW5y3D80BBmcf7SdVwNdDDx4cg\
        Yb1BY92diuHn4q9LX7HDKkwBmYJz0kmtEGRjkSYGAa8744Q+WF5ZwZTx4JLQABQgY61c5bhC5uuO\
        9avidqXPkg/HeMfkU23SVUMRgiUwoPMJOXbPXwl/rFksiXQU+UV6av0Ec2RcpwFGl3G0eFDCH4dj\
        1O8ejyzBUZT3YaZuscfG16FBQPiqAAqsxfgO6Ye2bpJHFnyyB5swL9JTL06ie9NC1+ZxvyPgMLay\
        Pijzoty9bqEao4KGHxXHdO+3shTSArsNM2hBpDdFMfsiyzy45hTcLnMYEq+kUvoPfJC7omo1K06C\
        sqcCAwEAAaOBhzCBhDAdBgNVHQ4EFgQUOTkjsHshUBL0Kzb90o5ivRyTQxYwHwYDVR0jBBgwFoAU\
        OTkjsHshUBL0Kzb90o5ivRyTQxYwDwYDVR0TAQH/BAUwAwEB/zAxBgNVHREEKjAoghNtZmEtdnBu\
        LmV4YW1wbGUuY29tghEqLnZwbi5leGFtcGxlLmNvbTANBgkqhkiG9w0BAQsFAAOCAQEAY7tyDZYI\
        9YJ94b47A8zBsHCw2UJxKEzqwi8DwMw+S7GOLvE4JFM3REunN/Je7KIkIe59glOrEcCRd9ncNhvj\
        MJuDAKbjgvEe+DYE0IlFz36V7P+86AP/2zUKyNHph2u1CwuvxxAapyAI4tLHYYPLOcxwxtWmbb7u\
        VrMKPJi05Gb2DJpf4E5eWyNZMnorjFBSbZA5wgZayjy56CAt4SgqrvOg22ZY7Zq0ejPM4wLkn2sA\
        9i/62oNgfzPSgjAAopXUiMo6/1ZKbn17s5+9cVpifuUtqdhYYOiz6dGXTGCSDWFVGRn4PPxThI7m\
        3oBRXGZnchLHxvzRsNqyvOGaqK4PaQ==
        """
}
