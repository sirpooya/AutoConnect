import AVFoundation
import AppKit
import AutoConnectCore
import SwiftUI

/// Hosts a live camera scan in an `NSWindow` this app owns.
///
/// Same reason as `SettingsWindow` and `PlaygroundWindow`: a SwiftUI scene would restore itself
/// at launch, and an accessory app cannot raise a restored window because it cannot become
/// active. Owning the window means the camera turns on when `show` is called and never otherwise,
/// which is the only acceptable behaviour for a camera.
@MainActor
final class CameraScanWindow: NSObject, NSWindowDelegate {
    static let shared = CameraScanWindow()

    private var window: NSWindow?
    private var scanner: CameraQRScanner?
    private var completion: ((Result<QRScanner.ScanResult, Error>) -> Void)?
    /// True across the permission round trip, before there is a window to guard against.
    private var isStarting = false

    /// Opens the scanner. `completion` is called exactly once, whether the camera reads a code,
    /// fails, or the user closes the window.
    func show(completion: @escaping (Result<QRScanner.ScanResult, Error>) -> Void) {
        // A second request while one is already scanning is answered by the window that is
        // already up. Cancelling the newcomer at once keeps its caller's pin balanced.
        guard window == nil, !isStarting else {
            WindowActivation.claim()
            if let window { present(window) }
            completion(.failure(QRScanner.ScanError.cancelled))
            return
        }

        self.completion = completion
        isStarting = true

        // A menu-bar-only app is `.accessory` and cannot take key focus, so Escape and the close
        // button would not answer. WindowActivation switches to `.regular` and back. Claiming it
        // *before* the permission prompt also brings the app forward, so the prompt is not
        // drawn behind whatever the user was looking at.
        WindowActivation.claim()

        // Permission is settled before any window exists. The scan window is ordered front
        // regardless of activation, so opening it first would bury the system's camera prompt
        // behind it and leave the user staring at a black rectangle.
        Task { @MainActor in
            let authorization = await CameraQRScanner.resolveAuthorization()
            self.isStarting = false

            // The caller gave up while the prompt was on screen.
            guard self.completion != nil else {
                WindowActivation.release()
                return
            }
            self.openWindow(authorization)
        }
    }

    private func openWindow(_ authorization: CameraQRScanner.Authorization) {
        let scanner = CameraQRScanner { [weak self] result in
            self?.finish(result)
        }
        self.scanner = scanner

        let hosting = NSHostingController(rootView: CameraScanView(scanner: scanner))
        // Fixed size, for the same reason the settings window is: letting AppKit measure SwiftUI
        // content during its own constraint pass is what kills that window.
        hosting.sizingOptions = []

        let window = EscapeClosesWindow(contentViewController: hosting)
        window.title = "Scan QR Code"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 396))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        present(window)
        scanner.start(authorization)
    }

    /// Brings the window up wherever the user actually is. Without `canJoinAllSpaces` and
    /// `orderFrontRegardless`, a full-screen app in front leaves this on the desktop Space, which
    /// looks exactly like the scanner failing to open.
    private func present(_ window: NSWindow) {
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// The one exit. Tears the camera down before answering, so the light is out by the time the
    /// panel shows what was added.
    private func finish(_ result: Result<QRScanner.ScanResult, Error>) {
        guard let completion else { return }
        self.completion = nil

        isStarting = false
        scanner?.cancel()
        scanner = nil

        if let window {
            // Cleared first, or closing re-enters through `windowWillClose`.
            window.delegate = nil
            self.window = nil
            window.close()
        }
        WindowActivation.release()

        completion(result)
    }

    func windowWillClose(_ notification: Notification) {
        // Dropped first: the window is already closing, and `finish` would otherwise send it
        // through `close()` a second time.
        window = nil
        finish(.failure(QRScanner.ScanError.cancelled))
    }
}

/// Escape closes the scanner.
///
/// A menu-bar-only app has no menu bar of its own, so there is no Cancel button and no Cmd+W to
/// inherit. `cancelOperation` is the responder-chain message Escape already sends, and NSWindow
/// acts on it only for sheets and panels, so this is the whole of what is missing.
private final class EscapeClosesWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// The scanner's window: a live preview, or the reason there is not one.
private struct CameraScanView: View {
    @ObservedObject var scanner: CameraQRScanner

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle()
                    .fill(.black)

                switch scanner.state {
                case .starting:
                    ProgressView()
                        .controlSize(.small)
                case .running:
                    CameraPreview(session: scanner.session)
                    reticle
                case .failed(let message, let canOpenPrivacySettings):
                    failure(message, canOpenPrivacySettings: canOpenPrivacySettings)
                }
            }
            .frame(height: 320)

            footer
        }
    }

    /// Says where to aim without covering what is being aimed at.
    private var reticle: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(.white.opacity(0.7), lineWidth: 2)
            .frame(width: 180, height: 180)
    }

    private func failure(_ message: String, canOpenPrivacySettings: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.5))

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if canOpenPrivacySettings {
                Button("Open Privacy Settings") { Self.openPrivacySettings() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 40)
    }

    /// One line, and it is either the standing instruction or the reason the last code was no
    /// use. The height is fixed so a hint arriving cannot resize the window under the preview.
    private var footer: some View {
        Text(scanner.hint ?? "Hold the QR code up to the camera.")
            .font(.system(size: 11))
            .foregroundStyle(scanner.hint == nil ? .secondary : .primary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .padding(.horizontal, 20)
    }

    private static func openPrivacySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        )
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Wraps `AVCaptureVideoPreviewLayer`, which has no SwiftUI equivalent.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }

    func updateNSView(_ nsView: PreviewView, context: Context) {}

    final class PreviewView: NSView {
        private let previewLayer: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)

            wantsLayer = true
            layer = CALayer()
            previewLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(previewLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            // Without this the layer animates to every new size, so the preview slides around
            // for a quarter second whenever the window is laid out.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
