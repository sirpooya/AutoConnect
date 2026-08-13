import AppKit
import SwiftUI

/// The status item glyph, loaded from the bundled vector PDF.
///
/// It is marked as a template image so AppKit tints it for the current menu bar appearance
/// (light, dark, and the inverted look while the menu is open) instead of drawing it flat black.
enum MenuBarIcon {
    /// Menu bar glyphs are conventionally 18x18pt, which leaves the standard padding inside the
    /// 22pt menu bar. The PDF is vector, so this only decides the point size, not the fidelity.
    private static let size = NSSize(width: 18, height: 18)

    static let image: NSImage? = {
        guard
            let url = Bundle.module.url(forResource: "menubar", withExtension: "pdf"),
            let image = NSImage(contentsOf: url)
        else { return nil }

        image.size = size
        image.isTemplate = true
        return image
    }()
}

/// Draws the custom glyph, falling back to an SF Symbol if the resource is ever missing, so a
/// packaging mistake degrades to a visible icon rather than an empty, unclickable status item.
struct MenuBarIconView: View {
    var body: some View {
        if let image = MenuBarIcon.image {
            Image(nsImage: image)
        } else {
            Image(systemName: "lock.rotation")
        }
    }
}
