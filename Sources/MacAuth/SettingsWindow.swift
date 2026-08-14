import AppKit
import SwiftUI

/// Hosts the settings pane in an `NSWindow` this app owns.
///
/// SwiftUI's `Settings` scene cannot be used here. When it is the app's only presentable scene,
/// macOS opens it at launch by itself, so the app came up showing a settings window nobody asked
/// for. Neither `applicationShouldOpenUntitledFile` nor `applicationShouldHandleReopen` prevents
/// it, and closing the window during launch makes SwiftUI terminate the app outright.
///
/// Owning the window means it appears exactly when `show` is called and never otherwise.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    /// Opens the pane, or brings it forward if it is already up.
    func show(state: AppState, vpn: VPNController, notifier: VPNStatusNotifier) {
        // A menu-bar-only app is `.accessory` and cannot take key focus, so text fields would
        // refuse first responder. WindowActivation switches to `.regular` and back.
        WindowActivation.claim()

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView()
                .environmentObject(state)
                .environmentObject(vpn)
                .environmentObject(notifier)
        )
        // The pane is a fixed size (tabs, each scrolling inside a constant frame), so the window
        // gets that size directly. Sizing it from `preferredContentSize` instead makes AppKit
        // re-measure the SwiftUI content during its own constraint pass, and with a ScrollView in
        // the tree that never settles: the window aborts with "more Update Constraints in Window
        // passes than there are views in the window".
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "MacAuth Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(
            NSSize(width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight)
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        // The pane opens to be read, not typed into, so nothing takes the caret.
        // AppKit picks the first text field otherwise, and the gateway address would
        // come up selected and one keystroke away from being replaced.
        window.initialFirstResponder = nil
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        WindowActivation.release()
    }
}
