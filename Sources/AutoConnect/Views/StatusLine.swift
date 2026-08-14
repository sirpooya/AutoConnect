import SwiftUI

/// The VPN status text: a highlight travelling across the words, and a new status arriving from
/// below rather than replacing the old one in place.
///
/// Both effects exist to make a slow, silent sequence legible. A connect takes seconds and passes
/// through four states, and static text that swaps character-for-character gives no sign that
/// anything is progressing.
struct StatusLine: View {
    let text: String

    /// Whether the highlight is travelling. Off leaves the text plain, for the states where
    /// nothing is happening and a moving highlight would only draw the eye.
    var isShimmering: Bool = true

    private var params: VPNStatusParams { VPNStatusParams.shared }

    var body: some View {
        ShimmerText(
            text: text,
            isShimmering: isShimmering,
            period: params.shimmerPeriod,
            intensity: params.shimmerIntensity
        )
        // A new status is a new view, so it can transition in while the old one leaves.
        .id(text)
        .transition(.push(from: .bottom))
        // Fixed height and clipping: the two lines overlap during the push, and without this the
        // block would grow by a line and shove everything below it down.
        .frame(height: 14, alignment: .leading)
        .clipped()
        .animation(.easeInOut(duration: params.statusSlideDuration), value: text)
    }
}

/// Text with a soft highlight sweeping across it, left to right, forever.
///
/// The highlight is a gradient masked by the text itself, so it lights up the glyphs rather than a
/// rectangle behind them.
struct ShimmerText: View {
    let text: String
    var isShimmering: Bool
    /// Seconds for one pass. Also the pause, since the sweep is one third of the cycle.
    var period: Double
    /// How bright the highlight gets, 0 to 1.
    var intensity: Double

    /// Travel position, in multiples of the text width. Runs from before the first glyph to past
    /// the last one.
    @State private var travel: CGFloat = -1

    var body: some View {
        base
            .overlay { if isShimmering, intensity > 0 { highlight } }
            .onAppear { startIfNeeded() }
            .onChange(of: isShimmering) { startIfNeeded() }
    }

    private var base: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var highlight: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .primary.opacity(intensity), location: 0.5),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            // Narrow enough to read as a glint rather than a fade of the whole line.
            .frame(width: max(width * 0.45, 24))
            .offset(x: travel * (width + width * 0.45))
        }
        // Masked by the same text, so only the glyphs light up.
        .mask(base)
        .allowsHitTesting(false)
    }

    private func startIfNeeded() {
        guard isShimmering, intensity > 0 else { return }

        // Reset without animating, or the highlight slides backwards to the start.
        travel = -1
        withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
            travel = 1
        }
    }
}
