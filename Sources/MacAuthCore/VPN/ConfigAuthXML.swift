import Foundation

/// Cisco's `config-auth` protocol: the XML handshake an AnyConnect client performs with the
/// gateway before a tunnel exists.
///
/// The exchange for a SAML tunnel group is:
///
/// 1. POST `type="init"` naming the tunnel group. The gateway replies `type="auth-request"`
///    with the IdP login URL and the name of the cookie that will carry the token.
/// 2. The client logs in at that URL in a browser and collects the token cookie.
/// 3. POST `type="auth-reply"` with the token. The gateway replies `type="complete"` with a
///    session token and the fingerprint of its own certificate.
/// 4. The session token becomes openconnect's `--cookie`.
///
/// Everything here is pure string and XML work so it can be tested against captured responses
/// without touching the network.
public enum ConfigAuth {

    /// The AnyConnect version the client claims to be. Gateways can and do reject clients they
    /// do not recognise, so this is deliberately a real shipped version.
    public static let defaultClientVersion = "4.7.00136"

    /// Header set AnyConnect itself sends. The `Content-Type` is wrong for an XML body, but it
    /// is what the real client sends and some gateways are strict about matching it.
    public static func headers(clientVersion: String = defaultClientVersion) -> [String: String] {
        [
            "User-Agent": "AnyConnect Linux_64 \(clientVersion)",
            "Accept": "*/*",
            "Accept-Encoding": "identity",
            "X-Transcend-Version": "1",
            "X-Aggregate-Auth": "1",
            "X-Support-HTTP-Auth": "true",
            "Content-Type": "application/x-www-form-urlencoded",
        ]
    }

    // MARK: - Responses

    /// Gateway response to the init POST: where to log in, and what to bring back.
    public struct AuthRequest: Equatable {
        public let authID: String
        public let title: String
        public let message: String
        /// Non-empty when the gateway is reporting a failed or rejected attempt.
        public let error: String
        public let loginURL: URL
        /// Reaching this URL in the browser means the token cookie has been set.
        public let loginFinalURL: URL
        public let tokenCookieName: String
        public let errorCookieName: String?
        /// The `<opaque>` block, captured verbatim. It is gateway state and must be echoed back
        /// byte for byte in the auth-reply, so it is never reserialised from parsed values.
        public let opaqueXML: String
        public let tunnelGroup: String?
    }

    /// Gateway response to the auth-reply POST: the credentials the tunnel needs.
    public struct AuthComplete: Equatable {
        public let authID: String
        public let message: String
        /// Becomes openconnect's `--cookie`.
        public let sessionToken: String
        /// Becomes openconnect's `--servercert`.
        public let serverCertHash: String
    }

    public enum Response: Equatable {
        case authRequest(AuthRequest)
        case complete(AuthComplete)
    }

    /// One entry of the gateway's GROUP dropdown.
    public struct TunnelGroupOption: Equatable, Hashable, Identifiable, Sendable {
        /// The alias to send back as `group-select`.
        public let value: String
        /// What the gateway calls it on its login page. Usually the same as `value`.
        public let label: String
        /// The gateway's own preselection.
        public let isDefault: Bool

        public var id: String { value }

        public init(value: String, label: String, isDefault: Bool = false) {
            self.value = value
            self.label = label
            self.isDefault = isDefault
        }
    }

    /// What a first, group-less init POST tells us about a gateway: which tunnel groups it
    /// offers, and which one it would pick itself. This is how the app fills in the group
    /// instead of having it typed in or, worse, compiled in.
    public struct GatewayProbe: Equatable, Sendable {
        public let groups: [TunnelGroupOption]
        /// The gateway's preselected group, or the only one it named.
        public var defaultGroup: String? {
            groups.first(where: \.isDefault)?.value ?? groups.first?.value
        }

        public init(groups: [TunnelGroupOption]) {
            self.groups = groups
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notXML
        case missingType(String)
        case unexpectedType(String)
        case missingElement(String)
        case malformedURL(String)
        /// The gateway rejected the attempt and said why.
        case gatewayError(String)

        public var description: String {
            switch self {
            case .notXML:
                return "The gateway did not return XML."
            case .missingType(let detail):
                return "The gateway response has no recognisable type. \(detail)"
            case .unexpectedType(let type):
                return "The gateway returned an unexpected response type '\(type)'."
            case .missingElement(let name):
                return "The gateway response is missing <\(name)>."
            case .malformedURL(let value):
                return "The gateway sent an unusable URL: \(value)"
            case .gatewayError(let message):
                return "The gateway refused the login: \(message)"
            }
        }
    }

