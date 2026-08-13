import XCTest
@testable import MacAuthCore

/// Fixtures are real responses captured from the gateway on 2026-08-13, with the session token
/// replaced by a placeholder. Keeping them verbatim is the point: this suite is what proves the
/// parser handles the actual bytes Cisco sends, not an idealised version of them.
final class ConfigAuthXMLTests: XCTestCase {

    // MARK: - Fixtures

    /// Response to `type="init"` with `<group-select>MFA-VPN</group-select>`.
    private let samlAuthRequest = """
    <?xml version="1.0" encoding="UTF-8"?>
    <config-auth client="vpn" type="auth-request" aggregate-auth-version="2">
    <opaque is-for="sg">
    <tunnel-group>MFA-VPN_Profile</tunnel-group>
    <auth-method>single-sign-on-v2</auth-method>
    <group-alias>MFA-VPN</group-alias>
    <config-hash>1780275125589</config-hash>
    </opaque>
    <auth id="main">
    <title>Login</title>
    <message>Please complete the authentication process in the AnyConnect Login window.</message>
    <banner></banner>
    <sso-v2-login>https://mfa-vpn.dkservices.ir:28015/+CSCOE+/saml/sp/login?tgname=MFA-VPN_Profile&#x26;acsamlcap=v2</sso-v2-login>
    <sso-v2-login-final>https://mfa-vpn.dkservices.ir:28015/+CSCOE+/saml_ac_login.html</sso-v2-login-final>
    <sso-v2-logout>https://mfa-vpn.dkservices.ir:28015/+CSCOE+/saml/sp/logout</sso-v2-logout>
    <sso-v2-logout-final>https://mfa-vpn.dkservices.ir:28015/+CSCOE+/saml_ac_login.html</sso-v2-logout-final>
    <sso-v2-token-cookie-name>acSamlv2Token</sso-v2-token-cookie-name>
    <sso-v2-error-cookie-name>acSamlv2Error</sso-v2-error-cookie-name>
    <form>
    <input type="sso" name="sso-token"></input>
    <select name="group_list" label="GROUP:">
    <option>HQ-VPN</option>
    <option selected="true">MFA-VPN</option>
    </select>
    </form>
    </auth>
    </config-auth>
    """

    /// Response to `type="init"` with the default group, which uses password auth rather than
    /// SAML. The parser must not mistake this for a SAML challenge.
    private let passwordAuthRequest = """
    <?xml version="1.0" encoding="UTF-8"?>
    <config-auth client="vpn" type="auth-request" aggregate-auth-version="2">
    <opaque is-for="sg">
    <tunnel-group>HQ-VPN</tunnel-group>
    <group-alias>HQ-VPN</group-alias>
    <config-hash>1780275125589</config-hash>
    </opaque>
    <auth id="main">
    <title>Login</title>
    <message>Please enter your username and password.</message>
    <banner></banner>
    <form>
    <input type="text" name="username" label="Username:"></input>
    <input type="password" name="password" label="Password:"></input>
    <input type="password" name="secondary_password" label="Password:"></input>
    <select name="group_list" label="GROUP:">
    <option selected="true">HQ-VPN</option>
    <option>MFA-VPN</option>
    </select>
    </form>
    </auth>
    </config-auth>
    """

    /// Shape of the `type="complete"` response, with a placeholder token.
    private let authComplete = """
    <?xml version="1.0" encoding="UTF-8"?>
    <config-auth client="vpn" type="complete" aggregate-auth-version="2">
    <session-token>PLACEHOLDER-SESSION-TOKEN</session-token>
    <session-id>1</session-id>
    <auth id="success">
    <message></message>
    </auth>
    <config>
    <vpn-base-config>
    <server-cert-hash>AA46A448019A03FFDAF8803558C9B19CE77B951B</server-cert-hash>
    </vpn-base-config>
    </config>
    </config-auth>
    """

    // MARK: - auth-request

    func testParsesSAMLAuthRequest() throws {
        guard case .authRequest(let request) = try ConfigAuth.parse(Data(samlAuthRequest.utf8))
        else {
            return XCTFail("expected an auth-request")
        }

        XCTAssertEqual(request.authID, "main")
        XCTAssertEqual(request.title, "Login")
        XCTAssertEqual(request.error, "")
        XCTAssertEqual(request.tokenCookieName, "acSamlv2Token")
        XCTAssertEqual(request.errorCookieName, "acSamlv2Error")
        XCTAssertEqual(request.tunnelGroup, "MFA-VPN_Profile")
        XCTAssertEqual(
            request.loginFinalURL.absoluteString,
            "https://mfa-vpn.dkservices.ir:28015/+CSCOE+/saml_ac_login.html"
        )
    }

