import CryptoKit
import Foundation

/// Talks `config-auth` to the VPN gateway: the init POST that starts a login, and the
/// auth-reply POST that trades a SAML token for a session token.
///
/// Trust is established by pinning the gateway certificate's SHA1 fingerprint rather than by
/// disabling validation. A certificate that no longer matches the pin is still accepted when a
/// public authority vouches for it under the gateway's own name, which is what a renewal looks
/// like; the caller re-pins to it (`renewedCertificate`).
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
                    The gateway's certificate changed and no public authority vouches for the \
                    new one, so it was refused. Pinned \(expected), presented \(actual ?? "none"). \
                    If the gateway really was given a new certificate, open Settings, \
                    Connections, press Forget beside the certificate, then Detect.
                    """
            case .wrongResponseKind(let detail):
                return "The gateway responded with \(detail) at the wrong stage of the login."
            }
        }
    }

    /// How the gateway's certificate is judged.
    public enum TrustPolicy: Equatable, Sendable {
        /// Normal operation: the stored fingerprint must match, or the connection is refused.
        case pinned
        /// First contact only. Accepts whatever certificate the gateway presents and records
        /// its fingerprint so it can be pinned from then on. Nothing else may use this: it
        /// trusts the network for exactly one request, which is the price of not having the
        /// fingerprint compiled in.
        case learnFingerprint
    }

    private let profile: VPNProfile
    private let trustPolicy: TrustPolicy
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

    /// Everything the presented certificate says about itself, read during the same handshake.
    /// Kept alongside the fingerprint so a pin can be shown as a certificate rather than as a
    /// row of hex.
    public private(set) var observedCertificate: PinnedCertificate?

    /// The certificate accepted in place of the pin because a public authority vouches for it,
    /// which is what a gateway renewing its certificate looks like. Nil unless that happened; the
    /// caller is expected to re-pin to it, or every later step would refuse it again.
    public private(set) var renewedCertificate: PinnedCertificate?

    /// The fingerprint of a certificate refused during the handshake. URLSession reports a
    /// refused challenge as "cancelled", which is what the user was shown for a certificate
    /// change; this is how `postRaw` tells the two apart.
    private var rejectedFingerprint: String?

    public init(
        profile: VPNProfile,
        trustPolicy: TrustPolicy = .pinned,
        clientVersion: String = ConfigAuth.defaultClientVersion
    ) {
        self.profile = profile
        self.trustPolicy = trustPolicy
        self.clientVersion = clientVersion
        super.init()
    }

    // MARK: - Steps

    /// Step 0. Asks the gateway which tunnel groups it offers, without naming one.
    ///
    /// Used by Settings so the only thing anyone types is the address. Pair it with
    /// `trustPolicy: .learnFingerprint` on a gateway whose fingerprint is not known yet, then
    /// store `observedCertificateSHA1` as the pin.
    public func probe() async throws -> ConfigAuth.GatewayProbe {
        let body = ConfigAuth.initRequest(
            groupSelect: nil,
            groupAccess: profile.groupAccess,
            clientVersion: clientVersion
        )

        return try ConfigAuth.parseProbe(try await postRaw(body))
    }

    /// What asking every group produced.
    public enum SSOGroupOutcome: Equatable, Sendable {
        /// This group answered with a browser sign-in, and is the one to save.
        case found(String)
        /// Every group was asked and none of them signs in through the browser.
        case noneOffered
    }

    /// Step 0b. Which of the offered tunnel groups actually does browser sign-in.
    ///
    /// The probe names the groups but says nothing about how any of them authenticates: a
    /// password group and a SAML group look identical in the dropdown. The only way to tell is
    /// to ask each one how to log in and see whether the answer contains a login URL, which is
    /// one extra request per group that is not the answer.
    ///
    /// Ordered so the common cases cost one request: a connection that already names a working
    /// group re-confirms it and stops.
    ///
    /// A group that refuses is skipped, not fatal, since the next one may be the right one.
    /// Anything else, a dropped connection or a certificate that no longer matches the pin, is
    /// thrown: those describe the gateway rather than the group, and swallowing them would
    /// report "no group here signs in through the browser" for what is really a network that
    /// went away mid-Detect.
    public func firstGroupOfferingSSO(
        among groups: [ConfigAuth.TunnelGroupOption],
        preferring current: String? = nil
    ) async throws -> SSOGroupOutcome {
        for group in ConfigAuth.groupsWorthTrying(groups, preferring: current) {
            let body = ConfigAuth.initRequest(
                groupSelect: group,
                groupAccess: profile.groupAccess,
                clientVersion: clientVersion
            )

            do {
                if case .authRequest = try await post(body) { return .found(group) }
            } catch ConfigAuth.ParseError.ssoNotOffered {
                continue
            } catch ConfigAuth.ParseError.gatewayError {
                continue
            }
        }

        return .noneOffered
    }

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
        try ConfigAuth.parse(try await postRaw(body))
    }

    private func postRaw(_ body: String) async throws -> Data {
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
            if let rejectedFingerprint, let expected = profile.normalizedCertificateSHA1 {
                throw ClientError.certificateRejected(expected: expected, actual: rejectedFingerprint)
            }
            throw ClientError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.httpStatus(http.statusCode)
        }

        return data
    }

    /// SHA1 of a DER-encoded certificate, uppercase hex. This is the same fingerprint format
    /// openconnect's `--servercert` accepts as a bare 40-character hex string.
    /// What to do with the certificate a gateway presented.
    public enum PinDecision: Equatable, Sendable {
        /// It matches the pin, or this request is the one allowed to learn it.
        case accept
        /// It does not match the pin, but a public authority vouches for it under the gateway's
        /// name. Accepted, and the connection re-pinned to it.
        case acceptRenewal
        /// It does not match and nothing vouches for it.
        case reject
        /// Nothing is pinned yet, so ordinary system validation decides.
        case systemTrust
    }

    /// The trust rule, apart from the handshake so it can be tested. `publiclyTrusted` is only
    /// asked on a mismatch, since evaluating a chain is the expensive part.
    public static func decide(
        presented: String,
        pinned: String?,
        policy: TrustPolicy,
        publiclyTrusted: @autoclosure () -> Bool
    ) -> PinDecision {
        if policy == .learnFingerprint { return .accept }
        guard let pinned else { return .systemTrust }
        if presented == pinned { return .accept }
        return publiclyTrusted() ? .acceptRenewal : .reject
    }

    /// Whether the chain is valid for `host` under the system's own roots, the way a browser
    /// would judge it. A self-signed or internal-CA certificate fails here, and so stays pinned.
    public static func isPubliclyTrusted(_ chain: [SecCertificate], host: String) -> Bool {
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard !chain.isEmpty,
              SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess,
              let trust
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

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

        let observed = PinnedCertificate.read(leaf)
        let fingerprint = observed.sha1
        observedCertificateSHA1 = fingerprint
        observedCertificate = observed

        // First contact takes the fingerprint on trust so it can be pinned from here on; the
        // caller asked for that explicitly and shows the user what was learned. With no pin at
        // all, system trust decides, which fails for a self-signed gateway: a pin is required.
        //
        // A mismatch used to be refused outright, so a gateway renewing its certificate stopped
        // every connect until someone found Forget and Detect. A renewal from a public authority,
        // valid for this very host name, is now taken and re-pinned. Anything less still fails.
        let host = challenge.protectionSpace.host
        switch Self.decide(
            presented: fingerprint,
            pinned: profile.normalizedCertificateSHA1,
            policy: trustPolicy,
            publiclyTrusted: Self.isPubliclyTrusted(chain, host: host)
        ) {
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .acceptRenewal:
            renewedCertificate = observed
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .reject:
            rejectedFingerprint = fingerprint
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .systemTrust:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