    // MARK: - Parsing

    public static func parse(_ data: Data) throws -> Response {
        guard let document = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]),
              let root = document.rootElement()
        else {
            throw ParseError.notXML
        }

        guard let type = root.attribute(forName: "type")?.stringValue else {
            throw ParseError.missingType(root.name ?? "unknown root element")
        }

        switch type {
        case "auth-request":
            return .authRequest(try parseAuthRequest(root))
        case "complete":
            return .complete(try parseComplete(root))
        default:
            throw ParseError.unexpectedType(type)
        }
    }

    /// Reads the tunnel groups out of a response to a group-less init POST.
    ///
    /// Deliberately separate from `parse`: a gateway answering without a chosen group replies
    /// with a login *form*, which has none of the SSO elements `parseAuthRequest` insists on.
    /// Both shapes are accepted here, since a gateway with a single SAML group skips the form
    /// and answers with the SSO challenge for its default group instead.
    public static func parseProbe(_ data: Data) throws -> GatewayProbe {
        guard let document = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]),
              let root = document.rootElement()
        else {
            throw ParseError.notXML
        }

        guard let type = root.attribute(forName: "type")?.stringValue else {
            throw ParseError.missingType(root.name ?? "unknown root element")
        }
        guard type == "auth-request" else {
            throw ParseError.unexpectedType(type)
        }

        if let error = root.firstChild(named: "auth")?.childText("error"), !error.isEmpty {
            throw ParseError.gatewayError(error)
        }

        var groups = groupOptions(in: root)

        // No dropdown means the gateway offers exactly one group and went straight to its
        // challenge. It names that group in the opaque block it wants echoed back.
        if groups.isEmpty, let only = root.firstChild(named: "opaque")?.childText("tunnel-group"),
           !only.isEmpty {
            groups = [TunnelGroupOption(value: only, label: only, isDefault: true)]
        }

        guard !groups.isEmpty else {
            throw ParseError.missingElement("group-select options")
        }

        return GatewayProbe(groups: groups)
    }

    /// Options of the login form's group dropdown, in the order the gateway listed them.
    private static func groupOptions(in root: XMLElement) -> [TunnelGroupOption] {
        guard
            let form = root.firstChild(named: "auth")?.firstChild(named: "form"),
            let selects = form.children?.compactMap({ $0 as? XMLElement })
                .filter({ $0.localName == "select" || $0.name == "select" }),
            // Cisco names it `group_list`; accept anything group-ish so a gateway with a
            // differently named dropdown still works rather than silently offering nothing.
            let select = selects.first(where: {
                ($0.attribute(forName: "name")?.stringValue ?? "").lowercased().contains("group")
            }) ?? selects.first
        else {
            return []
        }

        return (select.children?.compactMap { $0 as? XMLElement } ?? [])
            .filter { $0.localName == "option" || $0.name == "option" }
            .compactMap { option in
                let text = option.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = option.attribute(forName: "value")?.stringValue ?? text
                guard let value, !value.isEmpty else { return nil }

                let selected = option.attribute(forName: "selected")?.stringValue?.lowercased()
                return TunnelGroupOption(
                    value: value,
                    label: (text?.isEmpty == false ? text : value) ?? value,
                    isDefault: selected == "true" || selected == "selected"
                )
            }
    }

    private static func parseAuthRequest(_ root: XMLElement) throws -> AuthRequest {
        guard let auth = root.firstChild(named: "auth") else {
            throw ParseError.missingElement("auth")
        }

        let error = auth.childText("error") ?? ""

        // An auth-request carrying an error and no login URL is a rejection, not a challenge.
        guard let rawLogin = auth.childText("sso-v2-login") else {
            if !error.isEmpty { throw ParseError.gatewayError(error) }
            throw ParseError.missingElement("sso-v2-login")
        }
        guard let loginURL = URL(string: rawLogin) else {
            throw ParseError.malformedURL(rawLogin)
        }

        guard let rawFinal = auth.childText("sso-v2-login-final") else {
            throw ParseError.missingElement("sso-v2-login-final")
        }
        guard let loginFinalURL = URL(string: rawFinal) else {
            throw ParseError.malformedURL(rawFinal)
        }

        guard let cookieName = auth.childText("sso-v2-token-cookie-name") else {
            throw ParseError.missingElement("sso-v2-token-cookie-name")
        }

        guard let opaque = root.firstChild(named: "opaque") else {
            throw ParseError.missingElement("opaque")
        }

        return AuthRequest(
            authID: auth.attribute(forName: "id")?.stringValue ?? "",
            title: auth.childText("title") ?? "",
            message: auth.childText("message") ?? "",
            error: error,
            loginURL: loginURL,
            loginFinalURL: loginFinalURL,
            tokenCookieName: cookieName,
            errorCookieName: auth.childText("sso-v2-error-cookie-name"),
            // Whitespace is preserved when parsing, so the serialised element arrives with the
            // surrounding newlines attached. Trim them: the element itself must go back
            // untouched, but its indentation is not part of the gateway's state.
            opaqueXML: opaque.xmlString.trimmingCharacters(in: .whitespacesAndNewlines),
            tunnelGroup: opaque.childText("tunnel-group")
        )
    }

    private static func parseComplete(_ root: XMLElement) throws -> AuthComplete {
        guard let sessionToken = root.childText("session-token"), !sessionToken.isEmpty else {
            throw ParseError.missingElement("session-token")
        }

        guard
            let config = root.firstChild(named: "config"),
            let baseConfig = config.firstChild(named: "vpn-base-config"),
            let certHash = baseConfig.childText("server-cert-hash"),
            !certHash.isEmpty
        else {
            throw ParseError.missingElement("server-cert-hash")
        }

        let auth = root.firstChild(named: "auth")

        return AuthComplete(
            authID: auth?.attribute(forName: "id")?.stringValue ?? "",
            message: auth?.childText("message") ?? "",
            sessionToken: sessionToken,
            serverCertHash: certHash
        )
    }

    // MARK: - Requests

    /// Step 1. Asks the gateway how to authenticate against a tunnel group.
    ///
    /// - Parameters:
    ///   - groupSelect: the tunnel group alias, for example `MFA-VPN`. Pass nil or an empty
    ///     string to omit the element, which is how the gateway is asked what groups it has:
    ///     it then answers with its group dropdown, or with the challenge for its default.
    ///   - groupAccess: the gateway URL the client is dialling.
    public static func initRequest(
        groupSelect: String?,
        groupAccess: String,
        clientVersion: String = defaultClientVersion
    ) -> String {
        let groupLine = (groupSelect?.isEmpty == false)
            ? "\n<group-select>\(escape(groupSelect!))</group-select>"
            : ""

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <config-auth client="vpn" type="init" aggregate-auth-version="2">
        <version who="vpn">\(escape(clientVersion))</version>
        <device-id>mac-intel</device-id>\(groupLine)
        <group-access>\(escape(groupAccess))</group-access>
        <capabilities>
        <auth-method>single-sign-on-v2</auth-method>
        </capabilities>
        </config-auth>
        """
    }

    /// Step 3. Presents the SAML token collected in the browser.
    ///
    /// `opaqueXML` must be the verbatim block from the auth-request; the gateway treats it as
    /// its own session state.
    public static func authReplyRequest(
        opaqueXML: String,
        ssoToken: String,
        clientVersion: String = defaultClientVersion
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <config-auth client="vpn" type="auth-reply" aggregate-auth-version="2">
        <version who="vpn">\(escape(clientVersion))</version>
        <device-id>mac-intel</device-id>
        <session-token/>
        <session-id/>
        \(opaqueXML)
        <auth>
        <sso-token>\(escape(ssoToken))</sso-token>
        </auth>
        </config-auth>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - XMLElement conveniences

extension XMLElement {
    /// First direct child with this name, ignoring namespaces.
    func firstChild(named name: String) -> XMLElement? {
        children?.lazy
            .compactMap { $0 as? XMLElement }
            .first { $0.localName == name || $0.name == name }
    }

    /// Trimmed text of a direct child, or nil when the child is absent.
    func childText(_ name: String) -> String? {
        firstChild(named: name)?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
