import AppKit
import SwiftUI

/// The available menu bar glyph sets. Every set is a pair: an outline glyph for disconnected and a
/// filled one for a live tunnel, so the meaning survives whichever set is chosen.
/// Raw values are explicit and have gaps because the selection is persisted: two sets were removed
/// after being tried, and renumbering the survivors would silently move a saved choice onto a
/// different glyph.
enum MenuBarIconSet: Int, CaseIterable, Identifiable {
    case keyholeArc = 0
    case keyholeInCircle = 1
    case padlock = 2
    case globe = 5
    case lock = 6

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .keyholeArc: "Keyhole arc"
        case .keyholeInCircle: "Keyhole in circle"
        case .padlock: "Padlock"
        case .globe: "Globe"
        case .lock: "Lock"
        }
    }

    /// Resource basenames, disconnected first.
    var names: (off: String, on: String) {
        switch self {
        case .keyholeArc: ("off", "on")
        case .keyholeInCircle: ("2-off", "2-on")
        case .padlock: ("3-off", "3-on")
        case .globe: ("globe-off", "globe-on")
        case .lock: ("lock-off", "lock-on")
        }
    }
}

/// The status item glyphs, loaded from the bundled vector PDFs.
///
/// They are marked as template images so AppKit tints them for the current menu bar appearance
/// (light, dark, and the inverted look while the panel is open) instead of drawing them flat
/// black.
@MainActor
enum MenuBarIcon {
    /// Menu bar glyphs are conventionally 18x18pt, which leaves the standard padding inside the
    /// 22pt menu bar. The PDFs are vector, so this only decides the point size, not the fidelity.
    private static let size = NSSize(width: 18, height: 18)

    /// Loaded glyphs, by resource name. The status item re-reads its image on every phase change
    /// and the playground can swap sets live, so this keeps that off the disk.
    private static var cache: [String: NSImage] = [:]

    static func image(connected: Bool, set: MenuBarIconSet = .keyholeArc) -> NSImage? {
        load(connected ? set.names.on : set.names.off)
    }

    private static func load(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }

        guard
            let url = Bundle.module.url(forResource: name, withExtension: "pdf"),
            let image = NSImage(contentsOf: url)
        else { return nil }

        image.size = size
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

/// Draws the current glyph, falling back to an SF Symbol if a resource is ever missing, so a
/// packaging mistake degrades to a visible icon rather than an empty, unclickable status item.
struct MenuBarIconView: View {
    var isConnected: Bool = false

    private var set: MenuBarIconSet {
        MenuBarIconSet(rawValue: VPNStatusParams.shared.menuBarIconSet) ?? .keyholeArc
    }

    var body: some View {
        if let image = MenuBarIcon.image(connected: isConnected, set: set) {
            Image(nsImage: image)
        } else {
            Image(systemName: isConnected ? "lock.rotation.open" : "lock.rotation")
        }
    }
}
