import CryptoKit
import Foundation
import Security

/// What the gateway's certificate says about itself, read once when it is pinned and kept with
/// the connection.
///
/// A trust-on-first-use pin proves nothing about who the gateway is; it only proves that nothing
/// has changed since the day it was learned. So the interesting facts are the ones that let a
/// person judge that day's decision for themselves, and the one that explains the failure when
/// the pin eventually stops matching: gateways renew their certificates, and a renewal looks
/// exactly like an attack unless you already know the old one was about to expire.
///
/// `sha1` stays the pin of record because that is the form `openconnect --servercert` takes as a
/// bare hex string. Everything else here is description.
public struct PinnedCertificate: Codable, Equatable, Sendable {

    /// How much life the certificate has left, which is what turns a future pin mismatch from a
    /// mystery into an expected renewal.
    public enum Expiry: Equatable, Sendable {
        case expired(daysAgo: Int)
        case soon(daysLeft: Int)
        case valid(daysLeft: Int)
        /// The certificate did not carry a validity period we could read.
        case unknown
    }

    /// Uppercase hex, no separators. The value `--servercert` accepts directly.
    public var sha1: String
    /// Uppercase hex, no separators. openconnect prefers this as `pin-sha256:`, and it is the
    /// stronger of the two comparisons.
    public var sha256: String
    /// Subject common name: who the certificate claims to be issued for.
    public var commonName: String?
    /// DNS names in the subjectAltName extension. Modern clients match on these, not the CN.
    public var subjectAltNames: [String]
    /// Issuer common name, or its organisation when it has no CN. Says whether this is a
    /// self-signed certificate or one from an internal CA, which is the reason pinning exists.
    public var issuer: String?
    public var notBefore: Date?
    public var notAfter: Date?
    /// When this app first accepted the certificate. Profile history rather than certificate
    /// data, and the only honest thing a first-contact pin can claim.
    public var pinnedAt: Date

    public init(
        sha1: String,
        sha256: String,
        commonName: String? = nil,
        subjectAltNames: [String] = [],
        issuer: String? = nil,
        notBefore: Date? = nil,
        notAfter: Date? = nil,
        pinnedAt: Date = Date()
    ) {
        self.sha1 = sha1
        self.sha256 = sha256
        self.commonName = commonName
        self.subjectAltNames = subjectAltNames
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.pinnedAt = pinnedAt
    }

