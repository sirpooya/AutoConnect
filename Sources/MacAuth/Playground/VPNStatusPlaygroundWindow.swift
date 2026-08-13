import AppKit
import SwiftUI

/// Opening the playground from a menu-bar-only app needs a temporary switch to a regular
/// activation policy, since an accessory app cannot take key focus and the sliders would not
/// track. `WindowActivation` also puts the policy back when the window closes.
@MainActor
enum VPNStatusPlaygroundWindow {
    static let id = "vpn-status-playground"

    static func open(_ openWindow: OpenWindowAction) {
        WindowActivation.claim()
        openWindow(id: id)
    }
}
