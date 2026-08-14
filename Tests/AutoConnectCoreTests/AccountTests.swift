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
