import XCTest
@testable import AutoConnectCore

final class BoundedProcessTests: XCTestCase {

    func testCapturesOutputAndStatus() throws {
        let result = try XCTUnwrap(
            BoundedProcess.run("/bin/echo", ["hello"], capture: .standardOutput)
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.text, "hello\n")
    }

    func testReportsFailureStatus() throws {
        let result = try XCTUnwrap(BoundedProcess.run("/usr/bin/false", []))
        XCTAssertNotEqual(result.status, 0)
    }

    func testMissingToolIsNil() {
        XCTAssertNil(BoundedProcess.run("/nonexistent/tool", []))
    }

    /// The case that froze the app: a tool that never exits. The caller must get control back at
    /// the deadline, and the tool must not be left running.
    func testToolThatNeverExitsIsStoppedAtTheDeadline() {
        let started = Date()
        XCTAssertNil(BoundedProcess.run("/bin/sleep", ["30"], timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// More output than a pipe buffer holds, so a reader that only starts after exit would deadlock.
    func testDrainsLargeOutputWhileRunning() throws {
        let result = try XCTUnwrap(
            BoundedProcess.run(
                "/bin/sh", ["-c", "head -c 1000000 /dev/zero"], capture: .standardOutput
            )
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 1_000_000)
    }
}
