import AVFoundation
import AppKit
import AutoConnectCore
import Foundation

/// Reads authenticator QR codes from a live camera feed.
///
/// The other three add paths are one-shot: they hand `QRScanner` a still image or a string and
/// get an answer back at once. A camera is not one-shot. It runs until it sees something, so this
/// owns a session, publishes what it is doing, and calls back exactly once when it is done.
///
/// `AVCaptureMetadataOutput` does the decoding rather than `Vision`. Vision wants an image, and
/// building one per frame to hand it would be work the capture stack already does for free. What
/// the payload *means* is still `QRScanner.entries`, so a camera scan reads an export QR code and
/// its caveats exactly the way an opened image does.
@MainActor
final class CameraQRScanner: NSObject, ObservableObject {

    enum State: Equatable {
        case starting
        case running
        /// `canOpenPrivacySettings` is true only for a TCC refusal, which is the one failure the
        /// user can do something about from here.
        case failed(String, canOpenPrivacySettings: Bool)
    }

    @Published private(set) var state: State = .starting

    /// A QR code that is not an authenticator code. Shown without ending the scan: the camera is
    /// still pointed at something, and the next thing it sees may well be the right code.
    @Published private(set) var hint: String?

    /// Read by the preview layer. Only ever configured on `sessionQueue`.
    let session = AVCaptureSession()

    private let output = AVCaptureMetadataOutput()
    private let sessionQueue = DispatchQueue(label: "com.sirpooya.autoconnect.camera")
    private var onResult: ((Result<QRScanner.ScanResult, Error>) -> Void)?
    private var hintResetTask: Task<Void, Never>?

    init(onResult: @escaping (Result<QRScanner.ScanResult, Error>) -> Void) {
        self.onResult = onResult
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        // Same gate as the notifier, for the same class of reason: TCC identifies an app by its
        // bundle, and reads the purpose string out of its Info.plist. A bare executable has
        // neither, so asking either fails silently or kills the process.
        guard Self.isBundled else {
            state = .failed(Self.unbundledNote, canOpenPrivacySettings: false)
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.configureAndRun()
                    } else {
                        self.state = .failed(Self.deniedNote, canOpenPrivacySettings: true)
                    }
                }
            }
        default:
            state = .failed(Self.deniedNote, canOpenPrivacySettings: true)
        }
    }

    /// Ends the scan without a result. Called when the window closes.
    func cancel() {
        finish(.failure(QRScanner.ScanError.cancelled))
    }

    // MARK: - Session

    private func configureAndRun() {
        let session = session
        let output = output
        let delegate = self
        let queue = sessionQueue

        queue.async {
            guard let device = Self.preferredDevice() else {
                Task { @MainActor [weak delegate] in
                    delegate?.state = .failed(Self.noCameraNote, canOpenPrivacySettings: false)
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)

                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw QRScanner.ScanError.cameraFailed("The camera could not be opened.")
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()

                // Only valid once the output belongs to a session, which is why this is not up
                // with the rest of the setup.
                output.setMetadataObjectsDelegate(delegate, queue: queue)
                output.metadataObjectTypes = [.qr]

                session.startRunning()

                Task { @MainActor [weak delegate] in
                    delegate?.state = .running
                }
            } catch {
                Task { @MainActor [weak delegate] in
                    delegate?.state = .failed(
                        error.localizedDescription,
                        canOpenPrivacySettings: false
                    )
                }
            }
        }
    }

    /// The built-in camera if there is one, otherwise whatever is plugged in or handed over by a
    /// nearby iPhone.
    private nonisolated static func preferredDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: - Results

    private func handle(payloads: [String]) {
        guard onResult != nil else { return }

        for payload in payloads {
            do {
                guard let result = try QRScanner.entries(in: payload) else { continue }
                finish(.success(result))
            } catch {
                // A link that is recognised but unreadable ends the scan. Holding the camera
                // steadier will not fix it, so re-reading the same code forever is no kindness.
                finish(.failure(error))
            }
            return
        }

        guard let payload = payloads.first else { return }
        show(hint: QRScanner.ScanError.noOTPAuthURI(payload).errorDescription)
    }

    private func show(hint text: String?) {
        hint = text
        hintResetTask?.cancel()
        hintResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hint = nil
        }
    }

    private func finish(_ result: Result<QRScanner.ScanResult, Error>) {
        guard let onResult else { return }
        self.onResult = nil
        hintResetTask?.cancel()

        // Stopping blocks until the last frame is through, so it does not belong on the main
        // thread. Nothing here reads the session again.
        let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }

        onResult(result)
    }

    // MARK: - Notes

    private static let deniedNote =
        "macOS is blocking the camera. Allow AutoConnect in System Settings, Privacy & Security, Camera."

    private static let noCameraNote = "This Mac has no camera available."

    private static let unbundledNote =
        "Camera scanning needs the packaged app. Build it with Scripts/make-app.sh."

    /// Whether this process is a real `.app`. See `VPNStatusNotifier.isBundled`.
    private static let isBundled: Bool = {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }()
}

extension CameraQRScanner: AVCaptureMetadataOutputObjectsDelegate {

    /// Called on `sessionQueue` for every frame that contains a barcode.
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // Reduced to strings here so nothing from the capture stack crosses to the main actor.
        let payloads = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .compactMap(\.stringValue)

        guard !payloads.isEmpty else { return }

        Task { @MainActor [weak self] in
            self?.handle(payloads: payloads)
        }
    }
}
