import Foundation

/// Parses the `otpauth-migration://offline?data=...` URI that Google Authenticator's
/// "Transfer accounts / Export accounts" screen shows as a QR code.
///
///     otpauth-migration://offline?data=<base64 of a protobuf MigrationPayload>
///
/// It is not one account but a batch of them, which is why this returns a `Batch` rather than
/// a single `OTPAuthURI.Parsed`. Google splits a large export across several QR codes, each
/// carrying its own `batch_index` of `batch_size`, so a scan that looks complete may only be
/// the first part: `Batch.summary` is what says so.
///
/// The payload is protobuf, decoded here by hand rather than by adding SwiftProtobuf. The
/// schema Google ships is small and frozen:
///
///     message MigrationPayload {
///       message OtpParameters {
///         bytes secret = 1; string name = 2; string issuer = 3;
///         Algorithm algorithm = 4;  // 1 SHA1, 2 SHA256, 3 SHA512, 4 MD5
///         DigitCount digits = 5;    // 1 six, 2 eight
///         OtpType type = 6;         // 1 HOTP, 2 TOTP
///         int64 counter = 7;
///       }
///       repeated OtpParameters otp_parameters = 1;
///       int32 version = 2; int32 batch_size = 3; int32 batch_index = 4; int32 batch_id = 5;
///     }
///
/// There is no period field: Google Authenticator only ever exports the 30-second default.
public enum OTPMigrationURI {

    public static let scheme = "otpauth-migration"

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notAMigrationURI
        case missingData
        case badBase64
        case malformedPayload
        /// The batch parsed, but nothing in it is a time-based account this app can generate.
        case noUsableEntries(skipped: Int)

