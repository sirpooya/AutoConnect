import Foundation

/// Turns a diagnostic log into something a user can hand over.
///
/// A failed connect is nearly always one of a handful of settled causes, and every one of them
/// is already named in `~/Library/Logs/AutoConnect.log`. The gap was never the log; it was that
/// nobody knew it existed, so a report arrived as "it doesn't work" and the round trip to find
/// out which of the handful it was took days. This builds the two things that close that gap:
/// the text to paste, and a GitHub issue already carrying it.
///
/// Pure and here rather than in the view for the usual reason: the truncation has an off-by-one
/// in it waiting to happen, and the log must not be the part of a report that gets cut.
public enum IssueReport {

    /// How much of the log a prefilled issue URL can carry.
    ///
    /// GitHub itself accepts a long query string, but the whole URL travels through the browser
    /// and its history, and past roughly 8k it is silently refused with no error anyone can act
    /// on. The body is trimmed to fit rather than the URL being sent to fail, and the log is
    /// trimmed from the front, because the end of a log is where the failure is.
    public static let urlBodyLimit = 6000

    /// The report as text: what is running, then what it did. The copy button puts exactly this
    /// on the clipboard, so a report pasted into chat and one opened as an issue say the same
    /// thing.
    public static func body(version: String, system: String, log: String) -> String {
        let trimmed = log.trimmingCharacters(in: .whitespacesAndNewlines)
        let contents = trimmed.isEmpty
            ? "(the log is empty: no connect has been attempted since it was last cleared)"
            : trimmed

        return """
            **AutoConnect** \(version)
            **macOS** \(system)

            <!-- What were you doing, and what did you expect to happen? -->

            ### Log

            ```
            \(contents)
            ```
            """
    }

    /// The last `limit` characters, cut at a line boundary so a report never opens mid-line.
    ///
    /// Returns the whole thing when it already fits, and says how much was dropped when it does
    /// not, since a log that starts abruptly otherwise reads as a log that lost its beginning to
    /// a bug.
    public static func tail(of log: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard log.count > limit else { return log }

        let cut = log.suffix(limit)
        // The first line is now a fragment of whichever line the cut landed in.
        let whole = cut.firstIndex(of: "\n").map { cut[cut.index(after: $0)...] } ?? cut
        let dropped = log.count - whole.count

        return "[\(dropped) earlier characters omitted]\n" + whole
    }

    /// A GitHub issue with the report already in it.
    ///
    /// `issues` is the repository's issues URL. The **log** is what gets trimmed to fit, not the
    /// finished body: trimming the body would take the version header off the top and leave the
    /// code fence unclosed, so the report would arrive both anonymous and malformed.
    public static func url(
        issues: URL,
        title: String,
        version: String,
        system: String,
        log: String
    ) -> URL? {
        // What the body costs before any log goes into it, so the log is given exactly the room
        // that is left rather than a guess that has to be kept in step with the template.
        let overhead = body(version: version, system: system, log: "").count
        let room = urlBodyLimit - overhead

        var components = URLComponents(url: issues, resolvingAgainstBaseURL: false)
        components?.path += "/new"
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(
                name: "body",
                value: body(
                    version: version,
                    system: system,
                    log: tail(of: log, limit: room)
                )
            ),
        ]
        return components?.url
    }
}
