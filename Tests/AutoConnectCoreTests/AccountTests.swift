import XCTest
@testable import AutoConnectCore

final class AccountTests: XCTestCase {

    func testParsesFullURI() throws {
        let uri = "otpauth://totp/DigikalaMFA:p.kamel@digikala.com"
            + "?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
            + "&issuer=DigikalaMFA&algorithm=SHA1&digits=6&period=30"

        let parsed = try OTPAuthURI.parse(uri)

        XCTAssertEqual(parsed.account.issuer, "DigikalaMFA")
        XCTAssertEqual(parsed.account.label, "p.kamel@digikala.com")
        XCTAssertEqual(parsed.account.algorithm, .sha1)
        XCTAssertEqual(parsed.account.digits, 6)
        XCTAssertEqual(parsed.account.period, 30)
        XCTAssertEqual(parsed.secret, Data("12345678901234567890".utf8))
    }

    func testAppliesDefaultsWhenParametersAreAbsent() throws {
        let parsed = try OTPAuthURI.parse("otpauth://totp/alice@example.com?secret=MZXW6YTB")

        XCTAssertEqual(parsed.account.issuer, "")
        XCTAssertEqual(parsed.account.label, "alice@example.com")
        XCTAssertEqual(parsed.account.algorithm, .sha1)
        XCTAssertEqual(parsed.account.digits, 6)
        XCTAssertEqual(parsed.account.period, 30)
    }

    func testIssuerPrefixInPathIsUsedWhenQueryParameterIsAbsent() throws {
        let parsed = try OTPAuthURI.parse("otpauth://totp/GitHub:octocat?secret=MZXW6YTB")

        XCTAssertEqual(parsed.account.issuer, "GitHub")
        XCTAssertEqual(parsed.account.label, "octocat")
    }

    /// The Key URI spec says the issuer query parameter wins over the path prefix.
    func testIssuerQueryParameterWinsOverPathPrefix() throws {
        let parsed = try OTPAuthURI.parse(
            "otpauth://totp/Stale:octocat?secret=MZXW6YTB&issuer=Fresh"
        )

        XCTAssertEqual(parsed.account.issuer, "Fresh")
        XCTAssertEqual(parsed.account.label, "octocat")
    }

    func testPercentEncodedLabelIsDecoded() throws {
        let parsed = try OTPAuthURI.parse(
            "otpauth://totp/ACME%20Co:john%40example.com?secret=MZXW6YTB"
        )

        XCTAssertEqual(parsed.account.issuer, "ACME Co")
        XCTAssertEqual(parsed.account.label, "john@example.com")
    }

    func testHonorsNonDefaultParameters() throws {
        let parsed = try OTPAuthURI.parse(
            "otpauth://totp/x?secret=MZXW6YTB&algorithm=sha512&digits=8&period=60"
        )

        XCTAssertEqual(parsed.account.algorithm, .sha512)
        XCTAssertEqual(parsed.account.digits, 8)
        XCTAssertEqual(parsed.account.period, 60)
        XCTAssertTrue(parsed.account.usesNonDefaultSettings)
    }

    func testClampsAbsurdDigitsAndPeriod() throws {
        let parsed = try OTPAuthURI.parse(
            "otpauth://totp/x?secret=MZXW6YTB&digits=99&period=0"
        )

        XCTAssertEqual(parsed.account.digits, 8)
        XCTAssertEqual(parsed.account.period, 30)
    }

    func testRejectsNonOTPAuthURI() {
        for input in ["https://example.com", "totp://x?secret=MZXW6YTB", "nonsense"] {
            XCTAssertThrowsError(try OTPAuthURI.parse(input), input) { error in
                XCTAssertEqual(error as? OTPAuthURI.ParseError, .notAnOTPAuthURI)
            }
        }
    }

    func testRejectsHOTPWithASpecificError() {
        XCTAssertThrowsError(
            try OTPAuthURI.parse("otpauth://hotp/x?secret=MZXW6YTB&counter=1")
        ) { error in
            XCTAssertEqual(error as? OTPAuthURI.ParseError, .counterBasedNotSupported)
        }
    }

