import Foundation
import SwiftUI
import UIKit
@testable import TronMobileCore
@testable import TronMobile

/// Shared bounds for the hosted chat-motion measurements. The 160 ms streaming
/// and replacement curves span roughly ten 60 Hz display boundaries; a 40 pt
/// one-frame ceiling admits the largest 37.7 pt tool-capsule state step measured
/// in the hosted fixture while rejecting larger structural jumps. Tail positioning
/// already has a 12 pt hosted geometry contract.
enum ChatMotionConformanceBounds {
    static let maximumGeometryStep: CGFloat = 40
    static let minimumAnimatedFrames = 4
    static let minimumPixelChangingFrames = 3
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

@MainActor
enum ChatMotionPixelSupport {
    /// Captures the mounted hosted window, cropped to the row's published frame.
    /// Pixel sampling is intentionally a separate pass from geometry sampling.
    static func captureRow(_ rowID: String, harness: ChatViewScrollHarness) throws -> UIImage? {
        guard let frame = harness.probeObservation.rowFrames[rowID],
              let window = harness.visibleRootView.window else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: frame)
        return renderer.image { context in
            context.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    static func changedPixels(_ lhs: UIImage, _ rhs: UIImage) -> Bool {
        guard let a = lhs.cgImage, let b = rhs.cgImage,
              a.width == b.width, a.height == b.height,
              let aData = a.dataProvider?.data as Data?,
              let bData = b.dataProvider?.data as Data? else { return lhs.size != rhs.size }
        let aBytes = [UInt8](aData), bBytes = [UInt8](bData)
        let threshold = Int(ChatMotionConformanceBounds.pixelChannelThreshold)
        return stride(from: 0, to: min(aBytes.count, bBytes.count), by: 4).contains { index in
            (0..<min(4, min(aBytes.count, bBytes.count) - index)).contains {
                abs(Int(aBytes[index + $0]) - Int(bBytes[index + $0])) > threshold
            }
        }
    }
}
