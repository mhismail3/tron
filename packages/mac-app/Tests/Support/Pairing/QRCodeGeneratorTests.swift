import Foundation
import CoreImage
import AppKit
import Testing
@testable import TronMac

private func decodeQRCode(_ image: CIImage) -> String? {
    let detector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: CIContext(),
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )
    return detector?
        .features(in: image)
        .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        .first
}

@Suite("QRCodeGenerator")
struct QRCodeGeneratorTests {

    @Test("round-trip: pairing URL encodes and decodes back")
    func pairingURLRoundTrip() throws {
        let payload = PairingPayload(host: "100.64.0.1", port: 9847, code: "abc123xyz", label: "My Mac")
        let url = try #require(PairingURLBuilder.makeURL(payload))
        let urlString = url.absoluteString

        let image = try #require(QRCodeGenerator.makeImage(payload: urlString, size: 512))
        // Convert NSImage back to CIImage for the detector. Because
        // makeImage returns an NSImage backed by an NSCIImageRep, we
        // can recover the CIImage directly.
        let rep = try #require(image.representations.first as? NSCIImageRep)
        let decoded = try #require(decodeQRCode(rep.ciImage))
        #expect(decoded == urlString)
    }

}
