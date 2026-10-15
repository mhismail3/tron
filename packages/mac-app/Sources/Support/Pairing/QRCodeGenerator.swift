import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Wraps `CIQRCodeGenerator` to produce an `NSImage` from a string.
/// Empty input yields nil.
enum QRCodeGenerator {
    /// Encodes `payload` as a QR code at the requested pixel size.
    /// Returns nil if the payload is empty or CoreImage refuses to
    /// produce an output image.
    static func makeImage(payload: String, size: CGFloat = 256) -> NSImage? {
        guard !payload.isEmpty else { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        let nativeSize = ciImage.extent.size
        guard nativeSize.width > 0, nativeSize.height > 0 else { return nil }

        let scale = max(size / nativeSize.width, 1)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
