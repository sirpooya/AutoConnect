import Foundation

/// Where the app points people on the web.
///
/// One place, because the same two URLs are now reached from About and from the error row in the
/// panel, and the repository has already been renamed once: the `osx-auth-qr` name it was first
/// pushed under is gone, and a second copy of that string is a second thing to miss.
enum AppLinks {
    static let repository = URL(string: "https://github.com/sirpooya/AutoConnect")!
    static let issues = URL(string: "https://github.com/sirpooya/AutoConnect/issues")!
}
