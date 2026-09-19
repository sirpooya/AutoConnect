import AppKit
import AutoConnectCore
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
        // Repeated per attempt rather than written once at launch. A log is read from the end,
        // and a header scrolled off the top by twenty retries is a header nobody sees.
        write("app \(versionText) on \(systemText)")
    }

    // MARK: - Handing it over

    /// What the log currently holds.
    ///
    /// Writes are queued, so a read taken the moment a failure appears on screen would miss the
    /// line that explains it. Draining the queue first is most of the point of reading at all.
    static func contents() -> String {
        queue.sync {}
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// `1.6.1 (12)`, or a plain statement that this is not a release build. Separate from
    /// About's version string, which is written to be read in a window rather than pasted into
    /// an issue.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        switch (short, build) {
        case let (.some(short), .some(build)): return "\(short) (\(build))"
        case let (.some(short), .none): return short
        default: return "unpackaged build"
        }
    }

    static var systemText: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// The whole report as text, for the clipboard.
    static func report() -> String {
        IssueReport.body(version: versionText, system: systemText, log: contents())
    }

    /// Puts the report on the clipboard. Returns nothing to say: the button says "Copied".
    static func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(), forType: .string)
    }

    /// A GitHub issue with the report already in it, or the plain issues page when the URL could
    /// not be built. Never fails closed: the point is to get the user somewhere they can report.
    static func issueURL() -> URL {
        IssueReport.url(
            issues: AppLinks.issues,
            title: "Cannot connect",
            version: versionText,
            system: systemText,
            log: contents()
        ) ?? AppLinks.issues
    }
}
