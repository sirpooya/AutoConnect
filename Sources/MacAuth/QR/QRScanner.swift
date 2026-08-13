import AppKit
import Foundation
import MacAuthCore
import Vision

/// Reads `otpauth://` URIs out of QR codes, either by letting the user drag a region of the
/// screen or by opening an image file.
///
/// Screen capture goes through `/usr/sbin/screencapture -i`, which the system draws itself.
/// That keeps the app out of the Screen Recording permission flow entirely.
enum QRScanner {

    enum ScanError: LocalizedError {
        case cancelled
        case captureFailed(Int32)
        case unreadableImage
        case noQRCodeFound
        case noOTPAuthURI(String)

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
            }
        }
    }

    /// Lets the user drag a region of the screen, then decodes it.
    static func scanScreenRegion() throws -> OTPAuthURI.Parsed {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("macauth-scan-\(UUID().uuidString).png")

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
    static func scanImageFile() throws -> OTPAuthURI.Parsed {
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
    static func parse(imageAt url: URL) throws -> OTPAuthURI.Parsed {
        guard
            let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw ScanError.unreadableImage
        }

        return try parse(cgImage: cgImage)
    }

    static func parse(cgImage: CGImage) throws -> OTPAuthURI.Parsed {
        let payloads = try detectQRPayloads(in: cgImage)
        guard !payloads.isEmpty else { throw ScanError.noQRCodeFound }

        for payload in payloads {
            if let uri = OTPAuthURI.firstURI(in: payload) {
                return try OTPAuthURI.parse(uri)
            }
        }

        throw ScanError.noOTPAuthURI(payloads[0])
    }

    /// Decodes an `otpauth://` URI sitting on the clipboard.
    static func parseClipboard() throws -> OTPAuthURI.Parsed {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard let uri = OTPAuthURI.firstURI(in: text) else {
            throw ScanError.noOTPAuthURI(text.isEmpty ? "nothing" : text)
        }
        return try OTPAuthURI.parse(uri)
    }

    private static func detectQRPayloads(in cgImage: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}
