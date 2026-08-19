import Foundation

/// Which openconnect is on this Mac, asked of the binary itself rather than assumed.
///
/// The About pane is where a bug report is put together, and "openconnect 9.12" is half of what
/// this app actually runs: the tunnel behaviour that differs between releases is not the app's.
/// Parsing is separated from spawning so the shapes openconnect prints can be tested without a
/// process, which is the same split `OpenConnectRunner` uses for its output lines.
public enum OpenConnectVersion {

    /// The version out of `openconnect --version`, without the leading `v`.
    ///
    /// The first line is `OpenConnect version v9.12`, and distribution builds append their own
    /// suffix (`v8.20-unknown`), which is kept: it is part of what is installed.
    public static func parse(_ output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let range = line.range(of: "version ") else { continue }
            var token = line[range.upperBound...]
                .split(separator: " ", omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            if token.hasPrefix("v") { token.removeFirst() }
            return token.isEmpty ? nil : token
        }
        return nil
    }

    /// Asks the binary at `path` what it is. Nil when there is nothing executable there, when it
    /// fails, or when it prints something this cannot read.
    ///
    /// `--version` is the one openconnect invocation that touches neither the network nor the
    /// routing table, so it is safe to run while the user's own tunnel is up.
    public static func read(at path: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }
}
