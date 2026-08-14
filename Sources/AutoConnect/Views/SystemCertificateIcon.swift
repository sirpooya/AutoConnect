import AppKit
import SwiftUI

/// The certificate artwork macOS uses in Keychain Access.
///
/// It lives in SecurityInterface.framework's resources rather than in any API, so it is loaded
/// from the framework bundle by name and falls back to an SF Symbol when a future macOS moves
/// or renames it. Nothing is bundled with this app: the icon on screen is the system's own, so
/// it always matches the one the user sees in Keychain Access.
struct SystemCertificateIcon: View {
    /// Point size of the square the icon is drawn in.
    var size: CGFloat = 32

    var body: some View {
        if let image = Self.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    /// Loaded once: the lookup touches the filesystem, and this view is rebuilt on every
    /// keystroke in the sheet it sits in.
    private static let artwork: NSImage? = {
        let bundle = Bundle(path: "/System/Library/Frameworks/SecurityInterface.framework")
        return bundle?.image(forResource: "CertLargeStd")
    }()
}
