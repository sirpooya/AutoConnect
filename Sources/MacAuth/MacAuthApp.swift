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

        // The playground is deliberately not a scene either. As a `Window` scene it restored
        // itself at launch after any session that had opened it, and an accessory app cannot
        // raise a restored window because it cannot become active. See PlaygroundWindow.
    }
}
