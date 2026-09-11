import CoreGraphics
import Foundation

/// Display-local points, never screenshot pixels or global desktop coordinates.
/// A crop is immutable for a selected view and must not expand to fit a source.
public struct NativeCaptureRegion: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func rectangle(in size: CGSize) throws -> CGRect {
        let sourceWidth = Double(size.width), sourceHeight = Double(size.height)
        guard [x, y, width, height, sourceWidth, sourceHeight].allSatisfy({ $0.isFinite }),
              x >= 0, y >= 0, width > 0, height > 0,
              sourceWidth > 0, sourceHeight > 0,
              x <= sourceWidth, y <= sourceHeight,
              width <= sourceWidth - x, height <= sourceHeight - y else {
            throw NativeWindowCaptureError.sourceUnavailable
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
