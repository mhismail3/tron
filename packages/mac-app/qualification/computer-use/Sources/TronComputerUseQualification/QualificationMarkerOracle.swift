import CoreGraphics
import Foundation

struct QualificationMarkerSamples {
    let green: Int
    let red: Int
}

enum QualificationMarkerError: Error {
    case invalidGeometry
    case cannotCreateBitmap
}

/// ScreenCaptureKit can return Display P3 pixels. Normalize through a real sRGB
/// drawing context; NSBitmapImageRep(cgImage:).colorAt can relabel those bytes as
/// calibrated RGB and make a visibly green image fail the colour oracle.
enum QualificationMarkerOracle {
    static func samples(in image: CGImage) throws -> QualificationMarkerSamples {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 2_560, height <= 2_560,
              width * height <= 4_000_000 else { throw QualificationMarkerError.invalidGeometry }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return try pixels.withUnsafeMutableBytes { bytes in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw QualificationMarkerError.cannotCreateBitmap }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let step = max(1, max(width, height) / 80)
            var green = 0
            var red = 0
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    let offset = (y * width + x) * 4
                    guard bytes[offset + 3] > 230 else { continue }
                    if bytes[offset] > 140 && bytes[offset + 1] < 77 {
                        red += 1
                    } else if bytes[offset + 1] > 115 && bytes[offset] < 77 {
                        green += 1
                    }
                }
            }
            return QualificationMarkerSamples(green: green, red: red)
        }
    }
}
