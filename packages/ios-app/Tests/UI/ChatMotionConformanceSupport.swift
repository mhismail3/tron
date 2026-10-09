import Foundation
import SwiftUI
import UIKit
@testable import TronMobileCore
@testable import TronMobile

/// Shared bounds for hosted chat motion. A 20 pt step leaves margin above the
/// largest correctly animated samples (14.67 pt arrive, 13.33 pt replace, 12 pt
/// resize) without admitting a near-atomic tool-capsule resize. Tail positioning
/// already has a 12 pt hosted geometry contract.
enum ChatMotionConformanceBounds {
    static let maximumGeometryStep: CGFloat = 20
    static let minimumAnimatedFrames = 4
    static let minimumPixelChangingFrames = 2
    static let maximumTailDistance: CGFloat = 12
    static let pixelChannelThreshold: UInt8 = 8
}

struct ChatMotionFrameSample: Codable {
    let frame: Int
    let transitioningHeight: Double?
    let rowBelowHeight: Double?
    let transitioningFrame: [Double]?
    let rowBelowFrame: [Double]?
    let tailDistance: Double
}

struct ChatMotionCaseMetrics: Codable {
    let name: String
    let maximumTransitioningRowStep: Double
    let maximumRowBelowStep: Double
    let maximumTailDistance: Double
    let pixelChangingFrames: Int?
    let rowIdentityInstances: Int
    let samples: [ChatMotionFrameSample]
}

/// Pixel extraction shared by hosted visual fixtures so motion evidence uses
/// the same device-RGB/top-left convention as the existing row fixtures.
func sampledPixel(of image: UIImage, at point: CGPoint) -> (red: Int, green: Int, blue: Int, alpha: Int)? {
    guard let cgImage = image.cgImage else { return nil }
    let x = Int((point.x * image.scale).rounded())
    let y = Int((point.y * image.scale).rounded())
    guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height,
          let data = cgImage.dataProvider?.data as Data? else { return nil }
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
    defer { buffer.deallocate() }
    buffer.initialize(repeating: 0, count: 4)
    guard let context = CGContext(
        data: buffer,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(
        cgImage,
        in: CGRect(x: -CGFloat(x), y: -(CGFloat(cgImage.height) - CGFloat(y) - 1),
                   width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
    )
    return (Int(buffer[0]), Int(buffer[1]), Int(buffer[2]), Int(buffer[3]))
}

@MainActor
enum ChatMotionPixelSupport {
    /// `drawHierarchy` takes 20–80 ms on the hosted window, longer than a display
    /// frame. Slow the local clock so real-time animations remain observable
    /// across captures instead of aliasing differently on each run.
    static let animationClockSpeed: Float = 0.1
    /// Fifty pixel- and row-geometry-stable captures span the local gaps between
    /// expensive hosted snapshots; the larger cap remains only a hang guard.
    static let maximumSampleCount = 120
    static let requiredStablePixelCaptures = 50

    /// Pixel sampling is a separate, slower pass; use the orientation fixture's
    /// shared hosted-window capture and sample points only within this row.
    static func captureWindow(harness: ChatViewScrollHarness) throws -> UIImage {
        try ChatDisplayOrientationFixture.capture(harness)
    }

    static func changedPixels(_ lhs: UIImage, _ rhs: UIImage, in frame: CGRect) -> Bool {
        let inset = frame.insetBy(dx: 2, dy: 2)
        guard !inset.isNull, inset.width > 0, inset.height > 0 else { return false }
        let grid = 6
        let threshold = Int(ChatMotionConformanceBounds.pixelChannelThreshold)
        for row in 0...grid {
            for column in 0...grid {
                let point = CGPoint(x: inset.minX + inset.width * CGFloat(column) / CGFloat(grid),
                                    y: inset.minY + inset.height * CGFloat(row) / CGFloat(grid))
                guard let a = sampledPixel(of: lhs, at: point),
                      let b = sampledPixel(of: rhs, at: point) else { continue }
                if max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) > threshold {
                    return true
                }
            }
        }
        return false
    }
}
