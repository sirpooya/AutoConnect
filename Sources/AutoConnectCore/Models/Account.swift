import Foundation

/// One authenticator entry. Deliberately holds **no secret**: the secret lives in the Keychain
/// and is fetched only for the moment a code is generated.
public struct Account: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var issuer: String
    public var label: String
    public var algorithm: TOTP.Algorithm
    public var digits: Int
    public var period: Int

    public init(
        id: UUID = UUID(),
        issuer: String,
        label: String,
        algorithm: TOTP.Algorithm = .sha1,
        digits: Int = TOTP.defaultDigits,
        period: Int = TOTP.defaultPeriod
    ) {
        self.id = id
        self.issuer = issuer
        self.label = label
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
    }

    /// What the menu row shows as its title. Falls back to the label when there is no issuer.
    public var displayTitle: String {
        issuer.isEmpty ? label : issuer
    }

    /// Secondary line in the menu row. Empty when it would just repeat the title.
    public var displaySubtitle: String {
        issuer.isEmpty ? "" : label
    }

    /// The single line shown above the code: the account itself, without the issuer.
    ///
    /// The issuer is the same for every row it appears on, so leading with it buried the part
    /// that actually tells two rows apart. It is still in the details view.
    public var displayHeading: String {
        label.isEmpty ? displayTitle : label
    }

    /// True when this entry uses settings an authenticator would consider unusual, which is
    /// worth surfacing in the UI so a wrong code is easier to diagnose.
    public var usesNonDefaultSettings: Bool {
        algorithm != .sha1 || digits != TOTP.defaultDigits || period != TOTP.defaultPeriod
    }
}

/// Parses the `otpauth://` URIs found in enrollment QR codes.
///
///     otpauth://totp/Issuer:account@example.com?secret=BASE32&issuer=Issuer&algorithm=SHA1&digits=6&period=30
public enum OTPAuthURI {

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notAnOTPAuthURI
        case counterBasedNotSupported
        case missingSecret
        case badSecret(Base32.DecodeError)
        case missingLabel

        public var description: String {
            switch self {
            case .notAnOTPAuthURI:
                return "That is not an otpauth:// URI."
            case .counterBasedNotSupported:
                return "Counter-based (HOTP) codes are not supported, only time-based (TOTP)."
            case .missingSecret:
                return "The URI has no secret parameter."
            case .badSecret(let underlying):
                return "The secret could not be decoded. \(underlying.description)"
            case .missingLabel:
                return "The URI has no account label."
            }
        }
    }

    /// The result of a parse: metadata plus the raw secret, kept separate so the caller can
    /// hand the secret straight to the Keychain and let it go out of scope.
    public struct Parsed {
        public let account: Account
        public let secret: Data

        public init(account: Account, secret: Data) {
            self.account = account
            self.secret = secret
        }
    }

    public static func parse(_ string: String) throws -> Parsed {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "otpauth"
        else {
            throw ParseError.notAnOTPAuthURI
        }

        switch components.host?.lowercased() {
        case "totp":
            break
        case "hotp":
            throw ParseError.counterBasedNotSupported
        default:
            throw ParseError.notAnOTPAuthURI
        }

        let query = expandingEncodedSeparators(
            Dictionary(
                (components.queryItems ?? []).compactMap { item -> (String, String)? in
                    guard let value = item.value, !value.isEmpty else { return nil }
                    return (item.name.lowercased(), value)
                },
                uniquingKeysWith: { first, _ in first }
            )
        )

        guard let rawSecret = query["secret"] else { throw ParseError.missingSecret }

        let secret: Data
        do {
            secret = try Base32.decode(rawSecret)
        } catch let error as Base32.DecodeError {
            throw ParseError.badSecret(error)
        }

        // URLComponents has already percent-decoded the path for us.
        let path = components.path.hasPrefix("/")
            ? String(components.path.dropFirst())
            : components.path

        var issuer = query["issuer"] ?? ""
        var label = path

        // The label half of the path may be prefixed "Issuer:account". The issuer query
        // parameter wins when both are present, per the Key URI spec.
        if let separator = path.firstIndex(of: ":") {
            let prefix = String(path[path.startIndex..<separator])
            let remainder = String(path[path.index(after: separator)...])
            if issuer.isEmpty { issuer = prefix }
            label = remainder
        }

        issuer = issuer.trimmingCharacters(in: .whitespaces)
        label = label.trimmingCharacters(in: .whitespaces)

        guard !label.isEmpty || !issuer.isEmpty else { throw ParseError.missingLabel }

        let algorithm = query["algorithm"].flatMap { TOTP.Algorithm(loose: $0) } ?? .sha1
        let digits = query["digits"].flatMap(Int.init) ?? TOTP.defaultDigits
        let period = query["period"].flatMap(Int.init) ?? TOTP.defaultPeriod

        let account = Account(
            issuer: issuer,
            label: label,
            algorithm: algorithm,
            digits: min(max(digits, 6), 8),
            period: period > 0 ? period : TOTP.defaultPeriod
        )

        return Parsed(account: account, secret: secret)
    }

    /// The parameters this scheme defines. Only these are folded back out of a mangled value,
    /// so an issuer that legitimately contains an ampersand is left exactly as it was written.
    private static let knownParameters: Set<String> = [
        "secret", "issuer", "algorithm", "digits", "period", "counter", "image",
    ]

    /// Repairs a URI whose parameter separators were percent-encoded.
    ///
    /// Some enrollment pages escape the whole query string when they build the QR payload, so
    /// `&` arrives as `%26` and `=` as `%3D`. `URLComponents` then sees a single parameter
    /// carrying the rest of the query inside its value, and the issuer reads
    /// `Example&algorithm=SHA1&digits=6&period=30` everywhere it is shown. The trailing values
    /// are usually the defaults, so the codes are still correct and only the name looks wrong,
    /// which is what lets a QR code like this reach a user before anyone notices. When the
    /// secret is the parameter that swallowed the tail the account cannot be added at all,
    /// since the tail goes into the Base32 decoder.
    ///
    /// A value is split only when every trailing piece is a `name=value` pair naming a
    /// parameter above, and a parameter written properly always wins over one recovered from
    /// inside a value.
    private static func expandingEncodedSeparators(
        _ query: [String: String]
    ) -> [String: String] {
        var expanded = query

        for (name, value) in query where value.contains("&") {
            let pieces = value.components(separatedBy: "&")
            guard let head = pieces.first, pieces.count > 1 else { continue }

            var recovered: [(name: String, value: String)] = []
            for piece in pieces.dropFirst() {
                guard let separator = piece.firstIndex(of: "="),
                      case let key = String(piece[piece.startIndex..<separator]).lowercased(),
                      knownParameters.contains(key),
                      case let trailing = String(piece[piece.index(after: separator)...]),
                      !trailing.isEmpty
                else {
                    recovered = []
                    break
                }
                recovered.append((key, trailing))
            }

            guard !recovered.isEmpty else { continue }

            expanded[name] = head
            for pair in recovered where expanded[pair.name] == nil {
                expanded[pair.name] = pair.value
            }
        }

        return expanded
    }

    /// Finds the first `otpauth://` URI in arbitrary text, so a QR payload with surrounding
    /// noise still works.
    public static func firstURI(in text: String) -> String? {
        guard let range = text.range(of: "otpauth://", options: .caseInsensitive) else {
            return nil
        }
        let candidate = text[range.lowerBound...]
        let terminated = candidate.prefix { !$0.isWhitespace }
        return String(terminated)
    }
}