    /// Decoded key by key with defaults, for the same reason `VPNProfile` is: a connection saved
    /// before a field existed must not fail to decode and take the whole profile down with it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha1 = (try? container.decode(String.self, forKey: .sha1)) ?? ""
        sha256 = (try? container.decode(String.self, forKey: .sha256)) ?? ""
        commonName = try? container.decodeIfPresent(String.self, forKey: .commonName)
        subjectAltNames = (try? container.decode([String].self, forKey: .subjectAltNames)) ?? []
        issuer = try? container.decodeIfPresent(String.self, forKey: .issuer)
        notBefore = try? container.decodeIfPresent(Date.self, forKey: .notBefore)
        notAfter = try? container.decodeIfPresent(Date.self, forKey: .notAfter)
        pinnedAt = (try? container.decode(Date.self, forKey: .pinnedAt)) ?? Date()
    }

    // MARK: - Reading a certificate

    /// Reads everything on offer from a certificate the gateway presented.
    ///
    /// Nothing here can fail in a way worth reporting: a certificate missing a field is described
    /// without it, because the fingerprints are the part that matters and those always exist.
    public static func read(_ certificate: SecCertificate, pinnedAt: Date = Date()) -> PinnedCertificate {
        let der = SecCertificateCopyData(certificate) as Data
        let values = SecCertificateCopyValues(certificate, nil, nil) as? [String: Any] ?? [:]

        return PinnedCertificate(
            sha1: hex(Insecure.SHA1.hash(data: der)),
            sha256: hex(SHA256.hash(data: der)),
            commonName: copyCommonName(certificate),
            subjectAltNames: dnsNames(in: values),
            issuer: name(in: values, oid: kSecOIDX509V1IssuerName),
            notBefore: date(in: values, oid: kSecOIDX509V1ValidityNotBefore),
            notAfter: date(in: values, oid: kSecOIDX509V1ValidityNotAfter),
            pinnedAt: pinnedAt
        )
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02X", $0) }.joined()
    }

    private static func copyCommonName(_ certificate: SecCertificate) -> String? {
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
        return name as String?
    }

    /// The `value` of one top-level OID entry in `SecCertificateCopyValues` output.
    private static func property(_ values: [String: Any], _ oid: CFString) -> Any? {
        (values[oid as String] as? [String: Any])?[kSecPropertyKeyValue as String]
    }

    /// Validity dates arrive as a `CFAbsoluteTime`, which is seconds from 2001, not from 1970.
    private static func date(in values: [String: Any], oid: CFString) -> Date? {
        guard let seconds = property(values, oid) as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// A distinguished name is a list of labelled components. The common name is what a person
    /// recognises, so it wins; an internal CA that only sets an organisation still gets named.
    private static func name(in values: [String: Any], oid: CFString) -> String? {
        let components = property(values, oid) as? [[String: Any]] ?? []

        func component(_ wanted: CFString) -> String? {
            components.first {
                $0[kSecPropertyKeyLabel as String] as? String == wanted as String
            }?[kSecPropertyKeyValue as String] as? String
        }

        return component(kSecOIDCommonName)
            ?? component(kSecOIDOrganizationName)
            ?? component(kSecOIDOrganizationalUnitName)
    }

    /// DNS entries out of the subjectAltName extension. The extension nests its entries one
    /// section deeper than most, and the labels are human strings ("DNS Name") rather than OIDs,
    /// so this walks the tree rather than reaching for a fixed path.
    private static func dnsNames(in values: [String: Any]) -> [String] {
        var found: [String] = []

        func walk(_ node: Any) {
            if let list = node as? [Any] {
                list.forEach(walk)
            } else if let entry = node as? [String: Any] {
                let label = entry[kSecPropertyKeyLabel as String] as? String ?? ""
                let value = entry[kSecPropertyKeyValue as String]

                if label.localizedCaseInsensitiveContains("dns"), let name = value as? String {
                    if !found.contains(name) { found.append(name) }
                } else if let value {
                    walk(value)
                }
            }
        }

        walk(property(values, kSecOIDSubjectAltName) as Any)
        return found
    }

    // MARK: - Judging it

    /// Whether the certificate is still inside its validity window, and by how much.
    ///
    /// `warningDays` is the point at which a renewal is close enough to be worth saying out loud,
    /// so that the pin mismatch it will cause is expected rather than alarming.
    public func expiry(asOf now: Date = Date(), warningDays: Int = 30) -> Expiry {
        guard let notAfter else { return .unknown }

        let day: TimeInterval = 86_400
        let remaining = notAfter.timeIntervalSince(now)
        // Rounded up: with eleven hours left, "expires in 1 day" is truer than "in 0 days".
        let days = Int((remaining / day).rounded(.up))

        if remaining < 0 { return .expired(daysAgo: max(1, -days)) }
        if days <= warningDays { return .soon(daysLeft: days) }
        return .valid(daysLeft: days)
    }

    /// Whether this certificate was issued for the given host, by the rules a TLS client uses:
    /// the subjectAltName DNS entries if there are any, and the common name only as a fallback
    /// for certificates old enough not to carry the extension.
    ///
    /// A mismatch does not stop anything (the pin is what is enforced) but it is worth showing:
    /// a certificate that names a different host is one reused from elsewhere.
    public func covers(host: String) -> Bool {
        let target = host
            .split(separator: ":").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""
        guard !target.isEmpty else { return false }

        let candidates = subjectAltNames.isEmpty ? [commonName].compactMap { $0 } : subjectAltNames
        return candidates.contains { matches(pattern: $0.lowercased(), host: target) }
    }

    /// A wildcard covers exactly one label, and only the leftmost one: `*.example.com` is
    /// `a.example.com` but neither `example.com` nor `a.b.example.com`.
    private func matches(pattern: String, host: String) -> Bool {
        guard pattern.hasPrefix("*.") else { return pattern == host }

        let suffix = String(pattern.dropFirst(2))
        guard let firstDot = host.firstIndex(of: ".") else { return false }
        return String(host[host.index(after: firstDot)...]) == suffix
    }

    /// Grouped in fours the way Keychain Access prints a fingerprint, so a value compared against
    /// that window is compared against the same shape.
    public static func groupedHex(_ value: String, groupSize: Int = 4) -> String {
        stride(from: 0, to: value.count, by: groupSize).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: groupSize, limitedBy: value.endIndex)
                ?? value.endIndex
            return String(value[start..<end])
        }
        .joined(separator: " ")
    }
}
