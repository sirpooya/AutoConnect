import MacAuthCore
import SwiftUI

@main
struct MacAuthApp: App {
    // The menu bar item and its panel are built in AppKit so the panel can be centred on the
    // icon. See StatusItemController.
    @NSApplicationDelegateAdaptor(StatusItemController.self) private var controller

    var body: some Scene {
        // Settings is opened by Cmd+comma and by the panel's own button. It is a real pane, not a
        // placeholder: an empty Settings scene is what AppKit surfaces as a blank window when a
        // regular-policy app is activated with nothing else open.
        Settings {
            SettingsView()
                .environmentObject(controller.state)
                .environmentObject(controller.vpn)
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
