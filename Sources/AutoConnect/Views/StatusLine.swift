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
///
/// Pacing is not done here. `VPNSection` paces the phase itself, so the dot, the status and the
/// connected block move together; pacing the string alone put a green dot beside "Waiting for
/// sign-in".
struct StatusLine: View {
    let text: String

    /// Whether the highlight is travelling. Off leaves the text plain, for the states where
    /// nothing is happening and a moving highlight would only draw the eye.
    var isShimmering: Bool = true

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
                text: text,
                isShimmering: isShimmering,
                period: params.shimmerPeriod,
                intensity: params.shimmerIntensity,
                length: params.shimmerLength
            )
            .id(text)
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
        .animation(slide, value: text)
    }
}

/// Paces a value so each one is shown for a minimum time, however fast they really change.
///
/// The phases do not wait for the animation: a gateway that answers quickly can move through two
/// states in well under a second, which flashes a status past unread and leaves no time for the
/// shimmer to travel. Values are queued and released no faster than the floor, and the queue
/// always drains, so the row still ends on the truth.
@MainActor
@Observable
final class StatusPacer<Value: Equatable> {
    /// What is on screen. Nil until the first value arrives.
    private(set) var shown: Value?

    /// When it went up. The dwell is measured from here, not from the moment the next value is
    /// submitted: timed from submission, a status that had already been up for a minute still held
    /// the next one back for the full dwell, so clicking Connect sat on "Not connected" and the
    /// knob read as a delay rather than a floor.
    private var shownAt: Date?

    private var pending: [Value] = []
    private var drain: Task<Void, Never>?

    /// Wraps every change of `shown` so the whole update runs inside one animated transaction.
    ///
    /// An `.animation(_:value:)` on the row was not enough, which is what made the resize knobs look
    /// dead at every setting: the modifier animates what that view draws, but the height the row
    /// reports to its parent, and the panel and popover sizing themselves off it, are laid out
    /// outside it. Animating at the mutation carries the ancestors with it.
    private var animation: Animation?

    func submit(
        _ value: Value,
        minimumDwell: Double,
        immediately: Bool = false,
        animation: Animation? = nil
    ) {
        self.animation = animation

        // Checked before the duplicate guard below, not after: disconnecting mid-connect submits a
        // value that may already be on screen, and that must still throw away the progress states
        // queued behind it rather than letting them drain over a tunnel that is gone.
        if immediately {
            pending.removeAll()
            drain?.cancel()
            drain = nil
            show(value)
            return
        }

        guard value != pending.last else { return }

        // Nothing queued and nothing to change: drop it rather than re-showing what is already up.
        //
        // This one cost a visible delay. `onAppear` resubmits the phase every time the panel opens,
        // and re-showing an unchanged value restarted the dwell clock, so a click on Connect landed
        // on a status that had just been "shown" and waited the full dwell before "Contacting
        // gateway" appeared. With a queue behind it the same value is meaningful, since a sequence
        // can pass back through the state on screen.
        if pending.isEmpty, value == shown { return }

        guard shown != nil else {
            // First value of the session appears at once; there is nothing to hold on to.
            show(value)
            return
        }

        pending.append(value)
        startDraining(minimumDwell: minimumDwell)
    }

