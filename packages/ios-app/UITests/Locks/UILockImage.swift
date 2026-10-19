import UIKit
import XCTest

/// A screenshot as 8-bit sRGB RGBA pixels with the status bar painted out, so
/// two captures compare pixel by pixel independent of PNG encoding.
struct UILockImage {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    struct Difference {
        var count = 0
        var indices: [Int] = []
        var bounds = CGRect.null
    }

    init?(screenshot: XCUIScreenshot) {
        guard let image = screenshot.image.cgImage else { return nil }
        self.init(image, statusBarRows: UILock.statusBarPoints * Int(screenshot.image.scale))
    }

    init?(png: Data) {
        guard let image = UIImage(data: png)?.cgImage else { return nil }
        self.init(image, statusBarRows: 0)
    }

    private init?(_ image: CGImage, statusBarRows: Int) {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Rows are stored top-down; the mask is opaque mid-grey so it reads as a mask.
        for index in 0..<(min(statusBarRows, height) * width * 4) { buffer[index] = index % 4 == 3 ? 255 : 128 }
        self.width = width
        self.height = height
        pixels = buffer
    }

    func differingPixels(from other: UILockImage) -> Difference {
        var difference = Difference()
        guard width == other.width, height == other.height else {
            difference.count = width * height
            return difference
        }
        if pixels == other.pixels { return difference }
        pixels.withUnsafeBufferPointer { a in
            other.pixels.withUnsafeBufferPointer { b in
                for pixel in 0..<(width * height) {
                    let base = pixel * 4
                    var moved = false
                    for channel in 0..<4 where abs(Int(a[base + channel]) - Int(b[base + channel])) > UILock.channelTolerance {
                        moved = true
                        break
                    }
                    guard moved else { continue }
                    difference.count += 1
                    difference.indices.append(pixel)
                    difference.bounds = difference.bounds.union(CGRect(x: pixel % width, y: pixel / width, width: 1, height: 1))
                }
            }
        }
        return difference
    }

    func png() -> Data? { cgImage(pixels).flatMap { UIImage(cgImage: $0).pngData() } }

    /// This image dimmed, with every differing pixel in solid red.
    func highlighting(_ difference: Difference) -> Data? {
        var out = pixels
        for index in stride(from: 0, to: out.count, by: 4) {
            for channel in 0..<3 { out[index + channel] = UInt8(Int(out[index + channel]) / 3 + 170) }
        }
        for pixel in difference.indices {
            out[pixel * 4] = 255; out[pixel * 4 + 1] = 0; out[pixel * 4 + 2] = 0; out[pixel * 4 + 3] = 255
        }
        return cgImage(out).flatMap { UIImage(cgImage: $0).pngData() }
    }

    private func cgImage(_ bytes: [UInt8]) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
