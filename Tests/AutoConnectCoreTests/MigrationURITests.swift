import XCTest
@testable import AutoConnectCore

/// Google Authenticator's export QR codes, the `otpauth-migration://offline?data=...` form.
///
/// The fixtures below are protobuf payloads built to the schema Google ships, with the RFC 6238
/// test secret standing in for a real one so a decoded entry can be checked all the way through
/// to the code it produces. Real exports were not committed: the payload is the seed in plain
/// bytes, so a captured one is a live credential.
final class MigrationURITests: XCTestCase {

    /// Two time-based accounts, one part. GitHub/octocat on the RFC secret with SHA1 and six
    /// digits, then Example Corp/alice with SHA256 and eight.
    private let twoAccounts = "otpauth-migration://offline?data=Ci0KFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgdvY3RvY2F0GgZHaXRIdWIgASgBMAIKMwoKAQIDBAUGBwgJChIRYWxpY2VAZXhhbXBsZS5jb20aDEV4YW1wbGUgQ29ycCACKAIwAhABGAEgACiHrUs%3D"

    /// One usable account whose name repeats the issuer, plus an HOTP entry, as part 2 of 3.
    private let mixedBatch = "otpauth-migration://offline?data=CjQKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEg5HaXRIdWI6b2N0b2NhdBoGR2l0SHViIAEoATACCjsKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEhNjb3VudGVyQGV4YW1wbGUuY29tGgZMZWdhY3kgASgBMAE4BxABGAMgASiHrUs%3D"

    /// A single counter-based entry: parses, but leaves nothing this app can generate.
    private let counterOnly = "otpauth-migration://offline?data=CjsKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEhNjb3VudGVyQGV4YW1wbGUuY29tGgZMZWdhY3kgASgBMAE4BxABGAEgACiHrUs%3D"

    private let rfcSecret = Data("12345678901234567890".utf8)

    func testParsesEveryAccountInAnExport() throws {
        let batch = try OTPMigrationURI.parse(twoAccounts)

        XCTAssertEqual(batch.entries.count, 2)
        XCTAssertEqual(batch.skipped, 0)
        XCTAssertEqual(batch.batchSize, 1)
        XCTAssertEqual(batch.batchIndex, 0)
        XCTAssertFalse(batch.isPartialExport)
        // Nothing to warn about, so the accounts appearing in the list is the whole story.
        XCTAssertNil(batch.summary)

        let first = batch.entries[0]
        XCTAssertEqual(first.account.issuer, "GitHub")
        XCTAssertEqual(first.account.label, "octocat")
        XCTAssertEqual(first.account.algorithm, .sha1)
        XCTAssertEqual(first.account.digits, 6)
        XCTAssertEqual(first.account.period, 30)
        XCTAssertEqual(first.secret, rfcSecret)

        let second = batch.entries[1]
        XCTAssertEqual(second.account.issuer, "Example Corp")
        XCTAssertEqual(second.account.label, "alice@example.com")
        XCTAssertEqual(second.account.algorithm, .sha256)
        XCTAssertEqual(second.account.digits, 8)
        XCTAssertEqual(second.secret, Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
    }

    /// The point of decoding the secret is the code it makes, so check one against the RFC
    /// 6238 Appendix B vector for T=59, truncated to six digits.
    func testDecodedSecretGeneratesTheExpectedCode() throws {
        let batch = try OTPMigrationURI.parse(twoAccounts)
        let entry = batch.entries[0]

        let code = TOTP.generate(
            secret: entry.secret,
            counter: TOTP.counter(at: Date(timeIntervalSince1970: 59), period: entry.account.period),
            algorithm: entry.account.algorithm,
            digits: entry.account.digits
        )

        XCTAssertEqual(code, "287082")
    }

    func testSkipsCounterBasedEntriesInsteadOfFailingTheWholeBatch() throws {
        let batch = try OTPMigrationURI.parse(mixedBatch)

        XCTAssertEqual(batch.entries.count, 1)
        XCTAssertEqual(batch.skipped, 1)
        XCTAssertEqual(batch.entries[0].account.issuer, "GitHub")
        // "GitHub:octocat" carries the issuer twice; the row should not.
        XCTAssertEqual(batch.entries[0].account.label, "octocat")
    }

    func testPartialExportSaysWhichPartAndWhatWasLeftOut() throws {
        let batch = try OTPMigrationURI.parse(mixedBatch)

        XCTAssertTrue(batch.isPartialExport)
        XCTAssertEqual(batch.batchIndex, 1)
        XCTAssertEqual(batch.batchSize, 3)

        let summary = try XCTUnwrap(batch.summary)
        XCTAssertTrue(summary.contains("part 2 of 3"), summary)
        XCTAssertTrue(summary.contains("1 account"), summary)
        XCTAssertTrue(summary.contains("1 entry"), summary)
    }

    func testExportWithNothingUsableReportsHowManyWereSkipped() {
        XCTAssertThrowsError(try OTPMigrationURI.parse(counterOnly)) { error in
            XCTAssertEqual(
                error as? OTPMigrationURI.ParseError,
                .noUsableEntries(skipped: 1)
            )
        }
    }

    func testToleratesBase64URLAlphabetAndMissingPadding() throws {
        let mangled = twoAccounts
            .replacingOccurrences(of: "%3D", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")

        XCTAssertEqual(try OTPMigrationURI.parse(mangled).entries.count, 2)
    }

    func testRejectsOtherURIs() {
        for input in [
            "otpauth://totp/GitHub:octocat?secret=MZXW6YTB",
            "https://example.com?data=Ci0K",
            "offline?data=Ci0K",
            "",
        ] {
            XCTAssertThrowsError(try OTPMigrationURI.parse(input), input) { error in
                XCTAssertEqual(error as? OTPMigrationURI.ParseError, .notAMigrationURI, input)
            }
        }
    }

    func testRejectsMissingData() {
        XCTAssertThrowsError(try OTPMigrationURI.parse("otpauth-migration://offline")) { error in
            XCTAssertEqual(error as? OTPMigrationURI.ParseError, .missingData)
        }
    }

    func testRejectsBytesThatAreNotAnExport() {
        for input in [
            "otpauth-migration://offline?data=zzzzzzzz",
            "otpauth-migration://offline?data=EAEYASAA",  // version and batch fields, no accounts
        ] {
            XCTAssertThrowsError(try OTPMigrationURI.parse(input), input) { error in
                XCTAssertEqual(error as? OTPMigrationURI.ParseError, .malformedPayload, input)
            }
        }
    }

    func testFindsTheURIInSurroundingNoise() throws {
        let noisy = "scanned:\n\(twoAccounts) trailing words"
        let found = try XCTUnwrap(OTPMigrationURI.firstURI(in: noisy))

        XCTAssertEqual(found, twoAccounts)
        XCTAssertTrue(OTPMigrationURI.isMigrationURI(noisy))
        XCTAssertFalse(OTPMigrationURI.isMigrationURI("otpauth://totp/x?secret=MZXW6YTB"))
    }

    /// The plain `otpauth://` parser must not claim an export link, or the wrong error comes out.
    func testPlainParserDoesNotClaimAnExportLink() {
        XCTAssertNil(OTPAuthURI.firstURI(in: twoAccounts))
    }
}
