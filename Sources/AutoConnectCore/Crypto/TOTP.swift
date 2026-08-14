import CryptoKit
import Foundation

/// RFC 6238 time-based one-time passwords, with the RFC 4226 dynamic truncation it builds on.
public enum TOTP {

    public enum Algorithm: String, CaseIterable, Codable, Sendable {
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case sha512 = "SHA512"

        /// `otpauth://` URIs are inconsistent about case, so match loosely.
        public init?(loose raw: String) {
            let normalized = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard let match = Algorithm(rawValue: normalized) else { return nil }
            self = match
        }
    }

    /// Google Authenticator defaults, which is what almost every issuer uses.
    public static let defaultDigits = 6
    public static let defaultPeriod = 30

    /// The RFC 6238 time step for a given moment.
    public static func counter(at date: Date, period: Int = defaultPeriod) -> UInt64 {
        let period = max(1, period)
        let seconds = date.timeIntervalSince1970
        return UInt64(floor(seconds / Double(period)))
    }

    /// Seconds until the current code expires.
    public static func secondsRemaining(at date: Date, period: Int = defaultPeriod) -> Double {
        let period = Double(max(1, period))
        let seconds = date.timeIntervalSince1970
        return period - seconds.truncatingRemainder(dividingBy: period)
    }

    /// Fraction of the current period still remaining, 1.0 down to 0.0. Drives the ring.
    public static func remainingFraction(at date: Date, period: Int = defaultPeriod) -> Double {
        secondsRemaining(at: date, period: period) / Double(max(1, period))
    }

    /// Generates a code for an explicit counter value. The RFC test vectors work at this level.
    public static func generate(
        secret: Data,
        counter: UInt64,
        algorithm: Algorithm = .sha1,
        digits: Int = defaultDigits
    ) -> String {
        var message = Data(count: 8)
        for index in 0..<8 {
            // 8-byte big-endian counter.
            message[index] = UInt8(truncatingIfNeeded: counter >> UInt64((7 - index) * 8))
        }

        let key = SymmetricKey(data: secret)
        let mac: Data
        switch algorithm {
        case .sha1:
            mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            mac = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        // RFC 4226 dynamic truncation: the low nibble of the last byte picks the offset.
        let offset = Int(mac[mac.count - 1] & 0x0f)
        var truncated: UInt32 = 0
        for index in 0..<4 {
            truncated = (truncated << 8) | UInt32(mac[offset + index])
        }
        truncated &= 0x7fff_ffff

        let digits = min(max(digits, 1), 9)
        let modulus = UInt32(pow(10.0, Double(digits)))
        let code = truncated % modulus

        return String(format: "%0\(digits)u", code)
    }

    /// Generates the code valid at `date`.
    public static func generate(
        secret: Data,
        at date: Date = Date(),
        algorithm: Algorithm = .sha1,
        digits: Int = defaultDigits,
        period: Int = defaultPeriod
    ) -> String {
        generate(
            secret: secret,
            counter: counter(at: date, period: period),
            algorithm: algorithm,
            digits: digits
        )
    }
}
