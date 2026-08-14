#if DEBUG
import AppKit
import SwiftUI

/// Hosts the VPN status playground in an `NSWindow` this app owns.
///
/// Same reason as `SettingsWindow`: a SwiftUI `Window` scene restores itself at launch, so the
/// playground reappeared on its own after any session that had opened it, and an accessory app
/// cannot raise a restored window because it cannot become active. Owning the window means it
/// appears when `show` is called and never otherwise.
@MainActor
final class PlaygroundWindow: NSObject, NSWindowDelegate {
    static let shared = PlaygroundWindow()

    private var window: NSWindow?

    func show() {
        // A menu-bar-only app is `.accessory` and cannot take key focus, so the sliders would not
        // track the pointer. WindowActivation switches to `.regular` and back on close.
        WindowActivation.claim()

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: VPNStatusPlaygroundView())
        // Size the window explicitly. Letting AppKit measure the SwiftUI content mid-layout is
        // what kills the settings window, and this content scrolls too.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "VPN Status Playground"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1020, height: 660))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        // The policy is restored by WindowActivation's own willClose observer.
        window = nil
    }
}
#endif