    func testRejectsMissingSecret() {
        XCTAssertThrowsError(try OTPAuthURI.parse("otpauth://totp/x?issuer=y")) { error in
            XCTAssertEqual(error as? OTPAuthURI.ParseError, .missingSecret)
        }
    }

    func testRejectsUndecodableSecret() {
        XCTAssertThrowsError(try OTPAuthURI.parse("otpauth://totp/x?secret=0110")) { error in
            guard case .badSecret = error as? OTPAuthURI.ParseError else {
                return XCTFail("expected badSecret, got \(error)")
            }
        }
    }

    func testFindsURIInSurroundingText() {
        let found = OTPAuthURI.firstURI(
            in: "scanned: otpauth://totp/x?secret=MZXW6YTB trailing words"
        )
        XCTAssertEqual(found, "otpauth://totp/x?secret=MZXW6YTB")

        XCTAssertNil(OTPAuthURI.firstURI(in: "https://example.com"))
    }

    /// Reported from a real enrollment QR code: the page escaped the whole query string, so
    /// every separator arrived as `%26` / `%3D` and the issuer read
    /// "DigikalaMFA&algorithm=SHA1&digits=6&period=30" in the panel, Settings and details.
    func testRepairsPercentEncodedSeparators() throws {
        let parsed = try OTPAuthURI.parse(
            "otpauth://totp/p.kamel@digikala.com?secret=MZXW6YTB"
                + "&issuer=DigikalaMFA%26algorithm%3DSHA1%26digits%3D6%26period%3D30"
        )

        XCTAssertEqual(parsed.account.issuer, "DigikalaMFA")
        XCTAssertEqual(parsed.account.label, "p.kamel@digikala.com")
        XCTAssertEqual(parsed.account.algorithm, .sha1)
        XCTAssertEqual(parsed.account.digits, 6)
        XCTAssertEqual(parsed.account.period, 30)
    }

    /// The worse version of the same fault: the secret is what swallowed the tail, so the
    /// account could not be added at all rather than merely being named wrongly.
    func testRepairsASecretThatSwallowedTheQuery() throws {
        let parsed = try OTPAuthURI.parse(
            "otpauth://totp/alice@example.com"
                + "?secret=MZXW6YTB%26issuer%3DExample%26digits%3D8%26period%3D60"
        )

        XCTAssertEqual(parsed.account.issuer, "Example")
        XCTAssertEqual(parsed.account.digits, 8)
        XCTAssertEqual(parsed.account.period, 60)
        XCTAssertEqual(parsed.secret, Data("fooba".utf8))
    }

    /// A parameter that was written properly is the one the gateway meant, so it is never
    /// replaced by one recovered from inside another value.
    func testProperParameterWinsOverARecoveredOne() throws {
        let parsed = try OTPAuthURI.parse(
            "otpauth://totp/alice@example.com?secret=MZXW6YTB"
                + "&issuer=Example%26digits%3D8&digits=7"
        )

        XCTAssertEqual(parsed.account.issuer, "Example")
        XCTAssertEqual(parsed.account.digits, 7)
    }

    /// An issuer really can contain an ampersand, and nothing after it parses as a parameter
    /// of this scheme, so the name is left exactly as it was written.
    func testLeavesAGenuineAmpersandAlone() throws {
        let parsed = try OTPAuthURI.parse(
            "otpauth://totp/alice@example.com?secret=MZXW6YTB&issuer=Tom%20%26%20Jerry"
        )

        XCTAssertEqual(parsed.account.issuer, "Tom & Jerry")
    }

    func testDisplayStrings() {
        let withIssuer = Account(issuer: "DigikalaMFA", label: "p.kamel@digikala.com")
        XCTAssertEqual(withIssuer.displayTitle, "DigikalaMFA")
        XCTAssertEqual(withIssuer.displaySubtitle, "p.kamel@digikala.com")

        let withoutIssuer = Account(issuer: "", label: "alice@example.com")
        XCTAssertEqual(withoutIssuer.displayTitle, "alice@example.com")
        XCTAssertEqual(withoutIssuer.displaySubtitle, "")
    }

    func testDefaultSettingsAreNotFlagged() {
        XCTAssertFalse(Account(issuer: "a", label: "b").usesNonDefaultSettings)
    }
}
