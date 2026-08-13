import AppKit
import SwiftUI

/// Opening the playground from a menu-bar-only app needs two things a normal window does not:
/// a temporary switch to a regular activation policy (an accessory app cannot take key focus, so
/// the sliders would be unusable), and an explicit activation.
@MainActor
enum VPNStatusPlaygroundWindow {
    static let id = "vpn-status-playground"

    static func open(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
