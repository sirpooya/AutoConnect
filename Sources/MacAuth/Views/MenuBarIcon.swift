import AppKit
import SwiftUI

/// The status item glyphs, loaded from the bundled vector PDFs.
///
/// They are marked as template images so AppKit tints them for the current menu bar appearance
/// (light, dark, and the inverted look while the panel is open) instead of drawing them flat
/// black.
enum MenuBarIcon {
    /// Menu bar glyphs are conventionally 18x18pt, which leaves the standard padding inside the
    /// 22pt menu bar. The PDFs are vector, so this only decides the point size, not the fidelity.
    private static let size = NSSize(width: 18, height: 18)

    /// Shown while the tunnel is up.
    static let connected: NSImage? = load("on")

    /// Shown for every other state: idle, connecting, and failed.
    static let disconnected: NSImage? = load("off")

    static func image(connected isConnected: Bool) -> NSImage? {
        isConnected ? connected : disconnected
    }

    private static func load(_ name: String) -> NSImage? {
        guard
            let url = Bundle.module.url(forResource: name, withExtension: "pdf"),
            let image = NSImage(contentsOf: url)
        else { return nil }

        image.size = size
        image.isTemplate = true
        return image
    }
}

/// Draws the current glyph, falling back to an SF Symbol if a resource is ever missing, so a
/// packaging mistake degrades to a visible icon rather than an empty, unclickable status item.
struct MenuBarIconView: View {
    var isConnected: Bool = false

    var body: some View {
        if let image = MenuBarIcon.image(connected: isConnected) {
            Image(nsImage: image)
        } else {
            Image(systemName: isConnected ? "lock.rotation.open" : "lock.rotation")
        }
    }
}
