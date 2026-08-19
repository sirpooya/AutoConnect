import XCTest
@testable import AutoConnectCore

final class OpenConnectVersionTests: XCTestCase {

    /// What Homebrew's build prints, banner line and all.
    func testReadsVersionFromRealBanner() {
        let output = """
            OpenConnect version v9.12
            Using GnuTLS 3.8.4. Features present: TPMv2, PKCS#11, RSA software token, HOTP \
            software token, TOTP software token, Yubikey OATH, System keys, DTLS, ESP
            Supported protocols: anyconnect (default), nc, gp, pulse, f5, fortinet, array
            """
        XCTAssertEqual(OpenConnectVersion.parse(output), "9.12")
    }

    /// A distribution build's suffix is part of what is installed, so it is kept.
    func testKeepsBuildSuffix() {
        XCTAssertEqual(
            OpenConnectVersion.parse("OpenConnect version v8.20-unknown"),
            "8.20-unknown"
        )
    }

    func testHandlesMissingVLetter() {
        XCTAssertEqual(OpenConnectVersion.parse("OpenConnect version 9.01"), "9.01")
    }

    func testTrimsTrailingPunctuation() {
        XCTAssertEqual(OpenConnectVersion.parse("OpenConnect version v9.12."), "9.12")
    }

    func testReturnsNilWhenNothingLooksLikeAVersion() {
        XCTAssertNil(OpenConnectVersion.parse(""))
        XCTAssertNil(OpenConnectVersion.parse("command not found: openconnect"))
        XCTAssertNil(OpenConnectVersion.parse("OpenConnect version "))
    }

    /// A path with nothing at it must not be treated as an install.
    func testReadReturnsNilForMissingBinary() {
        XCTAssertNil(OpenConnectVersion.read(at: "/nowhere/openconnect"))
    }
}
