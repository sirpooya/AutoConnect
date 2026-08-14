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
            present(window)
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
        self.window = window
        present(window)
    }

    /// Brings the window up wherever the user actually is.
    ///
    /// `makeKeyAndOrderFront` alone is not enough for an accessory app: with a full-screen app in
    /// front, the window lands on the desktop Space and stays invisible behind it, which looks
    /// exactly like the playground failing to open. `canJoinAllSpaces` plus a full-screen
    /// auxiliary role puts it on the current Space instead, and `orderFrontRegardless` does not
    /// wait for the app to be active.
    private func present(_ window: NSWindow) {
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        window.makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        // The policy is restored by WindowActivation's own willClose observer.
        window = nil
    }
}
#endif
