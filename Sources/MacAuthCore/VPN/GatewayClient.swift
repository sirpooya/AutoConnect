import CryptoKit
import Foundation

/// Talks `config-auth` to the VPN gateway: the init POST that starts a login, and the
/// auth-reply POST that trades a SAML token for a session token.
///
/// The gateway's certificate has no publicly trusted signer, so trust is established by pinning
/// its SHA1 fingerprint rather than by disabling validation.
public final class GatewayClient: NSObject {

    public enum ClientError: Error, CustomStringConvertible {
        case badProfile
        case transport(Error)
        case httpStatus(Int)
        case certificateRejected(expected: String, actual: String?)
        case wrongResponseKind(String)

        public var description: String {
            switch self {
            case .badProfile:
                return "The VPN profile does not describe a usable gateway URL."
            case .transport(let underlying):
                return "Could not reach the gateway: \(underlying.localizedDescription)"
            case .httpStatus(let code):
                return "The gateway returned HTTP \(code)."
            case .certificateRejected(let expected, let actual):
                return """
                    The gateway presented an unexpected certificate. \
                    Expected \(expected), got \(actual ?? "none"). \
                    Refusing to continue.
                    """
            case .wrongResponseKind(let detail):
                return "The gateway responded with \(detail) at the wrong stage of the login."
            }
        }
    }

    private let profile: VPNProfile
    private let clientVersion: String
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Fingerprint of the certificate actually presented, recorded during the handshake.
    public private(set) var observedCertificateSHA1: String?

    public init(profile: VPNProfile, clientVersion: String = ConfigAuth.defaultClientVersion) {
        self.profile = profile
        self.clientVersion = clientVersion
        super.init()
    }

    // MARK: - Steps

    /// Step 1. Asks the gateway how to log in to the profile's tunnel group.
    public func requestAuthentication() async throws -> ConfigAuth.AuthRequest {
        let body = ConfigAuth.initRequest(
            groupSelect: profile.tunnelGroup,
            groupAccess: profile.groupAccess,
            clientVersion: clientVersion
        )

        switch try await post(body) {
        case .authRequest(let request):
            return request
        case .complete:
            throw ClientError.wrongResponseKind("an already-complete session")
        }
    }

    /// Step 3. Presents the SAML token collected in the browser and receives the session token.
    public func completeAuthentication(
        authRequest: ConfigAuth.AuthRequest,
        ssoToken: String
    ) async throws -> ConfigAuth.AuthComplete {
        let body = ConfigAuth.authReplyRequest(
            opaqueXML: authRequest.opaqueXML,
            ssoToken: ssoToken,
            clientVersion: clientVersion
        )

        switch try await post(body) {
        case .complete(let complete):
            return complete
        case .authRequest(let retry):
            // The gateway asking again means it did not accept the token.
            let reason = retry.error.isEmpty ? "the token was not accepted" : retry.error
            throw ClientError.wrongResponseKind("another login challenge (\(reason))")
        }
    }

    // MARK: - Transport

    private func post(_ body: String) async throws -> ConfigAuth.Response {
        guard let url = profile.gatewayURL else { throw ClientError.badProfile }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        for (field, value) in ConfigAuth.headers(clientVersion: clientVersion) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.httpStatus(http.statusCode)
        }

        return try ConfigAuth.parse(data)
    }

    /// SHA1 of a DER-encoded certificate, uppercase hex. This is the same fingerprint format
    /// openconnect's `--servercert` accepts as a bare 40-character hex string.
    public static func sha1Fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return Insecure.SHA1.hash(data: der)
            .map { String(format: "%02X", $0) }
            .joined()
    }
}

extension GatewayClient: URLSessionDelegate {

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            return completionHandler(.performDefaultHandling, nil)
        }

        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        guard let leaf = chain.first else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }

        let fingerprint = Self.sha1Fingerprint(of: leaf)
        observedCertificateSHA1 = fingerprint

        // With no pin configured, fall back to system trust. That will fail for this gateway,
        // which is the honest outcome: a pin is required, not optional.
        guard let expected = profile.normalizedCertificateSHA1 else {
            return completionHandler(.performDefaultHandling, nil)
        }

        if fingerprint == expected {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
