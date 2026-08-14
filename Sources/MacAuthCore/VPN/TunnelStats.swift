import Foundation

/// Traffic counters for a tunnel interface.
///
/// openconnect has no stats option, so the numbers come from the kernel's own interface counters
/// via `netstat -ibn`. That has a useful side effect: the figures stay correct even if openconnect
/// says nothing for hours.
public struct TunnelStats: Equatable, Sendable {

    /// Cumulative bytes received on the interface since it came up.
    public var bytesIn: UInt64
    /// Cumulative bytes sent.
    public var bytesOut: UInt64
    /// Packet counts, which AnyConnect labels "Frames".
    public var packetsIn: UInt64
    public var packetsOut: UInt64
    /// Bytes per second, averaged over the gap between the last two samples.
    public var rateIn: Double
    public var rateOut: Double
    public var mtu: Int?

    public init(
        bytesIn: UInt64 = 0,
        bytesOut: UInt64 = 0,
        packetsIn: UInt64 = 0,
        packetsOut: UInt64 = 0,
        rateIn: Double = 0,
        rateOut: Double = 0,
        mtu: Int? = nil
    ) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
        self.rateIn = rateIn
        self.rateOut = rateOut
        self.mtu = mtu
    }

    // MARK: - Parsing

    /// Reads counters out of `netstat -ibn -I <interface>` output.
    ///
    /// The interface's `<Link#n>` row is the one to use: the per-address rows repeat the same
    /// totals and print `-` in the error columns, and their extra Address field shifts every
    /// column right, so counting from the left only works on the Link row.
    ///
    ///     Name  Mtu  Network    Ipkts    Ierrs  Ibytes      Opkts   Oerrs  Obytes     Coll
    ///     utun6 1300 <Link#25>  1739606  0      1148180614  900391  0      813138424  0
    public struct Counters: Equatable {
        public var bytesIn: UInt64
        public var bytesOut: UInt64
        public var packetsIn: UInt64
        public var packetsOut: UInt64
        public var mtu: Int?
    }

    public static func parse(netstatOutput: String, interface: String) -> Counters? {
        for line in netstatOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)

            guard fields.count >= 9,
                  fields[0] == interface,
                  fields.contains(where: { $0.hasPrefix("<Link") })
            else {
                continue
            }

            guard let packetsIn = UInt64(fields[3]),
                  let bytesIn = UInt64(fields[5]),
                  let packetsOut = UInt64(fields[6]),
                  let bytesOut = UInt64(fields[8])
            else {
                continue
            }

            return Counters(
                bytesIn: bytesIn,
                bytesOut: bytesOut,
                packetsIn: packetsIn,
                packetsOut: packetsOut,
                mtu: Int(fields[1])
            )
        }

        return nil
    }

    // MARK: - Formatting

    /// Human byte count: "813 MB", "1.1 GB". Decimal units, matching what macOS shows.
    public static func formatBytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        let units: [(threshold: Double, suffix: String, decimals: Int)] = [
            (1_000_000_000_000, "TB", 1),
            (1_000_000_000, "GB", 1),
            (1_000_000, "MB", 0),
            (1_000, "KB", 0),
        ]

        for unit in units where value >= unit.threshold {
            let scaled = value / unit.threshold
            // Keep a decimal only while the number is small enough for it to mean anything.
            let decimals = scaled < 10 ? unit.decimals : 0
            return "\(String(format: "%.\(decimals)f", scaled)) \(unit.suffix)"
        }

        return "\(bytes) B"
    }

    /// Human rate: "1.2 MB/s".
    public static func formatRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return "0 B/s" }
        return formatBytes(UInt64(bytesPerSecond)) + "/s"
    }

    public var formattedIn: String { Self.formatBytes(bytesIn) }
    public var formattedOut: String { Self.formatBytes(bytesOut) }
    public var formattedRateIn: String { Self.formatRate(rateIn) }
    public var formattedRateOut: String { Self.formatRate(rateOut) }
}

/// Samples interface counters on a timer and turns successive readings into rates.
public final class TunnelStatsReader {

    private var lastSample: (bytesIn: UInt64, bytesOut: UInt64, at: Date)?

    public init() {}

    /// Reads the interface once and folds it into a rate using the previous reading.
    /// Returns nil when the interface does not exist, which is the normal case when disconnected.
    public func sample(interface: String, now: Date = Date()) -> TunnelStats? {
        guard let output = Self.runNetstat(interface: interface),
              let parsed = TunnelStats.parse(netstatOutput: output, interface: interface)
        else {
            lastSample = nil
            return nil
        }

        var stats = TunnelStats(
            bytesIn: parsed.bytesIn,
            bytesOut: parsed.bytesOut,
            packetsIn: parsed.packetsIn,
            packetsOut: parsed.packetsOut,
            mtu: parsed.mtu
        )

        if let previous = lastSample {
            let elapsed = now.timeIntervalSince(previous.at)
            if elapsed > 0.1 {
                // Counters can reset if the interface is recreated, so guard the subtraction.
                let deltaIn = parsed.bytesIn >= previous.bytesIn
                    ? parsed.bytesIn - previous.bytesIn
                    : 0
                let deltaOut = parsed.bytesOut >= previous.bytesOut
                    ? parsed.bytesOut - previous.bytesOut
                    : 0
                stats.rateIn = Double(deltaIn) / elapsed
                stats.rateOut = Double(deltaOut) / elapsed
            }
        }

        lastSample = (parsed.bytesIn, parsed.bytesOut, now)
        return stats
    }

    public func reset() {
        lastSample = nil
    }

    /// Read-only: netstat reports counters and changes nothing.
    private static func runNetstat(interface: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ibn", "-I", interface]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
