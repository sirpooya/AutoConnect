import Foundation

/// Everything needed to bring up one VPN connection, minus the secrets.
///
/// Credentials are referenced, never stored here: `credentialAccount` names the Keychain item
/// holding the password, and `otpAccountID` points at the authenticator entry whose code fills
/// the IdP's OTP field.
public struct VPNProfile: Codable, Equatable, Identifiable, Sendable {

    /// Where the IdP password comes from. Lives on `Credential` now; this alias keeps the
    /// legacy fields below decodable without a second copy of the enum.
    public typealias PasswordSource = Credential.PasswordSource

    /// Stable identity, so a connection can be renamed or re-pointed without losing its
    /// password or its place in the list.
    public var id: UUID
    /// Gateway host, optionally with a port: `mfa-vpn.example.com:28015`.
    public var host: String
    /// Tunnel group alias, as shown in AnyConnect's GROUP dropdown.
    public var tunnelGroup: String
    /// The sign-in identity this connection uses, from the credentials list. Nil means none is
    /// chosen yet, and the login window will open with nothing filled in.
    public var credentialID: UUID?
    /// Username or email typed into the IdP page.
    ///
    /// Superseded by `credentialID`: it is kept so a profile written by an older build can be
    /// migrated into a standalone credential, and so nothing silently loses a username.
    public var username: String
    /// SHA1 fingerprint of the gateway certificate, uppercase hex without separators.
    /// Required because the gateway certificate has no publicly trusted signer.
    public var certificateSHA1: String?
    /// Keychain account name holding the IdP password, when this app stores it itself.
    public var credentialAccount: String
    /// Where the password comes from.
    public var passwordSource: PasswordSource
    /// The login-Keychain server whose item supplies the password, when `passwordSource` is
    /// `.loginKeychain`. Nil means "no item chosen yet".
    public var passwordKeychainServer: String?
    /// Host of the identity provider the gateway redirects to, remembered from the last login so
    /// the Keychain lookup can offer that site's entry first. Not required for anything.
    public var idpHost: String?
    /// The authenticator account whose TOTP fills the OTP field.
    public var otpAccountID: UUID?
    /// Absolute path to the openconnect binary.
    public var openconnectPath: String
    /// Absolute path to the vpnc-script openconnect uses to configure routes and DNS.
    public var vpncScriptPath: String?

    public init(
        id: UUID = UUID(),
        host: String,
        tunnelGroup: String,
        credentialID: UUID? = nil,
        username: String = "",
        certificateSHA1: String? = nil,
        credentialAccount: String = "vpn-password",
        passwordSource: PasswordSource = .stored,
        passwordKeychainServer: String? = nil,
        idpHost: String? = nil,
        otpAccountID: UUID? = nil,
        openconnectPath: String = "/opt/homebrew/bin/openconnect",
        vpncScriptPath: String? = "/opt/homebrew/etc/vpnc/vpnc-script"
    ) {
        self.id = id
        self.host = host
        self.tunnelGroup = tunnelGroup
        self.credentialID = credentialID
        self.username = username
        self.certificateSHA1 = certificateSHA1
        self.credentialAccount = credentialAccount
        self.passwordSource = passwordSource
        self.passwordKeychainServer = passwordKeychainServer
        self.idpHost = idpHost
        self.otpAccountID = otpAccountID
        self.openconnectPath = openconnectPath
        self.vpncScriptPath = vpncScriptPath
    }

    /// Decoded key by key with defaults, never by the synthesized initialiser.
    ///
    /// A profile saved by an older build has none of the keys added since, and the synthesized
    /// decoder treats every one of those as a hard failure. That reads to the user as their
    /// settings vanishing on upgrade, so each key falls back to the value a fresh profile uses.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VPNProfile(host: "", tunnelGroup: "")

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }

        // A profile saved before connections had identities gets one now. Its Keychain item is
        // named by `credentialAccount`, which is decoded as saved, so the password survives.
        id = value(.id, UUID())
        host = value(.host, fallback.host)
        tunnelGroup = value(.tunnelGroup, fallback.tunnelGroup)
        credentialID = try? container.decodeIfPresent(UUID.self, forKey: .credentialID)
        username = value(.username, fallback.username)
        certificateSHA1 = try? container.decodeIfPresent(String.self, forKey: .certificateSHA1)
        credentialAccount = value(.credentialAccount, fallback.credentialAccount)
        passwordSource = value(.passwordSource, fallback.passwordSource)
        passwordKeychainServer = try? container.decodeIfPresent(
            String.self, forKey: .passwordKeychainServer
        )
        idpHost = try? container.decodeIfPresent(String.self, forKey: .idpHost)
        otpAccountID = try? container.decodeIfPresent(UUID.self, forKey: .otpAccountID)
        openconnectPath = value(.openconnectPath, fallback.openconnectPath)
        vpncScriptPath = (try? container.decodeIfPresent(String.self, forKey: .vpncScriptPath))
            ?? fallback.vpncScriptPath
    }

    /// The gateway root, which is where `config-auth` POSTs go.
    public var gatewayURL: URL? {
        URL(string: "https://\(host)/")
    }

    /// What the client reports as the URL it is dialling.
    public var groupAccess: String {
        "https://\(host)"
    }

    /// Normalised fingerprint for comparison: uppercase, no colons or spaces.
    public var normalizedCertificateSHA1: String? {
        guard let certificateSHA1 else { return nil }
        let stripped = certificateSHA1
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        return stripped.isEmpty ? nil : stripped
    }

    /// What to call this connection in a list or at the top of the menu.
    ///
    /// The address is the name: a gateway already has one, and a second label for the same
    /// thing is one more field to fill in and keep true.
    public var displayName: String {
        let address = host.trimmingCharacters(in: .whitespaces)
        if address.isEmpty { return "New connection" }
        // The port is noise in a title; the host is what identifies it.
        return address.split(separator: ":").first.map(String.init) ?? address
    }

    /// True once the profile has everything a connect needs.
    public var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !tunnelGroup.trimmingCharacters(in: .whitespaces).isEmpty
            && normalizedCertificateSHA1 != nil
    }

    /// What a fresh install starts with: nothing but the defaults that are true of any machine.
    ///
    /// No gateway, group or fingerprint is compiled in. The user types an address, and the app
    /// asks that gateway for the rest. Shipping a particular employer's values as defaults made
    /// every install look pre-configured for one company and left stale values in UserDefaults
    /// long after they changed.
    public static let empty = VPNProfile(host: "", tunnelGroup: "")

    /// A new, unconfigured connection. Its Keychain item is named after its identity, so two
    /// connections never share a password.
    public static func newConnection() -> VPNProfile {
        let id = UUID()
        return VPNProfile(
            id: id,
            host: "",
            tunnelGroup: "",
            credentialAccount: "vpn-password-\(id.uuidString)"
        )
    }

    /// A stand-in for tests and previews. Not a real gateway.
    public static let example = VPNProfile(
        host: "vpn.example.com:443",
        tunnelGroup: "EXAMPLE-VPN",
        certificateSHA1: "0123456789ABCDEF0123456789ABCDEF01234567"
    )
}
