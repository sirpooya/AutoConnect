import Foundation

/// The two things a user has to do by hand before a tunnel can come up, expressed as commands
/// they can copy rather than as prose pointing somewhere else.
///
/// "See the README" is a dead end for anyone who downloaded the app: there is no README beside
/// it. So both setup steps live here as an exact line, and both are built from the same constants
/// `OpenConnectRunner` launches with, so a sudo rule the user pastes cannot drift from the process
/// it has to cover.
public enum SetupCommands {

    // MARK: - Installing openconnect

    /// Where Homebrew puts its own binary, Apple Silicon first, then Intel.
    public static let homebrewCandidates = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    /// Whether Homebrew is on this machine at all, which decides which advice is true.
    public static func homebrewPath(
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        homebrewCandidates.first(where: exists)
    }

    /// What to say when openconnect is missing, and the one thing to do about it.
    public struct InstallAdvice: Equatable {
        /// One or two sentences, shown under the card.
        public let message: String
        /// The line to copy, or nil when the next step is not a command.
        public let command: String?
        /// Where to send someone who has no command to run.
        public let link: URL?
    }

    /// Two cases, because their first step differs. With Homebrew present there is a command that
    /// works; without it the same command fails with "brew: command not found", which reads as the
    /// app being wrong rather than as a missing package manager.
    public static func openconnectInstall(homebrewInstalled: Bool) -> InstallAdvice {
        if homebrewInstalled {
            return InstallAdvice(
                message: """
                    openconnect is not installed. Copy the command, run it in Terminal, and this \
                    row goes away. If you already have openconnect elsewhere, use Locate instead.
                    """,
                command: "brew install openconnect",
                link: nil
            )
        }

        return InstallAdvice(
            message: """
                openconnect is not installed, and neither is Homebrew, which is where it comes \
                from. Install Homebrew first, then run: brew install openconnect.
                """,
            command: nil,
            link: URL(string: "https://brew.sh")
        )
    }

    // MARK: - The sudo rule

    /// A drop-in rather than an edit of `/etc/sudoers`: one file this app owns can be reviewed and
    /// deleted on its own.
    public static let sudoersFile = "/etc/sudoers.d/autoconnect"

    /// Written here first so a malformed rule can be checked before it counts. sudo ignores any
    /// filename in `sudoers.d` containing a dot, which is what makes this staging path inert.
    static let sudoersStagingFile = sudoersFile + ".tmp"

    /// The rule itself: root for the tunnel binary and for the one signal that stops it.
    ///
    /// Both commands come from `OpenConnectRunner`, so a rule copied out of Settings covers
    /// exactly what the app runs, including the pid-file marker that keeps shutdown off any
    /// openconnect the user started themselves.
    public static func sudoersRule(user: String, binaryPath: String) -> String {
        let shutdown = OpenConnectRunner.shutdownArguments().joined(separator: " ")
        return "\(sanitized(user)) ALL=(root) NOPASSWD: \(sanitized(binaryPath)), \(shutdown)"
    }

    /// One line to paste in Terminal.
    ///
    /// It stages, validates with `visudo -c`, then moves into place. A broken file in `sudoers.d`
    /// breaks sudo for everything on the machine, not just this app, so the check is not optional.
    public static func sudoersInstallCommand(user: String, binaryPath: String) -> String {
        let rule = sudoersRule(user: user, binaryPath: binaryPath)
        return "sudo sh -c 'echo \"\(rule)\" > \(sudoersStagingFile)"
            + " && visudo -cf \(sudoersStagingFile)"
            + " && chmod 440 \(sudoersStagingFile)"
            + " && mv \(sudoersStagingFile) \(sudoersFile)'"
    }

    /// Removing it again, which belongs next to installing it.
    public static var sudoersRemoveCommand: String {
        "sudo rm \(sudoersFile)"
    }

    /// Quotes and newlines cannot survive into a shell line the user is told to trust.
    ///
    /// A user name comes from the system and a path from a file picker, so neither is expected to
    /// contain any of these. Stripping them anyway keeps the worst case a command that fails
    /// rather than a command that runs something else.
    private static func sanitized(_ value: String) -> String {
        value.filter { !"'\"\\\n\r`$".contains($0) }
    }
}
