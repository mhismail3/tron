import SwiftUI
import Testing
import UIKit
@testable import TronMobile
@testable import TronMobileCore

/// An asymmetric, fully loaded image distinguishes render orientation from row
/// position. A placeholder or a symmetric thumbnail cannot expose this defect.
@MainActor
enum ChatDisplayOrientationFixture {
    static func snapshot() throws -> SessionSnapshot {
        var snapshot = try SessionScenarioBuilder(seed: 1_310).openingTail(targetEncodedBytes: 10_000)
        snapshot.transcript = try decodeTranscriptFixture([TranscriptItem].self, from: HostedChatDisplayFixture.imageTranscriptData)
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = snapshot.transcript.count
        snapshot.toolExecutions = []
        return snapshot
    }

    static func mediaFetch() throws -> ChatMediaFetch {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 80, width: 160, height: 80))
        }
        let data = try #require(image.pngData())
        return { _ in ChatMediaPayload(data: data, mimeType: "image/png") }
    }

    static func harness(orientation: ChatTranscriptOrientation = .selected) async throws -> ChatViewScrollHarness {
        try await ChatViewScrollHarness.composerSubmissionHarness(
            snapshot: snapshot(), displayFrameScheduler: .displayLink,
            mediaFetch: mediaFetch(), orientation: orientation
        )
    }

    static func capture(_ harness: ChatViewScrollHarness) throws -> UIImage {
        let window = try #require(harness.visibleRootView.window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// Scan rendered window pixels, not transforms inferred from SwiftUI layout.
    static func colorCenters(_ image: UIImage) throws -> (red: CGPoint, blue: CGPoint)? {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = CGPoint.zero, blue = CGPoint.zero
        var reds = 0, blues = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if bytes[i] > 160 && bytes[i + 1] < 70 && bytes[i + 2] < 70 {
                    red.x += CGFloat(x); red.y += CGFloat(y); reds += 1
                }
                if bytes[i + 2] > 160 && bytes[i] < 70 && bytes[i + 1] < 70 {
                    blue.x += CGFloat(x); blue.y += CGFloat(y); blues += 1
                }
            }
        }
        guard reds > 500, blues > 500 else { return nil }
        return (CGPoint(x: red.x / CGFloat(reds), y: red.y / CGFloat(reds)),
                CGPoint(x: blue.x / CGFloat(blues), y: blue.y / CGFloat(blues)))
    }

    static func waitForLoadedImage(_ harness: ChatViewScrollHarness) async throws -> UIImage {
        _ = try await harness.recorder.waitUntil { $0.observation.isReady }
        for _ in 0..<60 {
            try await harness.driveFrameBoundary()
            let image = try capture(harness)
            if try colorCenters(image) != nil { return image }
        }
        throw CocoaError(.fileReadUnknown)
    }
}

@MainActor
@Suite(.serialized, .enabled(if: UIValidationTier.isActive))
struct ChatDisplayOrientationTests {
    @Test("loaded inline image renders upright in window pixels in both orientations")
    func inlineImageRendersUpright() async throws {
        for orientation in [ChatTranscriptOrientation.newestAtEnd, .newestAtOrigin] {
            let harness = try await ChatDisplayOrientationFixture.harness(orientation: orientation)
            do {
                harness.visibleRootView.window?.overrideUserInterfaceStyle = .dark
                _ = try await ChatDisplayOrientationFixture.waitForLoadedImage(harness)
                for _ in 0..<24 { try await harness.driveFrameBoundary() }
                let image = try ChatDisplayOrientationFixture.capture(harness)
                let colors = try #require(try ChatDisplayOrientationFixture.colorCenters(image))
                #expect(colors.red.y < colors.blue.y, "\(orientation): red \(colors.red), blue \(colors.blue)")
                Attachment.record(try #require(image.pngData()), named: "inline-image-\(orientation).png")
            } catch {
                await harness.close()
                throw error
            }
            await harness.close()
        }
    }
}
