import AppKit

/// Manages the app's activation policy around the few windows it opens.
///
/// A menu-bar-only app runs as `.accessory`, which cannot take key focus: text fields refuse
/// first responder and sliders do not track. So any real window has to switch the app to
/// `.regular` for its lifetime and switch back afterwards.
///
/// Switching back matters more than it looks. Left in `.regular` with no window open,
/// `NSApp.activate` makes AppKit reopen "the app's window", which surfaces the Settings scene as
/// a blank panel every time the menu bar icon is clicked.
///
/// Claims are counted, so two windows open at once cannot drop the policy early.
@MainActor
enum WindowActivation {
    private static var claims = 0

    /// Take a claim and bring the app forward. Pair with `release()`.
    static func claim() {
        claims += 1
        if claims == 1 {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func release() {
        guard claims > 0 else { return }
        claims -= 1
        if claims == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// True while a window still holds a claim. The status item consults this before activating,
    /// so an accessory app never asks AppKit to conjure a window.
    static var hasOpenWindow: Bool { claims > 0 }
}
