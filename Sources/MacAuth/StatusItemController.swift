import AppKit
import SwiftUI

/// Owns the menu bar item and the panel it opens.
///
/// This is AppKit rather than SwiftUI's `MenuBarExtra` because `MenuBarExtra` gives no control
/// over where its window lands: it hugs whichever screen edge it happens to be near. An
/// `NSPopover` anchored to the status item button is always centred on the icon instead.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "MacAuth"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item

        let hosting = NSHostingController(rootView: MenuPanel().environmentObject(state))
        // Let SwiftUI drive the popover's height, so the panel grows and shrinks with the
        // account list instead of being pinned to a guessed size.
        hosting.sizingOptions = [.preferredContentSize]

        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false

        PanelPin.onChange = { [weak self] pinned in
            guard let self else { return }
            // A transient popover closes as soon as another window takes focus, which the file
            // picker and the capture overlay both do. Switching behaviour keeps it up for the
            // duration, then hands dismissal back to the system.
            popover.behavior = pinned ? .applicationDefined : .transient
            if !pinned { reopen() }
        }
    }

    @objc private func toggle() {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        // Always reopen on the list; a half-filled form left over from last time is not what
        // someone reaching for a code wants to see.
        state.route = .list

        show()
    }

    private func show() {
        guard let button = statusItem?.button else { return }

        // A menu bar app is not active by default, and an inactive app's text fields refuse
        // first responder, which would make the manual entry form untypeable.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Brings the panel back after a system window stole focus, so a scan ends with the new
    /// account visible rather than with an empty menu bar.
    private func reopen() {
        if popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            show()
        }
    }
}