        public var description: String {
            switch self {
            case .notAMigrationURI:
                return "That is not an otpauth-migration:// URI."
            case .missingData:
                return "That export link has no data parameter."
            case .badBase64:
                return "That export link's data could not be decoded."
            case .malformedPayload:
                return "That export link's contents are not a readable account export."
            case .noUsableEntries(let skipped):
                if skipped > 0 {
                    return "That export holds no time-based accounts. "
                        + "\(skipped) entry\(skipped == 1 ? "" : "s") uses a scheme this app does not support."
                }
                return "That export holds no accounts."
            }
        }
    }

    /// One scanned export QR code: the accounts it carried, what had to be left out, and where
    /// it sits in a multi-code export.
    public struct Batch {
        public let entries: [OTPAuthURI.Parsed]
        /// Entries present in the payload that this app cannot use: counter-based (HOTP),
        /// an algorithm it cannot compute, or an empty secret.
        public let skipped: Int
        /// Zero-based, as the payload states it.
        public let batchIndex: Int
        public let batchSize: Int

        public init(entries: [OTPAuthURI.Parsed], skipped: Int, batchIndex: Int, batchSize: Int) {
            self.entries = entries
            self.skipped = skipped
            self.batchIndex = batchIndex
            self.batchSize = batchSize
        }

        /// True when the export was split across several QR codes, so this scan is only part
        /// of what the user asked to move over.
        public var isPartialExport: Bool { batchSize > 1 }

        /// What to tell the user after the import, or nil when the account list appearing is
        /// the whole story. Kept here, and tested, so the wording cannot drift per caller.
        public var summary: String? {
            var sentences: [String] = []

            if isPartialExport {
                let part = min(max(batchIndex + 1, 1), batchSize)
                sentences.append(
                    "Imported \(count(entries.count, "account")) from part \(part) of \(batchSize) "
                        + "of that export. Scan the other QR codes to add the rest."
                )
            }

            if skipped > 0 {
                sentences.append(
                    "\(count(skipped, "entry", plural: "entries")) could not be imported: "
                        + "only time-based codes are supported."
                )
            }

            return sentences.isEmpty ? nil : sentences.joined(separator: " ")
        }

        private func count(_ n: Int, _ singular: String, plural: String? = nil) -> String {
            n == 1 ? "1 \(singular)" : "\(n) \(plural ?? singular + "s")"
        }
    }

    /// True when this text is an export link, so a caller can pick the right parser before
    /// reporting the payload as unrecognised.
    public static func isMigrationURI(_ string: String) -> Bool {
        firstURI(in: string) != nil
    }

    /// Finds the first export link in arbitrary text, matching `OTPAuthURI.firstURI` so a QR
    /// payload with surrounding noise still works.
    public static func firstURI(in text: String) -> String? {
        guard let range = text.range(of: "\(scheme)://", options: .caseInsensitive) else {
            return nil
        }
        let candidate = text[range.lowerBound...]
        return String(candidate.prefix { !$0.isWhitespace })
    }

    public static func parse(_ string: String) throws -> Batch {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == scheme
        else {
            throw ParseError.notAMigrationURI
        }

        // URLComponents percent-decodes the value for us, which is what turns %2B and %3D back
        // into the base64 they stand for.
        guard let raw = (components.queryItems ?? [])
            .first(where: { $0.name.lowercased() == "data" })?.value,
            !raw.isEmpty
        else {
            throw ParseError.missingData
        }

        guard let payload = decodeBase64(raw) else { throw ParseError.badBase64 }

        return try decode(payload: payload)
    }

    /// Standard base64, but tolerant: some tools hand back the URL-safe alphabet, and padding
    /// is easy to lose in a copy and paste.
    private static func decodeBase64(_ raw: String) -> Data? {
        var normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")

        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        return Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters])
    }

    // MARK: - Protobuf

    private static func decode(payload: Data) throws -> Batch {
        var reader = ProtobufReader(payload)
        var entries: [OTPAuthURI.Parsed] = []
        var skipped = 0
        var batchSize = 1
        var batchIndex = 0
        var sawParameters = false

        while !reader.isAtEnd {
            let field = try reader.readFieldHeader()
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                sawParameters = true
                if let parsed = try parameters(try reader.readBytes()) {
                    entries.append(parsed)
                } else {
                    skipped += 1
                }
            // Both fall back rather than throwing, for the same reason the entries do: a batch
            // counter this app cannot represent is not a reason to lose the accounts beside it.
            case (3, .varint):
                batchSize = Int(exactly: try reader.readVarint()) ?? 1
            case (4, .varint):
                batchIndex = Int(exactly: try reader.readVarint()) ?? 0
            default:
                try reader.skip(field.wireType)
            }
        }

        // A payload with no otp_parameters field at all is not an export, it is bytes that
        // happened to decode. An export whose entries were all unusable is a different story
        // and gets the count in its message.
        guard sawParameters else { throw ParseError.malformedPayload }
        guard !entries.isEmpty else { throw ParseError.noUsableEntries(skipped: skipped) }

        return Batch(
            entries: entries,
            skipped: skipped,
            batchIndex: batchIndex,
            batchSize: max(batchSize, 1)
        )
    }

    /// One `OtpParameters` message. Returns nil for an entry this app cannot generate codes
    /// for, which the caller counts rather than treating as a failed scan: one HOTP account in
    /// an export must not cost the user the other nine.
    private static func parameters(_ data: Data) throws -> OTPAuthURI.Parsed? {
        var reader = ProtobufReader(data)
        var secret = Data()
        var name = ""
        var issuer = ""
        var algorithm: TOTP.Algorithm? = .sha1
        var digits = TOTP.defaultDigits
        var isTimeBased = true

        while !reader.isAtEnd {
            let field = try reader.readFieldHeader()
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                secret = try reader.readBytes()
            case (2, .lengthDelimited):
                name = String(decoding: try reader.readBytes())
            case (3, .lengthDelimited):
                issuer = String(decoding: try reader.readBytes())
            case (4, .varint):
                switch try reader.readVarint() {
                case 0, 1: algorithm = .sha1     // ALGORITHM_UNSPECIFIED defaults to SHA1
                case 2: algorithm = .sha256
                case 3: algorithm = .sha512
                default: algorithm = nil         // MD5, which CryptoKit's HMAC cannot do here
                }
            case (5, .varint):
                digits = try reader.readVarint() == 2 ? 8 : 6
            case (6, .varint):
                // OTP_TYPE_UNSPECIFIED is treated as TOTP: every real export states the type,
                // and Google Authenticator's own default is time-based.
                isTimeBased = try reader.readVarint() != 1
            default:
                try reader.skip(field.wireType)
            }
        }

        guard isTimeBased, let algorithm, !secret.isEmpty else { return nil }

        var label = name.trimmingCharacters(in: .whitespaces)
        var displayIssuer = issuer.trimmingCharacters(in: .whitespaces)

        // The name is often "Issuer:account", the same shape as an otpauth:// path.
        if let separator = label.firstIndex(of: ":") {
            let prefix = String(label[label.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let remainder = String(label[label.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if displayIssuer.isEmpty {
                displayIssuer = prefix
                label = remainder
            } else if prefix.caseInsensitiveCompare(displayIssuer) == .orderedSame {
                label = remainder
            }
        }

        guard !label.isEmpty || !displayIssuer.isEmpty else { return nil }

        let account = Account(
            issuer: displayIssuer,
            label: label,
            algorithm: algorithm,
            digits: digits,
            period: TOTP.defaultPeriod
        )

        return OTPAuthURI.Parsed(account: account, secret: secret)
    }
}

/// Just enough of the protobuf wire format to read the export payload: varints, length-delimited
/// fields, and the ability to step over anything else without losing the stream.
private struct ProtobufReader {

    enum WireType {
        case varint
        case fixed64
        case lengthDelimited
        case fixed32
    }

    struct Field {
        let number: Int
        let wireType: WireType
    }

    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func readFieldHeader() throws -> Field {
        let tag = try readVarint()
        let wire: WireType
        switch tag & 0x07 {
        case 0: wire = .varint
        case 1: wire = .fixed64
        case 2: wire = .lengthDelimited
        case 5: wire = .fixed32
        // Wire types 3 and 4 are the deprecated group encoding, which nothing emits and which
        // cannot be skipped without knowing the schema.
        default: throw OTPMigrationURI.ParseError.malformedPayload
        }
        let number = Int(tag >> 3)
        guard number > 0 else { throw OTPMigrationURI.ParseError.malformedPayload }
        return Field(number: number, wireType: wire)
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while true {
            guard index < bytes.count else { throw OTPMigrationURI.ParseError.malformedPayload }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw OTPMigrationURI.ParseError.malformedPayload }
        }
    }

    mutating func readBytes() throws -> Data {
        // `Int(_:)` traps on a value too large to represent, and this length is whatever the
        // payload said it was. A QR code carrying a varint above `Int.max` therefore killed the
        // process outright rather than being reported as the malformed export it is, and a QR
        // code is not a trusted input: it is a picture, scanned from a screen or a camera.
        guard let length = Int(exactly: try readVarint()), bytes.count - index >= length else {
            throw OTPMigrationURI.ParseError.malformedPayload
        }
        defer { index += length }
        return Data(bytes[index..<(index + length)])
    }

    mutating func skip(_ wireType: WireType) throws {
        switch wireType {
        case .varint:
            _ = try readVarint()
        case .fixed64:
            try advance(8)
        case .fixed32:
            try advance(4)
        case .lengthDelimited:
            _ = try readBytes()
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard bytes.count - index >= count else {
            throw OTPMigrationURI.ParseError.malformedPayload
        }
        index += count
    }
}

private extension String {
    /// Names in an export are UTF-8, but a mangled one must not fail the whole batch.
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
