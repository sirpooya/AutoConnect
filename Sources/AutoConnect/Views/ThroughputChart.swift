import AutoConnectCore
import SwiftUI

/// Throughput over the last couple of minutes: download as a filled area, upload as a line on
/// the same axis.
///
/// Both series share one scale, because the question being asked is "which direction is busy, and
/// how busy" — two independent axes would make a trickle of upload look like a flood. The scale is
/// the window's own peak, so an idle tunnel reads as flat rather than as noise amplified to fill
/// the frame.
struct ThroughputChart: View {
    let samples: [VPNController.ThroughputSample]

    /// Floor for the scale, so tiny keepalive traffic does not get magnified into mountains.
    private let minimumPeak: Double = 50_000

    private var peak: Double {
        max(minimumPeak, samples.flatMap { [$0.down, $0.up] }.max() ?? minimumPeak)
    }

    var body: some View {
        ZStack {
            if samples.count < 2 {
                Text("Sampling...")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            } else {
                GeometryReader { geometry in
                    let size = geometry.size

                    // Download: filled area, since it is the dominant direction in practice.
                    path(in: size, value: \.down, closed: true)
                        .fill(
                            LinearGradient(
                                colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    path(in: size, value: \.down, closed: false)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

                    // Upload: line only, so it stays readable on top of the filled area.
                    path(in: size, value: \.up, closed: false)
                        .stroke(
                            Color.orange.opacity(0.9),
                            style: StrokeStyle(lineWidth: 1, lineJoin: .round)
                        )
                }
            }
        }
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
        .overlay(alignment: .topTrailing) {
            Text(scaleLabel)
                .font(.system(size: 7))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(3)
        }
        .overlay(alignment: .bottomLeading) {
            legend
                .padding(3)
        }
        .accessibilityLabel("Throughput chart, peak \(scaleLabel)")
    }

    private var scaleLabel: String {
        TunnelStats.formatRate(peak)
    }

    private var legend: some View {
        HStack(spacing: 6) {
            legendItem("down", color: .accentColor)
            legendItem("up", color: .orange)
        }
    }

    private func legendItem(_ label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 6, height: 2)
            Text(label)
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
        }
    }

    /// Builds the polyline for one series. `closed` adds the baseline so it can be filled.
    private func path(
        in size: CGSize,
        value: KeyPath<VPNController.ThroughputSample, Double>,
        closed: Bool
    ) -> Path {
        var path = Path()
        guard samples.count > 1, size.width > 0 else { return path }

        let step = size.width / CGFloat(samples.count - 1)
        // Inset the top so a peak's stroke is not clipped by the frame edge.
        let usableHeight = size.height - 2

        func point(_ index: Int) -> CGPoint {
            let fraction = min(1, samples[index][keyPath: value] / peak)
            return CGPoint(
                x: CGFloat(index) * step,
                y: 1 + usableHeight * (1 - fraction)
            )
        }

        path.move(to: point(0))
        for index in 1..<samples.count {
            path.addLine(to: point(index))
        }

        if closed {
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }

        return path
    }
}
