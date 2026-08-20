import AppKit
import AutoConnectCore
import Combine
import SwiftUI

/// Owns the menu bar item and the panel it opens.
///
/// This is AppKit rather than SwiftUI's `MenuBarExtra` because `MenuBarExtra` gives no control
/// over where its window lands: it hugs whichever screen edge it happens to be near. An
/// `NSPopover` anchored to the status item button is always centred on the icon instead.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    /// Declared first on purpose. Stored properties initialise in declaration order, and the
    /// stores below read the Keychain services and defaults keys that the rename moved, so this
    /// has to have moved them by the time `state` asks for the accounts.
    private let carriedOldData = LegacyMigration.runIfNeeded()

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
    private var terminationSignalSource: DispatchSourceSignal?

    private var cancellables = Set<AnyCancellable>()

    /// Catches a termination signal so the tunnel still comes down.
    ///
    /// `applicationWillTerminate` covers Cmd+Q and the Quit button, but a SIGTERM (a `pkill`, or a
    /// tool stopping the app) can end the process without AppKit running that. A signal source
    /// keeps the promise that quitting means disconnected.
    ///
    /// SIGKILL cannot be caught by anything; adoption is what covers that case.
    private func installTerminationSignalHandler() {
        // The default disposition has to be ignored, or the process dies before the handler runs.
        signal(SIGTERM, SIG_IGN)

        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.applicationWillTerminate(
                    Notification(name: NSApplication.willTerminateNotification)
                )
                NSApp.terminate(nil)
            }
        }
        source.resume()
        terminationSignalSource = source
    }

    /// Takes the tunnel down with the app.
    ///
    /// openconnect is a separate root process, so without this it keeps running after a quit and
    /// the machine stays on the VPN with nothing managing it. Adoption exists for the cases this
    /// cannot cover, a crash or a force quit, but a deliberate quit means deliberately off.
    func applicationWillTerminate(_ notification: Notification) {
        guard vpn.isConnected || vpn.hasRunningTunnel else { return }

        DiagnosticLog.write("quit: tearing down the tunnel")
        vpn.disconnect()
    }

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
        installTerminationSignalHandler()
        WindowActivation.startObserving()
        WindowActivation.evaluate()

        // In-app updates. Started here rather than lazily from About, so a build left running for
        // weeks still learns that a new one exists. The closure is the tunnel gate: a scheduled
        // check that offered an update mid-session would be offering to drop the connection.
        UpdateController.shared.start { [weak self] in
            guard let self else { return false }
            return vpn.isConnected || vpn.hasRunningTunnel || vpn.phase.isWorking
        }

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
        // The only way in, now that the footer button is gone:
        //   build/AutoConnect.app/Contents/MacOS/AutoConnect --playground
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

        // Choosing a different glyph set in the playground should show up in the real menu bar
        // immediately. AppKit observes nothing by itself, hence the notification.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paramsChanged),
            name: .vpnStatusParamsChanged,
            object: nil
        )
    }

    /// Only a live tunnel counts as connected: connecting and failed both show the off glyph, so
    /// the icon never claims protection the machine does not have.
    private func apply(phase: VPNController.Phase) {
        let isConnected: Bool
        if case .connected = phase { isConnected = true } else { isConnected = false }

        let set = MenuBarIconSet(rawValue: VPNStatusParams.shared.menuBarIconSet) ?? .keyholeArc
        statusItem?.button?.image = MenuBarIcon.image(connected: isConnected, set: set)
        statusItem?.button?.toolTip = "AutoConnect: \(phase.label)"
    }

    @objc private func paramsChanged() {
        apply(phase: vpn.phase)
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

        // A menu bar app is not active by default, and an inactive app's controls refuse first
        // responder, which would make anything typeable in the panel untypeable.
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