    /// The login URL arrives with `&` escaped as `&#x26;`. If that is not decoded, the query
    /// loses `acsamlcap=v2` and the IdP redirect misbehaves.
    func testDecodesEscapedAmpersandInLoginURL() throws {
        guard case .authRequest(let request) = try ConfigAuth.parse(Data(samlAuthRequest.utf8))
        else {
            return XCTFail("expected an auth-request")
        }

        XCTAssertEqual(
            request.loginURL.absoluteString,
            "https://mfa-vpn.dkservices.ir:28015/+CSCOE+/saml/sp/login"
                + "?tgname=MFA-VPN_Profile&acsamlcap=v2"
        )
        XCTAssertFalse(request.loginURL.absoluteString.contains("&#x26;"))
    }

    /// The opaque block is gateway state echoed back verbatim, so its contents must survive
    /// parsing intact.
    func testCapturesOpaqueBlockVerbatim() throws {
        guard case .authRequest(let request) = try ConfigAuth.parse(Data(samlAuthRequest.utf8))
        else {
            return XCTFail("expected an auth-request")
        }

        XCTAssertTrue(request.opaqueXML.hasPrefix("<opaque"))
        XCTAssertTrue(request.opaqueXML.hasSuffix("</opaque>"))
        XCTAssertTrue(request.opaqueXML.contains("<tunnel-group>MFA-VPN_Profile</tunnel-group>"))
        XCTAssertTrue(request.opaqueXML.contains("<config-hash>1780275125589</config-hash>"))
        XCTAssertTrue(request.opaqueXML.contains("is-for=\"sg\""))
    }

    /// A password tunnel group has no sso-v2-login, which must be a clear error rather than a
    /// crash or a bogus URL.
    func testPasswordAuthRequestIsRejectedAsNonSAML() {
        XCTAssertThrowsError(try ConfigAuth.parse(Data(passwordAuthRequest.utf8))) { error in
            XCTAssertEqual(
                error as? ConfigAuth.ParseError,
                .missingElement("sso-v2-login")
            )
        }
    }

    /// A rejection carries an error message and no login URL. Surface the gateway's reason.
    func testGatewayErrorIsSurfaced() {
        let rejected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config-auth client="vpn" type="auth-request" aggregate-auth-version="2">
        <opaque is-for="sg"><tunnel-group>MFA-VPN_Profile</tunnel-group></opaque>
        <auth id="main">
        <error id="88" param1="" param2="">Login failed.</error>
        <message>Please complete the authentication process.</message>
        </auth>
        </config-auth>
        """

        XCTAssertThrowsError(try ConfigAuth.parse(Data(rejected.utf8))) { error in
            XCTAssertEqual(error as? ConfigAuth.ParseError, .gatewayError("Login failed."))
        }
    }

    // MARK: - complete

    func testParsesAuthComplete() throws {
        guard case .complete(let complete) = try ConfigAuth.parse(Data(authComplete.utf8)) else {
            return XCTFail("expected a complete response")
        }

        XCTAssertEqual(complete.authID, "success")
        XCTAssertEqual(complete.sessionToken, "PLACEHOLDER-SESSION-TOKEN")
        XCTAssertEqual(complete.serverCertHash, "AA46A448019A03FFDAF8803558C9B19CE77B951B")
    }

    func testCompleteWithoutSessionTokenIsRejected() {
        let missing = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config-auth client="vpn" type="complete" aggregate-auth-version="2">
        <session-token></session-token>
        <auth id="success"><message></message></auth>
        <config><vpn-base-config><server-cert-hash>ABC</server-cert-hash></vpn-base-config></config>
        </config-auth>
        """

        XCTAssertThrowsError(try ConfigAuth.parse(Data(missing.utf8))) { error in
            XCTAssertEqual(error as? ConfigAuth.ParseError, .missingElement("session-token"))
        }
    }

