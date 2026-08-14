import Foundation

/// RFC 4648 Base32. Foundation only ships Base64, and `otpauth://` secrets are Base32.
public enum Base32 {

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case empty
        case invalidCharacter(Character)
        case invalidLength(Int)

        public var description: String {
            switch self {
            case .empty:
                return "The secret is empty."
            case .invalidCharacter(let character):
                return "'\(character)' is not a valid Base32 character (A-Z and 2-7 only)."
            case .invalidLength(let count):
                return "\(count) Base32 characters cannot form whole bytes."
            }
        }
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static let lookup: [Character: UInt32] = {
        var table = [Character: UInt32](minimumCapacity: 32)
        for (index, character) in alphabet.enumerated() {
            table[character] = UInt32(index)
        }
        return table
    }()

    /// Character counts that can appear in a valid Base32 group. 1, 3 and 6 leftover
    /// characters carry fewer than 8 bits of new data, so they are always malformed.
    private static let validRemainders: Set<Int> = [0, 2, 4, 5, 7]

    /// Decodes a Base32 string into raw bytes.
    ///
    /// Tolerates what real-world secrets actually look like: lowercase, missing or excess
    /// `=` padding, spaces, and the hyphens some services print for readability.
    public static func decode(_ input: String) throws -> Data {
        var cleaned = ""
        cleaned.reserveCapacity(input.count)

        for character in input {
            switch character {
            case " ", "-", "_", "\t", "\n", "\r":
                continue
            case "=":
                continue
            default:
                cleaned.append(Character(character.uppercased()))
            }
        }

        guard !cleaned.isEmpty else { throw DecodeError.empty }
        guard validRemainders.contains(cleaned.count % 8) else {
            throw DecodeError.invalidLength(cleaned.count)
        }

        var output = Data()
        output.reserveCapacity(cleaned.count * 5 / 8)

        var accumulator: UInt32 = 0
        var bitsHeld = 0

        for character in cleaned {
            guard let value = lookup[character] else {
                throw DecodeError.invalidCharacter(character)
            }
            accumulator = (accumulator << 5) | value
            bitsHeld += 5

            if bitsHeld >= 8 {
                bitsHeld -= 8
                output.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bitsHeld)))
            }
        }

        return output
    }

    /// Encodes bytes as padded Base32. Used for round-trip tests and for showing a
    /// manually entered secret back to the user in canonical form.
    public static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        var output = ""
        output.reserveCapacity((data.count + 4) / 5 * 8)

        var accumulator: UInt32 = 0
        var bitsHeld = 0

        for byte in data {
            accumulator = (accumulator << 8) | UInt32(byte)
            bitsHeld += 8

            while bitsHeld >= 5 {
                bitsHeld -= 5
                let index = Int((accumulator >> UInt32(bitsHeld)) & 0x1f)
                output.append(alphabet[index])
            }
        }

        if bitsHeld > 0 {
            let index = Int((accumulator << UInt32(5 - bitsHeld)) & 0x1f)
            output.append(alphabet[index])
        }

        while output.count % 8 != 0 {
            output.append("=")
        }

        return output
    }
}
