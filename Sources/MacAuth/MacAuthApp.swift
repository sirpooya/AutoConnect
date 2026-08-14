import MacAuthCore
import SwiftUI

@main
struct MacAuthApp: App {
    // The menu bar item and its panel are built in AppKit so the panel can be centred on the
    // icon. See StatusItemController.
    @NSApplicationDelegateAdaptor(StatusItemController.self) private var controller

    /// Never true. See the scene below.
    @State private var placeholderInserted = false

    var body: some Scene {
        // An App must declare a Scene, but every scene type that can present a window will be
        // presented at launch by macOS: a `Settings` scene opens itself as soon as it is the only
        // candidate, which is how this app used to come up showing an unrequested settings window.
        //
        // A `MenuBarExtra` that is never inserted satisfies the requirement while presenting
        // nothing at all. The real menu bar item is the AppKit `NSStatusItem`, and settings live in
        // an `NSWindow` this app owns. See SettingsWindow.
        MenuBarExtra("MacAuth", isInserted: $placeholderInserted) {
            EmptyView()
        }

        #if DEBUG
        // Dev-only tuning window. Drives the real VPN row through every phase with fake data, so
        // the status UI can be designed without a live gateway.
        Window("VPN Status Playground", id: VPNStatusPlaygroundWindow.id) {
            VPNStatusPlaygroundView()
        }
        .defaultSize(width: 1020, height: 660)
        #endif
    }
}