    private func startDraining(minimumDwell: Double) {
        guard drain == nil else { return }

        drain = Task { [weak self] in
            while let self, let next = pending.first {
                // Only the part of the dwell the current value has not served yet, so every one
                // gets the same floor whether it arrived in a burst or on its own.
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

    private func show(_ value: Value) {
        withAnimation(animation) { shown = value }
        shownAt = Date()
    }
}

/// Text whose glyphs are filled by a gradient travelling across them, the way Cursor's "Generating"
/// label reads.
///
/// The gradient **is** the text colour, rather than a bright band drawn over grey text. That is the
/// difference between the two looks: an overlay adds light and haloes the whole line, while a fill
/// ramps dim to bright and back, so the peak reads as a highlight passing over words that are grey
/// again behind it. The ramp is wide and the loop seamless, with no pause at either end.
struct ShimmerText: View {
    let text: String
    var isShimmering: Bool
    /// Seconds for one pass of the highlight.
    var period: Double
    /// How bright the peak gets, 0 to 1. Zero leaves the text plain.
    var intensity: Double
    /// How long the highlight itself is, as a multiple of the line's width. 1 means the ramp from
    /// grey up to the peak and back spans exactly the words; below that it is a glint on a few
    /// letters, above it the whole line brightens and dims together.
    var length: Double = 1.5

    var body: some View {
        if isShimmering, intensity > 0, period > 0 {
            // Sized by the plain text, then painted by the gradient: the glyphs are the mask, so
            // layout cannot depend on the animation.
            base.hidden().overlay { fill }
        } else {
            base
        }
    }

    private var base: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// The same glyphs at full opacity, for masking. Masking the `.secondary` copy would multiply
    /// its alpha into the gradient and wash the peak out.
    private var glyphs: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.black)
            .lineLimit(1)
            .fixedSize()
    }

    /// Driven by the clock, not by an animated `@State`.
    ///
    /// The travel used to be a state variable set inside `withAnimation(.repeatForever)` from
    /// `onAppear`. `StatusLine` puts an `.animation(slide, value:)` above this view, and an ancestor
    /// `.animation` re-applies its own curve to descendant changes: the repeat was replaced by a
    /// single 0.2s slide, so the highlight crossed once as a status changed and was never seen
    /// again. A clock cannot be overridden.
    private var fill: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            // One glint every two and a half line-widths: a highlight crosses, then the words sit
            // grey for a moment before the next. Spacing them tighter reads as stripes.
            let tile = width * 2.5
            // Capped below the spacing, not clamped to it: a ramp as long as its own tile leaves no
            // grey between passes, and the line just breathes instead of a highlight travelling.
            let band = min(width * length, tile * 0.9)

            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                let progress = elapsed.truncatingRemainder(dividingBy: period) / period

                // Leading-aligned by construction. `frame(width:)` alone centres the gradient in
                // the line's own width, which is what broke the first version: offsets written for
                // a left edge pushed the rect off the text, and glyphs with no gradient behind them
                // did not dim, they disappeared.
                HStack(spacing: 0) {
                    LinearGradient(
                        stops: stops(half: (band / 2) / (tile * 2)),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: tile * 2)

                    Spacer(minLength: 0)
                }
                // Travels exactly one tile per period. The second tile arrives where the first
                // began, so the wrap is invisible; a single tile would snap back with the highlight
                // still on screen.
                .offset(x: -tile * (1 - progress))
            }
        }
        .mask(glyphs)
        .allowsHitTesting(false)
    }

    /// Two identical dim → bright → dim ramps, so the pattern repeats with a period of one tile.
    ///
    /// `half` is the rise from grey to the peak, as a fraction of the whole two-tile gradient, so
    /// the highlight spans `2 * half` and the rest of each tile stays grey.
    ///
    /// The floor is well below `.secondary`, the colour a settled status uses. Measured against the
    /// first version, which ramped from `.secondary` up: the darkest glyph pixel moved by 0.06 over
    /// a whole pass, which is a real sweep that nobody can see. Shimmering text being dimmer
    /// overall than static text is the point, in Cursor too: the motion carries it, not the weight.
    private func stops(half: Double) -> [Gradient.Stop] {
        let dim = Color.primary.opacity(0.3)
        let peak = Color.primary.opacity(min(1, 0.45 + 0.55 * intensity))

        return [
            .init(color: dim, location: 0),
            .init(color: peak, location: half),
            .init(color: dim, location: 2 * half),
            .init(color: dim, location: 0.5),
            .init(color: peak, location: 0.5 + half),
            .init(color: dim, location: 0.5 + 2 * half),
            .init(color: dim, location: 1),
        ]
    }
}
