import AVFoundation
import AppKit
import AutoConnectCore
import CoreVideo
import Foundation
import Vision

/// Reads authenticator QR codes from a live camera feed.
///
/// The other three add paths are one-shot: they hand `QRScanner` a still image or a string and
/// get an answer back at once. A camera is not one-shot. It runs until it sees something, so this
/// owns a session, publishes what it is doing, and calls back exactly once when it is done.
///
/// **Decoding is `Vision`, on frames from `AVCaptureVideoDataOutput`, not `AVCaptureMetadataOutput`.**
/// The metadata output is the obvious API and it does not work here: barcode symbologies are an
/// iOS capability, and on macOS `availableMetadataObjectTypes` comes back empty at every stage of
/// setup, including after `startRunning`. Assigning `.qr` to it then throws an Objective-C
/// exception that Swift cannot catch, which aborts the process rather than failing a call. Vision
/// is also what `QRScanner` already uses, so every add path now decodes the same way.
///
/// What the payload *means* is still `QRScanner.entries`, so a camera scan reads an export QR code
/// and its caveats exactly the way an opened image does.
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

    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.sirpooya.autoconnect.camera")
    private var decoder: FrameDecoder?
    private var onResult: ((Result<QRScanner.ScanResult, Error>) -> Void)?
    private var hintResetTask: Task<Void, Never>?

    init(onResult: @escaping (Result<QRScanner.ScanResult, Error>) -> Void) {
        self.onResult = onResult
        super.init()
    }

    // MARK: - Authorization

    /// The answer to "may this app use the camera", resolved before anything is on screen.
    enum Authorization {
        case authorized
        case refused(String, canOpenPrivacySettings: Bool)
    }

    /// **Must be awaited before the scan window is opened, not after.**
    ///
    /// macOS draws the camera prompt as an app-modal alert, and the scan window is ordered front
    /// regardless of activation so it survives a full-screen app in front. Opening that window
    /// first therefore buries the prompt behind it: the user sees a black rectangle that will
    /// never do anything, and the request sits unanswered forever. Asking first costs nothing,
    /// because the prompt only ever appears on the very first scan.
    static func resolveAuthorization() async -> Authorization {
        // Same gate as the notifier, for the same class of reason: TCC identifies an app by its
        // bundle, and reads the purpose string out of its Info.plist. A bare executable has
        // neither, so asking either fails silently or kills the process.
        guard isBundled else { return .refused(unbundledNote, canOpenPrivacySettings: false) }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
            return granted ? .authorized : .refused(deniedNote, canOpenPrivacySettings: true)
        default:
            return .refused(deniedNote, canOpenPrivacySettings: true)
        }
    }

    // MARK: - Lifecycle

    /// Takes the answer rather than asking for it, so the prompt cannot end up behind the window
    /// this scanner is being shown in.
    func start(_ authorization: Authorization) {
        switch authorization {
        case .authorized:
            configureAndRun()
        case .refused(let message, let canOpenPrivacySettings):
            state = .failed(message, canOpenPrivacySettings: canOpenPrivacySettings)
        }
    }

    /// Ends the scan without a result. Called when the window closes.
    func cancel() {
        finish(.failure(QRScanner.ScanError.cancelled))
    }

    // MARK: - Session

    private func configureAndRun() {
        // Frames are decoded on the session queue and reduced to strings there, so nothing from
        // the capture stack ever reaches the main actor.
        let decoder = FrameDecoder { [weak self] payloads in
            Task { @MainActor [weak self] in
                self?.handle(payloads: payloads)
            }
        }
        self.decoder = decoder

        let session = session
        let output = output
        let queue = sessionQueue

        queue.async { [weak self] in
            guard let device = Self.preferredDevice() else {
                Task { @MainActor [weak self] in
                    self?.state = .failed(Self.noCameraNote, canOpenPrivacySettings: false)
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)

                // Vision wants a pixel buffer it can read directly; 32BGRA is the format it and
                // Core Image both take without a conversion in between.
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                // A QR code that was in frame is still in frame a moment later, so a backlog of
                // stale frames buys nothing and costs memory.
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(decoder, queue: queue)

                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw QRScanner.ScanError.cameraFailed("The camera could not be opened.")
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()

                session.startRunning()

                Task { @MainActor [weak self] in
                    self?.state = .running
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.state = .failed(
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
        decoder?.stop()
        decoder = nil

        // Stopping blocks until the last frame is through, so it does not belong on the main
        // thread. Nothing here reads the session again.
        let session = session
        let output = output
        sessionQueue.async {
            output.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning { session.stopRunning() }
        }

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

/// Runs Vision over camera frames and reports any QR payloads it finds.
///
/// Deliberately not the `@MainActor` scanner itself: the delegate callback arrives on the session
/// queue many times a second, and this way the frame never has to cross an actor boundary to be
/// looked at. Every member is touched only on that one serial queue.
private final class FrameDecoder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Cameras deliver 30 frames a second and a QR code does not appear and vanish between them.
    /// Decoding every frame just heats the machine up.
    private static let minimumInterval: UInt64 = 100_000_000  // 100ms

    private let onPayloads: ([String]) -> Void
    private var lastRun: UInt64 = 0
    private var isStopped = false

    init(onPayloads: @escaping ([String]) -> Void) {
        self.onPayloads = onPayloads
        super.init()
    }

    /// Called on the session queue, so it cannot race a decode in progress.
    func stop() { isStopped = true }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isStopped else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastRun >= Self.minimumInterval else { return }
        lastRun = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        } catch {
            // One unreadable frame is not worth reporting; the next one is along in 100ms.
            return
        }

        let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
        guard !payloads.isEmpty else { return }

        onPayloads(payloads)
    }
}
