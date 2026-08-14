import Foundation

/// A sign-in identity: who you are at the identity provider, and where the password comes from.
///
/// Kept apart from `VPNProfile` because the same account often opens more than one gateway, and
/// because a password should be typed once rather than once per connection. A connection points
/// at one of these by id.
///
/// The password itself is never in here. `keychainAccount` names the Keychain item that holds
/// it, or, for `.loginKeychain`, `passwordKeychainServer` names a website entry a browser
/// already saved.
public struct Credential: Codable, Equatable, Identifiable, Sendable {

    /// Where the password comes from.
    public enum PasswordSource: String, Codable, CaseIterable, Sendable {
        /// Nothing stored. The login window opens with the password field empty.
        case ask
        /// This app's own Keychain item, typed once in Settings.
        case stored
        /// An item a browser already saved in the login Keychain, reused rather than copied.
        case loginKeychain

        public var title: String {
            switch self {
            case .ask: "Ask me each time"
            case .stored: "Save it here"
            case .loginKeychain: "Login Keychain"
            }
        }
    }

    public var id: UUID
    /// Optional label, for telling two accounts at the same provider apart.
    public var name: String
    /// Username or email typed into the IdP page.
    public var username: String
    public var passwordSource: PasswordSource
    /// The login-Keychain server whose item supplies the password, for `.loginKeychain`.
    public var passwordKeychainServer: String?
    /// Name of this app's own Keychain item, for `.stored`. Derived from the id, so two
    /// credentials never share one and deleting one cannot take another's password.
    public var keychainAccount: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        username: String = "",
        passwordSource: PasswordSource = .stored,
        passwordKeychainServer: String? = nil,
        keychainAccount: String? = nil
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.passwordSource = passwordSource
        self.passwordKeychainServer = passwordKeychainServer
        self.keychainAccount = keychainAccount ?? "credential-\(id.uuidString)"
    }

    /// Decoded key by key with defaults, so a credential saved by an older build survives a
    /// new key being added rather than failing to decode and disappearing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }

        let id = value(.id, UUID())
        self.id = id
        name = value(.name, "")
        username = value(.username, "")
        passwordSource = value(.passwordSource, .stored)
        passwordKeychainServer = try? container.decodeIfPresent(
            String.self, forKey: .passwordKeychainServer
        )
        keychainAccount = value(.keychainAccount, "credential-\(id.uuidString)")
    }

    /// What to call this credential in a list or a picker.
    public var displayName: String {
        let named = name.trimmingCharacters(in: .whitespaces)
        if !named.isEmpty { return named }

        let user = username.trimmingCharacters(in: .whitespaces)
        return user.isEmpty ? "New credential" : user
    }

    /// The second line: the username when the name already took the first, otherwise where the
    /// password comes from.
    public var displaySubtitle: String {
        let named = name.trimmingCharacters(in: .whitespaces)
        let user = username.trimmingCharacters(in: .whitespaces)
        return named.isEmpty || user.isEmpty ? passwordSource.title : user
    }
}
