import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item and the panel it opens.
///
/// This is AppKit rather than SwiftUI's `MenuBarExtra` because `MenuBarExtra` gives no control
/// over where its window lands: it hugs whichever screen edge it happens to be near. An
/// `NSPopover` anchored to the status item button is always centred on the icon instead.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    // Reachable from the App scene, which hands them to the Settings pane.
    let state = AppState()
    let vpn = VPNController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    /// True while a system window (file picker, capture overlay) is part of an add in progress.
    /// The panel must survive losing focus to those, but only to those.
    private var isPinned = false

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item

        // The icon is the only thing visible when the panel is closed, so it carries the one
        // fact worth knowing at a glance: whether the tunnel is up.
        apply(phase: vpn.phase)
        vpn.$phase
            .sink { [weak self] phase in self?.apply(phase: phase) }
            .store(in: &cancellables)

        let hosting = NSHostingController(
            rootView: MenuPanel()
                .environmentObject(state)
                .environmentObject(vpn)
        )
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
            isPinned = pinned
            popover.behavior = pinned ? .applicationDefined : .transient
            if !pinned { reopen() }
        }

        // Switching to another app should put the panel away. A popover left open while the app
        // is in the background is the one thing a menu bar panel must never do.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    /// Only a live tunnel counts as connected: connecting and failed both show the off glyph, so
    /// the icon never claims protection the machine does not have.
    private func apply(phase: VPNController.Phase) {
        let isConnected: Bool
        if case .connected = phase { isConnected = true } else { isConnected = false }

        statusItem?.button?.image = MenuBarIcon.image(connected: isConnected)
        statusItem?.button?.toolTip = "MacAuth: \(phase.label)"
    }

    @objc private func appDidResignActive() {
        guard !isPinned, popover.isShown else { return }
        popover.performClose(nil)
    }

    @objc private func toggle() {
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
        //
        // Only activate while the app is still accessory-only. If a real window is open the app
        // is already `.regular` and already active, and activating again asks AppKit to restore
        // "the app's window", which surfaces the Settings scene as a stray blank panel.
        if !WindowActivation.hasOpenWindow {
            NSApp.activate(ignoringOtherApps: true)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Brings the panel back after a system window stole focus, so a scan ends with the new
    /// account visible rather than with an empty menu bar.
    ///
    /// It shows again from scratch even when the panel never went away. AppKit installs the
    /// event monitors that dismiss a transient popover at show time, so one that was pinned
    /// open while shown would otherwise keep ignoring clicks elsewhere for the rest of its life.
    private func reopen() {
        if popover.isShown { popover.close() }
        show()
    }
}
