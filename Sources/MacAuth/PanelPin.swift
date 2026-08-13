import Foundation

/// Keeps the menu bar panel open across a system UI trip.
///
/// The panel is a transient popover, so it closes the moment another window takes focus. That is
/// right for a stray click elsewhere, but wrong for the file picker and the screen capture
/// overlay: those are steps in adding an account, and the panel needs to still be there
/// afterwards to show the account that was just added.
///
/// `StatusItemController` installs `onChange`. Nesting is counted, so overlapping scans cannot
/// unpin the panel early.
@MainActor
enum PanelPin {
    /// Called with `true` when the first pin is taken and `false` when the last is released.
    static var onChange: ((Bool) -> Void)?

    private static var depth = 0

    static func pinned<T>(_ body: () throws -> T) rethrows -> T {
        depth += 1
        if depth == 1 { onChange?(true) }

        defer {
            depth -= 1
            if depth == 0 { onChange?(false) }
        }

        return try body()
    }
}
