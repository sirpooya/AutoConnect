import XCTest
@testable import MacAuthCore

final class TOTPTests: XCTestCase {

    // RFC 6238 Appendix B uses a different seed length per algorithm: the ASCII string
    // "12345678901234567890" repeated/truncated to the hash's block requirement.
    private let sha1Secret = Data("12345678901234567890".utf8)
    private let sha256Secret = Data("12345678901234567890123456789012".utf8)
    private let sha512Secret = Data(
        "1234567890123456789012345678901234567890123456789012345678901234".utf8
    )

    private func secret(for algorithm: TOTP.Algorithm) -> Data {
        switch algorithm {
        case .sha1: return sha1Secret
        case .sha256: return sha256Secret
        case .sha512: return sha512Secret
        }
    }

    /// RFC 6238 Appendix B, in full. All vectors are 8 digits with a 30 second period.
    func testRFC6238AppendixBVectors() {
        let vectors: [(time: TimeInterval, algorithm: TOTP.Algorithm, expected: String)] = [
            (59, .sha1, "94287082"),
            (59, .sha256, "46119246"),
            (59, .sha512, "90693936"),

            (1_111_111_109, .sha1, "07081804"),
            (1_111_111_109, .sha256, "68084774"),
            (1_111_111_109, .sha512, "25091201"),

            (1_111_111_111, .sha1, "14050471"),
            (1_111_111_111, .sha256, "67062674"),
            (1_111_111_111, .sha512, "99943326"),

            (1_234_567_890, .sha1, "89005924"),
            (1_234_567_890, .sha256, "91819424"),
            (1_234_567_890, .sha512, "93441116"),

            (2_000_000_000, .sha1, "69279037"),
            (2_000_000_000, .sha256, "90698825"),
            (2_000_000_000, .sha512, "38618901"),

            (20_000_000_000, .sha1, "65353130"),
            (20_000_000_000, .sha256, "77737706"),
            (20_000_000_000, .sha512, "47863826"),
        ]

        for vector in vectors {
            let code = TOTP.generate(
                secret: secret(for: vector.algorithm),
                at: Date(timeIntervalSince1970: vector.time),
                algorithm: vector.algorithm,
                digits: 8,
                period: 30
            )
            XCTAssertEqual(
                code,
                vector.expected,
                "T=\(vector.time) \(vector.algorithm.rawValue) should be \(vector.expected)"
            )
        }
    }

    /// The RFC 4226 counter vectors, which the truncation logic is shared with. These are the
    /// 6-digit values every authenticator app agrees on.
    func testRFC4226CounterVectors() {
        let expected = [
            "755224", "287082", "359152", "969429", "338314",
            "254676", "287922", "162583", "399871", "520489",
        ]

        for (counter, code) in expected.enumerated() {
            XCTAssertEqual(
                TOTP.generate(secret: sha1Secret, counter: UInt64(counter), digits: 6),
                code,
                "counter \(counter)"
            )
        }
    }

    func testCounterDerivation() {
        XCTAssertEqual(TOTP.counter(at: Date(timeIntervalSince1970: 0), period: 30), 0)
        XCTAssertEqual(TOTP.counter(at: Date(timeIntervalSince1970: 29), period: 30), 0)
        XCTAssertEqual(TOTP.counter(at: Date(timeIntervalSince1970: 30), period: 30), 1)
        XCTAssertEqual(TOTP.counter(at: Date(timeIntervalSince1970: 59), period: 30), 1)
        XCTAssertEqual(TOTP.counter(at: Date(timeIntervalSince1970: 60), period: 30), 2)
        // A 60 second period halves the step count.
        XCTAssertEqual(TOTP.counter(at: Date(timeIntervalSince1970: 59), period: 60), 0)
    }

    func testSecondsRemaining() {
        XCTAssertEqual(TOTP.secondsRemaining(at: Date(timeIntervalSince1970: 0), period: 30), 30)
        XCTAssertEqual(TOTP.secondsRemaining(at: Date(timeIntervalSince1970: 1), period: 30), 29)
        XCTAssertEqual(TOTP.secondsRemaining(at: Date(timeIntervalSince1970: 29), period: 30), 1)
        XCTAssertEqual(TOTP.secondsRemaining(at: Date(timeIntervalSince1970: 30), period: 30), 30)
    }

    func testRemainingFraction() {
        XCTAssertEqual(
            TOTP.remainingFraction(at: Date(timeIntervalSince1970: 15), period: 30),
            0.5,
            accuracy: 0.0001
        )
    }

    /// A code must be zero-padded to its full width, which is the classic off-by-one bug in
    /// hand-rolled implementations.
    func testCodesAreZeroPadded() {
        // Counter 0 with this seed produces 755224 at 6 digits; at 8 it gains leading digits.
        let six = TOTP.generate(secret: sha1Secret, counter: 0, digits: 6)
        XCTAssertEqual(six.count, 6)

        let eight = TOTP.generate(secret: sha1Secret, counter: 0, digits: 8)
        XCTAssertEqual(eight.count, 8)
        XCTAssertTrue(eight.hasSuffix(six))
    }

    func testAlgorithmLooseParsing() {
        XCTAssertEqual(TOTP.Algorithm(loose: "sha1"), .sha1)
        XCTAssertEqual(TOTP.Algorithm(loose: "SHA256"), .sha256)
        XCTAssertEqual(TOTP.Algorithm(loose: " sha512 "), .sha512)
        XCTAssertNil(TOTP.Algorithm(loose: "md5"))
    }
}
