import Foundation

/// Decides which origins a sign-in may type a password and a one-time code into.
///
/// The rule the login is supposed to follow is "never type a secret into an unexpected page", and
/// the shape of a SAML sign-in makes that harder than it sounds: nothing about the identity
/// provider is known in advance. The gateway names its own login URL, that URL redirects to
/// whichever IdP the company uses, and the form is somewhere on the other side. Hardcoding a host
/// is not an option, so the flow has to learn one.
///
/// Learning it once is the whole point. Trusting *every* host the flow passes through is the same
/// as trusting none: one open redirect anywhere in the chain, and the password is typed into
/// whatever the redirect pointed at. So this keeps exactly two anchors:
///
/// - the **gateway**, which is known from the auth-request before the browser opens, and
/// - the **identity provider**, which is the first host outside the gateway's domain and is
///   recorded once and never replaced.
///
/// Anything sharing a domain with either anchor is part of the same sign-in. Anything else is not,
/// and filling stops rather than guessing. Autofill is a convenience layered on a working manual
/// path, so refusing costs the user a paste, not a login.
///
/// Pure and here rather than in the view layer for the same reason `ReconnectPolicy` and
/// `StatusNotificationPolicy` are: this is the decision worth testing, and it must not need a
/// webview to exercise.
public struct LoginOriginPolicy: Equatable, Sendable {

    /// The gateway's own login host, from the auth-request. Fixed for the life of the sign-in.
    public let gatewayHost: String?

    /// The identity provider the gateway handed off to, learned from the first navigation that
    /// leaves the gateway's domain. Nil until that happens, and never replaced once set.
    public private(set) var identityProviderHost: String?

    public init(gatewayHost: String?) {
        self.gatewayHost = Self.normalized(gatewayHost)
    }

    /// Offers a host the flow has reached.
    ///
    /// Only ever fills in the identity provider, and only the first time. A host that is already
    /// covered by an anchor teaches nothing, and a second unrelated host is precisely the case
    /// this exists to refuse, so neither changes anything.
    public mutating func observe(host: String?) {
        guard let host = Self.normalized(host) else { return }
        guard identityProviderHost == nil, !isAnchored(host) else { return }
        identityProviderHost = host
    }

    /// Whether a secret may be typed into a page served by this host.
    public func allows(host: String?) -> Bool {
        guard let host = Self.normalized(host) else { return false }
        return isAnchored(host)
    }

    /// The hosts a secret may currently reach, for the diagnostic log.
    public var anchors: [String] {
        [gatewayHost, identityProviderHost].compactMap { $0 }
    }

    private func isAnchored(_ host: String) -> Bool {
        anchors.contains { $0 == host || Self.sharesDomain($0, host) }
    }

    /// Two or more shared trailing labels means the same organisation, near enough:
    /// `sso.example.com` and `login.example.com` share `example.com`.
    ///
    /// The same heuristic `LoginKeychain.rank` already uses, and it errs the same way: a registry
    /// like `co.uk` has two labels of its own, so two hosts under one would be treated as related.
    /// That is a wider net than a public-suffix list would cast, and still enormously narrower
    /// than trusting the whole redirect chain, which is what this replaces.
    static func sharesDomain(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.split(separator: ".").reversed())
        let right = Array(rhs.split(separator: ".").reversed())
        return zip(left, right).prefix { $0 == $1 }.count >= 2
    }

    /// Hosts are compared case-insensitively, and an empty one is no host at all.
    private static func normalized(_ host: String?) -> String? {
        guard let host = host?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty
        else {
            return nil
        }
        return host
    }
}
