import Foundation

/// Append-only log of what a connect attempt actually did.
///
/// A menu bar app has nowhere to print, so a failed connect leaves no trace beyond one line of
/// status text. That is not enough to tell "the sign-in was cancelled" apart from "the token was
/// never captured", which look identical from the outside and have completely different fixes.
///
/// **Never logs a secret.** Cookie values, passwords, one-time codes and session tokens are
/// recorded by name and length only. URLs are reduced to host and path, since identity providers
/// routinely carry tokens in the query string.
enum DiagnosticLog {

    static let fileURL: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("AutoConnect.log")
    }()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let queue = DispatchQueue(label: "autoconnect.diagnostics")

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"

        queue.async {
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Host and path only. Query strings from an identity provider carry tokens.
    static func redact(_ url: URL?) -> String {
        guard let url else { return "(no url)" }
        return "\(url.host ?? "?")\(url.path)"
    }

    /// Describes a secret without revealing it.
    static func describe(secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return "empty" }
        return "\(secret.count) chars"
    }

    static func startSession() {
        write("---- connect attempt ----")
    }
}
