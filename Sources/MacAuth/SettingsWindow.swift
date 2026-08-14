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
    func show(state: AppState, vpn: VPNController) {
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
        )
        // Let SwiftUI size the window, so sections can grow without a guessed height.
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = "MacAuth Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        WindowActivation.release()
    }
}
