import SwiftUI

/// The VPN status text: a highlight travelling across the words while something is happening, and
/// a new status arriving from below as the old one leaves through the top.
///
/// Both effects exist to make a slow, silent sequence legible. A connect takes seconds and passes
/// through four states, and text that swaps character-for-character gives no sign of progress.
///
/// Ported from the `StatusText` component in iconkit-app: the two layers cross-fade as they slide,
/// always bottom to top, on a 300ms standard-easing curve, and the loading state runs a gradient
/// clipped to the glyphs rather than a band drawn over them.
struct StatusLine: View {
    let text: String

    /// Whether the highlight is travelling. Off leaves the text plain, for the states where
    /// nothing is happening and a moving highlight would only draw the eye.
    var isShimmering: Bool = true

    /// Whether this status ends the sequence rather than being a step in it. End states skip the
    /// queue: a click on Disconnect has to be answered at once, and a failure that waits its turn
    /// behind three progress steps is a failure nobody sees.
    var isFinal: Bool = false

    /// Holds each status on screen long enough to be read, however fast the phases move.
    @State private var pacer = StatusPacer()

    private var params: VPNStatusParams { VPNStatusParams.shared }

    /// Material's standard curve, the one the reference component uses.
    private var slide: Animation {
        .timingCurve(0.4, 0, 0.2, 1, duration: params.statusSlideDuration)
    }

    var body: some View {
        // A ZStack, not a VStack: the outgoing and incoming lines overlap during the slide, and
        // stacked layout would reserve room for both and jog the panel.
        ZStack(alignment: .leading) {
            ShimmerText(
                text: pacer.shown,
                isShimmering: isShimmering,
                period: params.shimmerPeriod,
                intensity: params.shimmerIntensity
            )
            .id(pacer.shown)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                )
            )
        }
        // Fixed height and clipping, so a line mid-slide cannot be seen above or below its slot.
        .frame(height: 14, alignment: .leading)
        .clipped()
        .animation(slide, value: pacer.shown)
        .onAppear {
            pacer.submit(text, minimumDwell: params.statusMinimumDwell, immediately: isFinal)
        }
        .onChange(of: text) {
            pacer.submit(text, minimumDwell: params.statusMinimumDwell, immediately: isFinal)
        }
    }
}

/// Paces the status line so every status is shown for a minimum time.
///
/// The real phases do not wait for the animation: a gateway that answers quickly can move through
/// two states in well under a second, which would flash a status past unread and leave no time for
/// the shimmer to travel. Statuses are queued and released no faster than the floor, and the queue
/// always drains, so the line still ends on the truth.
@MainActor
@Observable
final class StatusPacer {
    /// The status currently on screen.
    private(set) var shown: String = ""

    /// When it went up. The dwell is measured from here, not from the moment a new status is
    /// submitted: timed from submission, a status that had already been on screen for a minute
    /// still held the next one back for the full dwell, so clicking Connect sat on "Not connected"
    /// and the knob read as a delay rather than a floor.
    private var shownAt: Date?

    private var pending: [String] = []
    private var drain: Task<Void, Never>?

    func submit(_ text: String, minimumDwell: Double, immediately: Bool = false) {
        // Checked before the duplicate guard below, not after: disconnecting mid-connect sets the
        // text back to one that is already on screen, and that must still throw away the progress
        // statuses queued behind it rather than letting them drain over a tunnel that is gone.
        if immediately {
            pending.removeAll()
            drain?.cancel()
            drain = nil
            show(text)
            return
        }

        guard text != pending.last, text != shown || pending.isEmpty else { return }

        if shown.isEmpty {
            // First status of the session appears at once; there is nothing to hold on to.
            show(text)
            return
        }

        pending.append(text)
        startDraining(minimumDwell: minimumDwell)
    }

    private func startDraining(minimumDwell: Double) {
        guard drain == nil else { return }

        drain = Task { [weak self] in
            while let self, let next = pending.first {
                // Only the part of the dwell the current status has not served yet. Every status
                // therefore gets the same floor, whether it arrived in a burst or on its own.
                let elapsed = shownAt.map { Date().timeIntervalSince($0) } ?? minimumDwell
                let remaining = minimumDwell - elapsed

                if remaining > 0 {
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { break }
                }

                pending.removeFirst()
                show(next)
            }
            self?.drain = nil
        }
    }

    private func show(_ text: String) {
        shown = text
        shownAt = Date()
    }
}

/// Text filled with a gradient that travels across it, so the glyphs themselves light up.
struct ShimmerText: View {
    let text: String
    var isShimmering: Bool
    /// Seconds for one pass of the highlight.
    var period: Double
    /// How bright the highlight gets, 0 to 1. Zero leaves the text plain.
    var intensity: Double

    /// Travel position, as a multiple of the text width.
    @State private var travel: CGFloat = -1

    var body: some View {
        base
            .overlay { if isShimmering, intensity > 0 { highlight } }
            .onAppear { start() }
            .onChange(of: isShimmering) { start() }
    }

    private var base: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var highlight: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            // A band roughly half the line, so it reads as a glint rather than the whole line
            // brightening and dimming.
            let band = max(width * 0.45, 24)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .primary.opacity(intensity), location: 0.5),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band)
            .offset(x: travel * (width + band))
        }
        // Clipped to the text, the equivalent of the reference's background-clip: text.
        .mask(base)
        .allowsHitTesting(false)
    }

    private func start() {
        guard isShimmering, intensity > 0 else { return }

        // Reset unanimated first, or the band slides backwards to the start position.
        travel = -1
        withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
            travel = 1
        }
    }
}
