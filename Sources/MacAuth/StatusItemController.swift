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
    /// Turns phase changes into banners, when Settings says to. Silent by default.
    let notifier = VPNStatusNotifier()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    /// True while a system window (file picker, capture overlay) is part of an add in progress.
    /// The panel must survive losing focus to those, but only to those.
    private var isPinned = false

    private var cancellables = Set<AnyCancellable>()

    /// Keeps the app alive when its last window closes.
    ///
    /// A menu bar app's windows are incidental: closing Settings or the playground must leave the
    /// status item running. SwiftUI's app lifecycle otherwise terminates on the last window, which
    /// makes closing Settings look exactly like a crash.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Refuses AppKit's offer to open an "untitled" window at launch.
    ///
    /// Launching an app with no document and no visible window makes AppKit ask for one, and with
    /// a SwiftUI `Settings` scene as the only candidate that is what it opens. This app's entire
    /// interface is the menu bar item, so the answer is always no.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// Refuses AppKit's offer to open a window when the app is activated with none visible.
    ///
    /// Without this, clicking the menu bar icon can surface the Settings scene: AppKit treats an
    /// activation with no visible windows as a reopen and picks a scene itself. Settings must only
    /// appear when it is asked for.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opt out of window restoration. With the system's "Close windows when quitting an app"
        // unchecked, macOS reopens whatever was on screen at quit, so a Settings window left open
        // comes back by itself on the next launch and reads as the app opening it unbidden.
        //
        // Do NOT try to fix this by closing windows in this method: closing SwiftUI's own scene
        // windows during launch makes the app terminate immediately with exit 0.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])

        // Keeps the activation policy honest even for windows opened outside `claim`, such as
        // Settings via Cmd+comma.
        WindowActivation.startObserving()
        WindowActivation.evaluate()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item

        // The icon is the only thing visible when the panel is closed, so it carries the one
        // fact worth knowing at a glance: whether the tunnel is up.
        apply(phase: vpn.phase)
        vpn.$phase
            .sink { [weak self] phase in
                guard let self else { return }
                apply(phase: phase)
                // The icon is for whoever is looking at the menu bar; the banner is for whoever
                // is not. Both are driven from the one place the phase is observed.
                notifier.record(
                    phase: phase,
                    gateway: vpn.profile.displayName,
                    isRenewing: vpn.isRenewing
                )
            }
            .store(in: &cancellables)

        let hosting = NSHostingController(
            rootView: MenuPanel()
                .environmentObject(state)
                .environmentObject(vpn)
                .environmentObject(notifier)
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

        #if DEBUG
        // Lets the playground be opened straight from a launch, without hunting for the footer
        // button inside a popover that accessibility cannot see:
        //   build/MacAuth.app/Contents/MacOS/MacAuth --playground
        if CommandLine.arguments.contains("--playground") {
            PlaygroundWindow.shared.show()
        }
        #endif

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
