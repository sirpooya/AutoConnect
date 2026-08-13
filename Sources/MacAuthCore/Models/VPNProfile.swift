import Foundation

/// Everything needed to bring up one VPN connection, minus the secrets.
///
/// Credentials are referenced, never stored here: `credentialAccount` names the Keychain item
/// holding the password, and `otpAccountID` points at the authenticator entry whose code fills
/// the IdP's OTP field.
public struct VPNProfile: Codable, Equatable, Sendable {

    /// Gateway host, optionally with a port: `mfa-vpn.example.com:28015`.
    public var host: String
    /// Tunnel group alias, as shown in AnyConnect's GROUP dropdown.
    public var tunnelGroup: String
    /// Username or email typed into the IdP page.
    public var username: String
    /// SHA1 fingerprint of the gateway certificate, uppercase hex without separators.
    /// Required because the gateway certificate has no publicly trusted signer.
    public var certificateSHA1: String?
    /// Keychain account name holding the IdP password.
    public var credentialAccount: String
    /// The authenticator account whose TOTP fills the OTP field.
    public var otpAccountID: UUID?
    /// Absolute path to the openconnect binary.
    public var openconnectPath: String
    /// Absolute path to the vpnc-script openconnect uses to configure routes and DNS.
    public var vpncScriptPath: String?

    public init(
        host: String,
        tunnelGroup: String,
        username: String = "",
        certificateSHA1: String? = nil,
        credentialAccount: String = "vpn-password",
        otpAccountID: UUID? = nil,
        openconnectPath: String = "/opt/homebrew/bin/openconnect",
        vpncScriptPath: String? = "/opt/homebrew/etc/vpnc/vpnc-script"
    ) {
        self.host = host
        self.tunnelGroup = tunnelGroup
        self.username = username
        self.certificateSHA1 = certificateSHA1
        self.credentialAccount = credentialAccount
        self.otpAccountID = otpAccountID
        self.openconnectPath = openconnectPath
        self.vpncScriptPath = vpncScriptPath
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

    /// The verified profile for this project's gateway. Values were discovered by probing and
    /// are recorded in plan.md section 3.
    public static let digikalaMFA = VPNProfile(
        host: "mfa-vpn.dkservices.ir:28015",
        tunnelGroup: "MFA-VPN",
        certificateSHA1: "AA46A448019A03FFDAF8803558C9B19CE77B951B"
    )
}
