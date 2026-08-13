import MacAuthCore
import SwiftUI

@main
struct MacAuthApp: App {
    // The menu bar item and its panel are built in AppKit so the panel can be centred on the
    // icon. See StatusItemController.
    @NSApplicationDelegateAdaptor(StatusItemController.self) private var controller

    var body: some Scene {
        // The app has no windows of its own. A Settings scene satisfies the requirement that an
        // App declare one; LSUIElement keeps it out of the Dock and out of the menu bar.
        Settings { EmptyView() }

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
