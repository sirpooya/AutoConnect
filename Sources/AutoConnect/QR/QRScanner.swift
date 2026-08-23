import AppKit
import Foundation
import AutoConnectCore
import Vision

/// Reads authenticator QR codes, either by letting the user drag a region of the screen or by
/// opening an image file. Two payloads count: a single `otpauth://` enrollment code, and the
/// `otpauth-migration://` export Google Authenticator produces, which carries several accounts
/// at once.
///
/// Screen capture goes through `/usr/sbin/screencapture -i`, which the system draws itself.
/// That keeps the app out of the Screen Recording permission flow entirely.
enum QRScanner {

    /// What one scan yielded. An export QR code is many accounts, so every path returns a list
    /// rather than a single entry, plus whatever the user still needs to be told: which part of
    /// a split export this was, and what it could not carry.
    struct ScanResult {
        var entries: [OTPAuthURI.Parsed]
        var note: String?
    }

    enum ScanError: LocalizedError {
        case cancelled
        case captureFailed(Int32)
        case unreadableImage
        case noQRCodeFound
        case noOTPAuthURI(String)
        case cameraFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Scan cancelled."
            case .captureFailed(let code):
                return "Screen capture failed (exit \(code))."
            case .unreadableImage:
                return "That image could not be read."
            case .noQRCodeFound:
                return "No QR code found in that image."
            case .noOTPAuthURI(let payload):
                let preview = payload.count > 60 ? String(payload.prefix(60)) + "..." : payload
                return "That QR code is not an authenticator code. It contains: \(preview)"
            case .cameraFailed(let reason):
                return reason
            }
        }
    }

    /// Lets the user drag a region of the screen, then decodes it.
    static func scanScreenRegion() throws -> ScanResult {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoconnect-scan-\(UUID().uuidString).png")

        defer { try? FileManager.default.removeItem(at: destination) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive selection, -x silent, -t png
        process.arguments = ["-i", "-x", "-t", "png", destination.path]

        try process.run()
        process.waitUntilExit()

        // screencapture exits 0 and writes nothing when the user presses Escape.
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw ScanError.cancelled
        }
        guard process.terminationStatus == 0 else {
            throw ScanError.captureFailed(process.terminationStatus)
        }

        return try parse(imageAt: destination)
    }

    /// Opens a file picker and decodes the chosen image.
    static func scanImageFile() throws -> ScanResult {
        let panel = NSOpenPanel()
        panel.title = "Choose a QR code image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            throw ScanError.cancelled
        }

        return try parse(imageAt: url)
    }

    /// Decodes an image already on disk. Also used for drag and drop.
    static func parse(imageAt url: URL) throws -> ScanResult {
        guard
            let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw ScanError.unreadableImage
        }

        return try parse(cgImage: cgImage)
    }

    static func parse(cgImage: CGImage) throws -> ScanResult {
        let payloads = try detectQRPayloads(in: cgImage)
        guard !payloads.isEmpty else { throw ScanError.noQRCodeFound }

        for payload in payloads {
            if let result = try entries(in: payload) { return result }
        }

        throw ScanError.noOTPAuthURI(payloads[0])
    }

    /// Decodes a link sitting on the clipboard, enrollment or export.
    static func parseClipboard() throws -> ScanResult {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard let result = try entries(in: text) else {
            throw ScanError.noOTPAuthURI(text.isEmpty ? "nothing" : text)
        }
        return result
    }

    /// The one place a payload is turned into accounts. Returns nil when the text holds neither
    /// kind of link, so the caller can report what it did contain; a link that is recognised but
    /// unreadable throws, since its own message says more than "not an authenticator code".
    ///
    /// The export is checked first: it is the longer scheme, and "otpauth://" is not a substring
    /// of "otpauth-migration://", so neither parser can claim the other's payload.
    ///
    /// Internal rather than private because `CameraQRScanner` decodes its own payloads, through
    /// the capture stack rather than Vision, and must reach the same answer from them.
    static func entries(in text: String) throws -> ScanResult? {
        if let uri = OTPMigrationURI.firstURI(in: text) {
            let batch = try OTPMigrationURI.parse(uri)
            return ScanResult(entries: batch.entries, note: batch.summary)
        }
        if let uri = OTPAuthURI.firstURI(in: text) {
            return ScanResult(entries: [try OTPAuthURI.parse(uri)], note: nil)
        }
        return nil
    }

    private static func detectQRPayloads(in cgImage: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}
