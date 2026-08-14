import Foundation
import Security

/// Reads passwords that are already in the login Keychain, saved by a browser rather than by
/// this app.
///
/// The point is to avoid asking for a password this Mac already holds. Safari and anything else
/// using the system Keychain store website logins as `kSecClassInternetPassword` items keyed by
/// server and account, so a lookup by the username the user typed finds the IdP entry without
/// them typing the password a second time.
///
/// Chrome and Firefox keep passwords in their own encrypted stores, not here, so they will not
/// be found. That is a limitation to state, not to work around.
public enum LoginKeychain {

    /// One matching item. Deliberately carries no password: listing is metadata-only.
    public struct Item: Equatable, Hashable, Identifiable, Sendable {
        public let server: String
        public let account: String

        public var id: String { "\(server)\u{1}\(account)" }

        public init(server: String, account: String) {
            self.server = server
            self.account = account
        }
    }

    public enum LookupError: Error, CustomStringConvertible {
        case denied
        case notFound
        case status(OSStatus)

        public var description: String {
            switch self {
            case .denied:
                return "Access to that Keychain item was denied."
            case .notFound:
                return "No matching item in the login Keychain."
            case .status(let code):
                return "The Keychain returned error \(code)."
            }
        }
    }

    /// Every internet-password item saved for this account name, newest first.
    ///
    /// Metadata only: no password is read, so macOS shows no permission prompt. That is what
    /// lets Settings say which item it found before anyone commits to using it.
    public static func items(account: String) -> [Item] {
        let account = account.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty else { return [] }

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let entries = result as? [[String: Any]]
        else {
            return []
        }

        let items = entries.compactMap { entry -> (item: Item, modified: Date)? in
            guard let server = entry[kSecAttrServer as String] as? String else { return nil }
            let modified = entry[kSecAttrModificationDate as String] as? Date ?? .distantPast
            return (Item(server: server, account: account), modified)
        }

        return items
            .sorted { $0.modified > $1.modified }
            .map(\.item)
            // The same site can hold several items; one row per server is what the user means.
            .reduce(into: [Item]()) { unique, item in
                if !unique.contains(item) { unique.append(item) }
            }
    }

    /// Reads the password for one item.
    ///
    /// This is the call that makes macOS ask permission, so it belongs at connect time, not
    /// while browsing Settings. Choosing "Always Allow" in that prompt means it is asked once.
    public static func password(server: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8)
            else {
                throw LookupError.notFound
            }
            return password
        case errSecItemNotFound:
            throw LookupError.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw LookupError.denied
        default:
            throw LookupError.status(status)
        }
    }

    /// Ranks candidate items against a host, so the IdP's own entry is offered first.
    ///
    /// Exact host wins, then a shared registrable-looking suffix (`sso.example.com` for
    /// `login.example.com`), then everything else in the order given.
    public static func rank(_ items: [Item], preferring host: String?) -> [Item] {
        guard let host = host?.lowercased(), !host.isEmpty else { return items }

        // Two or more shared trailing labels means the same organisation, near enough:
        // `sso.example.com` and `login.example.com` share `example.com`.
        func sharesDomain(_ lhs: String, _ rhs: String) -> Bool {
            let left = Array(lhs.split(separator: ".").reversed())
            let right = Array(rhs.split(separator: ".").reversed())
            return zip(left, right).prefix { $0 == $1 }.count >= 2
        }

        func score(_ item: Item) -> Int {
            let server = item.server.lowercased()
            if server == host { return 0 }
            if sharesDomain(server, host) { return 1 }
            return 2
        }

        // Stable: equal scores keep the order they came in, which is newest first.
        return items.enumerated()
            .sorted { (score($0.element), $0.offset) < (score($1.element), $1.offset) }
            .map(\.element)
    }
}
