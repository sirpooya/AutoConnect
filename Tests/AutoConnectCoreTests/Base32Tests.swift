import XCTest
@testable import MacAuthCore

final class Base32Tests: XCTestCase {

    /// RFC 4648 section 10 test vectors.
    func testRFC4648Vectors() {
        let vectors = [
            ("f", "MY======"),
            ("fo", "MZXQ===="),
            ("foo", "MZXW6==="),
            ("foob", "MZXW6YQ="),
            ("fooba", "MZXW6YTB"),
            ("foobar", "MZXW6YTBOI======"),
        ]

        for (plain, encoded) in vectors {
            XCTAssertEqual(Base32.encode(Data(plain.utf8)), encoded, "encode \(plain)")
            XCTAssertEqual(
                try? Base32.decode(encoded),
                Data(plain.utf8),
                "decode \(encoded)"
            )
        }
    }

    /// The RFC 6238 seed, as every authenticator encodes it.
    func testRFC6238SeedRoundTrip() {
        let secret = Data("12345678901234567890".utf8)
        let encoded = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

        XCTAssertEqual(Base32.encode(secret), encoded)
        XCTAssertEqual(try? Base32.decode(encoded), secret)
    }

    func testDecodeToleratesLowercase() throws {
        XCTAssertEqual(try Base32.decode("mzxw6ytb"), Data("fooba".utf8))
        XCTAssertEqual(try Base32.decode("MzXw6YtB"), Data("fooba".utf8))
    }

    func testDecodeToleratesMissingPadding() throws {
        XCTAssertEqual(try Base32.decode("MZXW6"), Data("foo".utf8))
        XCTAssertEqual(try Base32.decode("MZXW6==="), Data("foo".utf8))
    }

    func testDecodeToleratesFormattingCharacters() throws {
        let expected = Data("12345678901234567890".utf8)
        XCTAssertEqual(try Base32.decode("GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ"), expected)
        XCTAssertEqual(try Base32.decode("GEZD-GNBV-GY3T-QOJQ-GEZD-GNBV-GY3T-QOJQ"), expected)
        XCTAssertEqual(try Base32.decode("GEZDGNBVGY3TQOJQ\nGEZDGNBVGY3TQOJQ"), expected)
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try Base32.decode("")) { error in
            XCTAssertEqual(error as? Base32.DecodeError, .empty)
        }
        XCTAssertThrowsError(try Base32.decode("   ")) { error in
            XCTAssertEqual(error as? Base32.DecodeError, .empty)
        }
    }

    func testInvalidCharacterThrows() {
        // 0, 1, 8 and 9 are deliberately absent from the Base32 alphabet.
        XCTAssertThrowsError(try Base32.decode("MZXW6YT0")) { error in
            XCTAssertEqual(error as? Base32.DecodeError, .invalidCharacter("0"))
        }
        XCTAssertThrowsError(try Base32.decode("MZXW6YT1")) { error in
            XCTAssertEqual(error as? Base32.DecodeError, .invalidCharacter("1"))
        }
        XCTAssertThrowsError(try Base32.decode("MZXW6YT!")) { error in
            XCTAssertEqual(error as? Base32.DecodeError, .invalidCharacter("!"))
        }
    }

    /// 1, 3 and 6 leftover characters cannot form whole bytes and mean a truncated secret.
    func testImpossibleLengthsThrow() {
        for input in ["M", "MZX", "MZXW6Y", "MZXW6YTBM"] {
            XCTAssertThrowsError(try Base32.decode(input), "\(input) should be rejected") { error in
                guard case .invalidLength = error as? Base32.DecodeError else {
                    return XCTFail("expected invalidLength for \(input), got \(error)")
                }
            }
        }
    }

    func testEncodeEmptyIsEmpty() {
        XCTAssertEqual(Base32.encode(Data()), "")
    }

    func testRandomRoundTrip() throws {
        for length in 1...64 {
            let bytes = Data((0..<length).map { _ in UInt8.random(in: .min ... .max) })
            let decoded = try Base32.decode(Base32.encode(bytes))
            XCTAssertEqual(decoded, bytes, "round trip failed at length \(length)")
        }
    }
}
