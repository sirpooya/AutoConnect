import AppKit

/// Manages the app's activation policy around the few real windows it opens.
///
/// A menu-bar-only app runs as `.accessory`, which cannot take key focus: text fields refuse first
/// responder and sliders do not track. Any real window therefore has to switch the app to
/// `.regular` for its lifetime and switch back afterwards.
///
/// Switching back matters more than it looks. Left in `.regular` with no window open, activating
/// the app makes AppKit open "the app's window" on its behalf, which surfaces the Settings scene
/// as a stray blank panel every time the menu bar icon is clicked.
///
/// The policy is **derived from the windows that actually exist**, not from a counter. An earlier
/// version counted claims and releases, which leaked: opening Settings while it was already open
/// took a second claim that no `onDisappear` ever returned, and the app stayed `.regular` forever.
@MainActor
enum WindowActivation {

    /// Windows this app opens deliberately are titled. The status item's window and the popover
    /// are borderless, so `.titled` cleanly separates "a real window is up" from "the panel is
    /// showing", without matching on private class names.
    private static var realWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    static var hasOpenWindow: Bool { !realWindows.isEmpty }

    /// When `claim` last ran. Some claims come before their window exists (Sparkle's alert, the
    /// camera's permission round trip), so the sweep leaves a recent claim alone.
    private static var lastClaim: ContinuousClock.Instant?

    /// How long a claim may go without a window before the sweep treats it as leaked.
    private static let claimGrace: Duration = .seconds(10)

    /// Call before opening a window. Switches to `.regular` and brings the app forward.
    static func claim() {
        lastClaim = .now
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Call when a window closes. Re-derives the policy from what is left on screen.
    ///
    /// Deferred by one turn of the run loop because a closing window is still in `NSApp.windows`
    /// while `windowWillClose` and SwiftUI's `onDisappear` run.
    static func release() {
        Task { @MainActor in
            evaluate()
        }
    }

    /// Sets the policy to match reality. Safe to call at any time.
    static func evaluate() {
        NSApp.setActivationPolicy(hasOpenWindow ? .regular : .accessory)
    }

    /// Drops a Dock icon that no window accounts for.
    ///
    /// Restoring the policy on window close alone missed a case: the app was found `.regular`,
    /// with a Dock icon, for hours after a session renewal's sign-in window had gone, and nothing
    /// re-derived the policy until some other window closed. This only ever demotes, and never
    /// within `claimGrace` of a claim, so a window about to open is not made unfocusable.
    static func sweep() {
        guard NSApp.activationPolicy() == .regular, !hasOpenWindow else { return }
        if let lastClaim, ContinuousClock.now - lastClaim < claimGrace { return }
        DiagnosticLog.write("activation: regular with no window open, back to accessory")
        NSApp.setActivationPolicy(.accessory)
    }

    /// Watches for any window closing, so the policy is restored even for windows this app did not
    /// open through `claim` (Settings opened with Cmd+comma, for instance), and sweeps on a timer
    /// and whenever the app loses focus for the cases a close never reports.
    static func startObserving() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { release() }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { sweep() }
        }

        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { sweep() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
    }
}
