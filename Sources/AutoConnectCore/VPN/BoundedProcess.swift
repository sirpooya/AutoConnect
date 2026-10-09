import Foundation

/// Runs a short-lived system tool to completion, but never waits on it past a deadline.
///
/// `waitUntilExit` and `readDataToEndOfFile` wait as long as the tool does, and a tool can wait
/// forever. `route -n get` reads the routing socket until its own reply arrives, and a reply lost
/// among a burst of route changes (which is what openconnect's teardown produces) never does. Run
/// from the main thread during a session renewal, that froze the whole app for fifteen minutes.
/// Every tool the app runs and waits for goes through here, so the worst case is the deadline.
public enum BoundedProcess {
    public struct Result: Sendable {
        public let status: Int32
        public let output: Data

        public var text: String? { String(data: output, encoding: .utf8) }
    }

    public enum Capture: Sendable {
        case nothing
        case standardOutput
        case standardOutputAndError
    }

    public static let defaultTimeout: TimeInterval = 5

    /// Nil when the tool could not be launched, or overran the deadline and was stopped.
    public static func run(
        _ path: String,
        _ arguments: [String],
        capture: Capture = .nothing,
        timeout: TimeInterval = defaultTimeout
    ) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe: Pipe?
        switch capture {
        case .nothing:
            pipe = nil
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .standardOutput:
            pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
        case .standardOutputAndError:
            pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
        }

        // Signalled from Foundation's own queue, so waiting on it never depends on the run loop of
        // the thread that is waiting, and nothing else runs re-entrantly while it waits.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drained off the waiting thread, or a tool that fills the pipe buffer blocks on its write
        // and never exits.
        let collected = Collected()
        let drained = DispatchSemaphore(value: 0)
        if let pipe {
            DispatchQueue.global(qos: .utility).async {
                collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
                drained.signal()
            }
        } else {
            drained.signal()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            stop(process, exited: exited)
            return nil
        }

        // The tool is gone, so its output is complete unless something it spawned still holds the
        // pipe open. Give that a moment rather than another unbounded wait.
        guard drained.wait(timeout: .now() + 1) == .success else { return nil }

        return Result(status: process.terminationStatus, output: collected.data)
    }

    /// Asks politely, then insists. sudo relays the first signal to the command it is running.
    private static func stop(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// Written once by the reader, read once after the reader signals, so the semaphore orders them.
private final class Collected: @unchecked Sendable {
    var data = Data()
}
