import XCTest
@testable import AutoConnectCore

final class IssueReportTests: XCTestCase {

    func testBodyCarriesTheVersionTheSystemAndTheLog() {
        let body = IssueReport.body(version: "1.6.1 (12)", system: "macOS 26.5.1", log: "a line")

        XCTAssertTrue(body.contains("1.6.1 (12)"))
        XCTAssertTrue(body.contains("macOS 26.5.1"))
        XCTAssertTrue(body.contains("a line"))
    }

    /// An empty log is a fact about the install, not a blank space to leave someone guessing at.
    func testEmptyLogSaysSoRatherThanLeavingAGap() {
        let body = IssueReport.body(version: "1.6.1", system: "macOS 26", log: "   \n  ")
        XCTAssertTrue(body.contains("the log is empty"))
    }

    func testTailReturnsTheWholeLogWhenItFits() {
        XCTAssertEqual(IssueReport.tail(of: "short", limit: 100), "short")
    }

    /// The end of a log is where the failure is, so the front is what gets dropped, and it is
    /// dropped at a line boundary rather than mid-line.
    func testTailKeepsTheEndAndCutsOnALineBoundary() {
        let log = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let tail = IssueReport.tail(of: log, limit: 40)

        XCTAssertTrue(tail.hasSuffix("line 50"))
        XCTAssertTrue(tail.contains("earlier characters omitted"))
        // Whatever survived, it starts with a whole line rather than a fragment of one.
        let firstLogLine = tail.split(separator: "\n").dropFirst().first ?? ""
        XCTAssertTrue(firstLogLine.hasPrefix("line "), "got \(firstLogLine)")
    }

    /// The log is what gets trimmed, never the finished body: trimming the body would take the
    /// version header off the top and leave the code fence unclosed.
    func testURLTrimsTheLogAndKeepsTheHeader() throws {
        let url = try XCTUnwrap(
            IssueReport.url(
                issues: URL(string: "https://github.com/example/app/issues")!,
                title: "Cannot connect",
                version: "1.6.1 (12)",
                system: "macOS 26.5.1",
                log: String(repeating: "noise\n", count: 4000)
            )
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let body = try XCTUnwrap(
            components.queryItems?.first(where: { $0.name == "body" })?.value
        )

        XCTAssertEqual(components.path, "/example/app/issues/new")
        XCTAssertTrue(body.contains("1.6.1 (12)"), "the header must survive the trim")
        XCTAssertTrue(body.contains("macOS 26.5.1"))
        // The fence still closes, which is the failure the trim order exists to prevent.
        XCTAssertEqual(body.components(separatedBy: "```").count - 1, 2)
        XCTAssertLessThanOrEqual(body.count, IssueReport.urlBodyLimit)
    }
}