    func testCompleteWithoutCertHashIsRejected() {
        let missing = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config-auth client="vpn" type="complete" aggregate-auth-version="2">
        <session-token>T</session-token>
        <auth id="success"><message></message></auth>
        </config-auth>
        """

        XCTAssertThrowsError(try ConfigAuth.parse(Data(missing.utf8))) { error in
            XCTAssertEqual(error as? ConfigAuth.ParseError, .missingElement("server-cert-hash"))
        }
    }

    // MARK: - Malformed input

    func testNonXMLIsRejected() {
        XCTAssertThrowsError(try ConfigAuth.parse(Data("<html>nope".utf8))) { error in
            XCTAssertEqual(error as? ConfigAuth.ParseError, .notXML)
        }
    }

    func testUnknownTypeIsRejected() {
        let unknown = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config-auth client="vpn" type="something-else" aggregate-auth-version="2"/>
        """

        XCTAssertThrowsError(try ConfigAuth.parse(Data(unknown.utf8))) { error in
            XCTAssertEqual(error as? ConfigAuth.ParseError, .unexpectedType("something-else"))
        }
    }

    // MARK: - Request building

    func testInitRequestNamesTheTunnelGroupAndAdvertisesSAML() throws {
        let xml = ConfigAuth.initRequest(
            groupSelect: "MFA-VPN",
            groupAccess: "https://mfa-vpn.dkservices.ir:28015"
        )

        XCTAssertTrue(xml.contains("type=\"init\""))
        XCTAssertTrue(xml.contains("<group-select>MFA-VPN</group-select>"))
        XCTAssertTrue(xml.contains("<auth-method>single-sign-on-v2</auth-method>"))
        XCTAssertTrue(
            xml.contains("<group-access>https://mfa-vpn.dkservices.ir:28015</group-access>")
        )
        // Must be well formed, since the gateway is strict.
        XCTAssertNoThrow(try XMLDocument(data: Data(xml.utf8)))
    }

    func testAuthReplyEchoesOpaqueAndCarriesTheToken() throws {
        guard case .authRequest(let request) = try ConfigAuth.parse(Data(samlAuthRequest.utf8))
        else {
            return XCTFail("expected an auth-request")
        }

        let xml = ConfigAuth.authReplyRequest(
            opaqueXML: request.opaqueXML,
            ssoToken: "TOKEN-VALUE"
        )

        XCTAssertTrue(xml.contains("type=\"auth-reply\""))
        XCTAssertTrue(xml.contains("<sso-token>TOKEN-VALUE</sso-token>"))
        XCTAssertTrue(xml.contains("<tunnel-group>MFA-VPN_Profile</tunnel-group>"))
        XCTAssertTrue(xml.contains("<session-token/>"))

        let document = try XMLDocument(data: Data(xml.utf8))
        let opaque = document.rootElement()?.firstChild(named: "opaque")
        XCTAssertEqual(opaque?.childText("config-hash"), "1780275125589")
    }

    /// A token containing XML-significant characters must not break the document.
    func testTokenIsEscaped() throws {
        let xml = ConfigAuth.authReplyRequest(
            opaqueXML: "<opaque is-for=\"sg\"><tunnel-group>g</tunnel-group></opaque>",
            ssoToken: "a&b<c>\"d\""
        )

        let document = try XMLDocument(data: Data(xml.utf8))
        let token = document.rootElement()?
            .firstChild(named: "auth")?
            .childText("sso-token")
        XCTAssertEqual(token, "a&b<c>\"d\"")
    }

    func testHeadersImpersonateAnyConnect() {
        let headers = ConfigAuth.headers()

        XCTAssertEqual(headers["User-Agent"], "AnyConnect Linux_64 4.7.00136")
        XCTAssertEqual(headers["X-Aggregate-Auth"], "1")
        XCTAssertEqual(headers["X-Transcend-Version"], "1")
        XCTAssertEqual(headers["Accept-Encoding"], "identity")
    }

    // MARK: - Profile

    func testProfileDerivesGatewayURLs() {
        let profile = VPNProfile.digikalaMFA

        XCTAssertEqual(profile.gatewayURL?.absoluteString, "https://mfa-vpn.dkservices.ir:28015/")
        XCTAssertEqual(profile.groupAccess, "https://mfa-vpn.dkservices.ir:28015")
        XCTAssertEqual(profile.tunnelGroup, "MFA-VPN")
    }

    func testProfileNormalizesFingerprint() {
        var profile = VPNProfile.digikalaMFA
        profile.certificateSHA1 = "aa:46:a4:48:01:9a:03:ff:da:f8:80:35:58:c9:b1:9c:e7:7b:95:1b"

        XCTAssertEqual(
            profile.normalizedCertificateSHA1,
            "AA46A448019A03FFDAF8803558C9B19CE77B951B"
        )
    }
}
