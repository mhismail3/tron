import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import XCTest
@testable import TronComputerControl

/// Synthetic pixel buffers and inert SCK configuration only. No window lookup,
/// permission query, SCStream construction/start, or native teardown is exercised.
final class WindowCaptureJPEGEncoderTests: XCTestCase {
    func testLimitsRejectOverflowAndUnboundedNativeQueueRateAndDimensions() throws {
        for (width, height, fps) in [(0, 16, 5), (16, -1, 5), (1281, 16, 5), (16, Int.max, 5), (16, 16, 0), (16, 16, 6)] {
            XCTAssertThrowsError(try NativeWindowCaptureLimits(width: width, height: height, framesPerSecond: fps))
        }
        let config = ScreenCaptureKitPlatform.configuration(try .init())
        XCTAssertEqual(config.width, 1280); XCTAssertEqual(config.height, 1280)
        XCTAssertEqual(config.queueDepth, 3)
        XCTAssertEqual(CMTimeGetSeconds(config.minimumFrameInterval), 0.2, accuracy: 0.00001)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(config.colorSpaceName, CGColorSpace.sRGB)
        XCTAssertEqual(config.captureDynamicRange, .SDR)
        XCTAssertFalse(config.capturesAudio); XCTAssertFalse(config.captureMicrophone)
        XCTAssertFalse(config.includeChildWindows); XCTAssertFalse(config.showsCursor)
        XCTAssertFalse(config.showMouseClicks); XCTAssertTrue(config.ignoreShadowsSingleWindow)
        XCTAssertTrue(config.preservesAspectRatio)
    }

    func testSyntheticBufferProducesRealBoundedJPEGWithOwnDecodedDimensionsAndColor() throws {
        let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
        let frame = try XCTUnwrap(encoder.encode(sample()))
        XCTAssertEqual(frame.width, 16); XCTAssertEqual(frame.height, 16)
        try assertPixels(frame, red: true)
    }

    func testFinalCompleteFrameIsNotDroppedByASecondClockBeforeIdle() throws {
        let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
        _ = try XCTUnwrap(encoder.encode(sample()))
        // Back-to-back complete frames model delivery jitter at the SCK boundary.
        // The final blue update must survive even if only idle frames follow it.
        let final = try XCTUnwrap(encoder.encode(sample(redRect: .zero)))
        XCTAssertNil(try encoder.encode(sample(status: SCFrameStatus.idle.rawValue)))
        try assertPixels(final, red: false)
    }

    func testScaledNonoriginCropAndResizeReportActualContentDimensions() throws {
        let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
        for (points, pixels) in [
            (CGRect(x: 1, y: 2, width: 6, height: 3), CGRect(x: 2, y: 4, width: 12, height: 6)),
            (CGRect(x: 2, y: 1, width: 3, height: 5), CGRect(x: 4, y: 2, width: 6, height: 10)),
        ] {
            // Blue padding and a red content marker distinguish actual cropping
            // from relabeling the square canvas or using contentScale (0.25).
            let frame = try XCTUnwrap(encoder.encode(sample(rect: points, scale: 2, redRect: pixels)))
            XCTAssertEqual(frame.width, Int(pixels.width)); XCTAssertEqual(frame.height, Int(pixels.height))
            try assertPixels(frame, red: true)
        }
    }

    func testFractionalEdgesKeepOnlyFullyContainedPixelsWithoutClamping() throws {
        let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
        let points = CGRect(x: 1.25, y: 2.25, width: 5, height: 3)
        let pixels = CGRect(x: 3, y: 5, width: 9, height: 5)
        let frame = try XCTUnwrap(encoder.encode(sample(rect: points, scale: 2, redRect: pixels)))
        XCTAssertEqual(frame.width, 9); XCTAssertEqual(frame.height, 5)
        try assertPixels(frame, red: true)
    }

    func testIncompleteFramesNeverEncodeAndTerminalStatusesFailClosed() throws {
        for status in [SCFrameStatus.idle, .started] {
            let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
            XCTAssertNil(try encoder.encode(sample(status: status.rawValue)))
        }
        for status in [SCFrameStatus.blank, .suspended, .stopped] {
            let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
            XCTAssertThrowsError(try encoder.encode(sample(status: status.rawValue))) {
                XCTAssertEqual($0 as? NativeWindowCaptureError, .sourceUnavailable)
            }
        }
    }

    func testControlSamplesDoNotRequireCompleteFrameTimingOrGeometry() throws {
        let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
        for status in [SCFrameStatus.started, .idle] {
            for ready in [true, false] {
                XCTAssertNil(try encoder.encode(sample(status: status.rawValue, rect: nil, scale: nil, time: .invalid, ready: ready)))
            }
        }
        for status in [SCFrameStatus.blank, .suspended, .stopped] {
            XCTAssertThrowsError(try encoder.encode(sample(status: status.rawValue, rect: nil, scale: nil, time: .invalid))) {
                XCTAssertEqual($0 as? NativeWindowCaptureError, .sourceUnavailable)
            }
        }
        for buffer in [try sample(time: .invalid), try sample(ready: false)] {
            XCTAssertThrowsError(try encoder.encode(buffer)) {
                XCTAssertEqual($0 as? NativeWindowCaptureError, .malformedFrame)
            }
        }
    }

    func testMissingInvalidMetadataWrongSizeAndWrongPixelFormatAreRejected() throws {
        let malformed: [CMSampleBuffer] = [
            try sample(status: nil), try sample(status: 99), try sample(rect: nil),
            try sample(rect: .init(x: 0, y: 0, width: CGFloat.infinity, height: 16)),
            try sample(rect: .init(x: -0.1, y: 0, width: 16, height: 16)),
            try sample(rect: .init(x: 0, y: 0, width: 16.1, height: 16)),
            try sample(rect: .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5)),
            try sample(scale: 2), // Point bounds fit, scaled pixel bounds do not.
            try sample(scale: nil), try sample(scale: .nan), try sample(scale: .infinity),
            try sample(scale: 0.5), try sample(scale: 4.1),
            try sample(width: 8), try sample(format: kCVPixelFormatType_32ARGB),
        ]
        for (index, buffer) in malformed.enumerated() {
            let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
            XCTAssertThrowsError(try encoder.encode(buffer), "malformed sample \(index)") {
                XCTAssertEqual($0 as? NativeWindowCaptureError, .malformedFrame)
            }
        }
    }

    func testSubpixelOrNegativeExtentsCannotStandardizeIntoCapturedPixels() throws {
        for rect in [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                     CGRect(x: 4, y: 2, width: -2, height: 3),
                     CGRect(x: 2, y: 4, width: 3, height: -2)] {
            let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
            XCTAssertThrowsError(try encoder.encode(sample(rect: rect)), "raw extent \(rect.size)") {
                XCTAssertEqual($0 as? NativeWindowCaptureError, .malformedFrame)
            }
        }
    }

    func testPresenterOverlayMetadataRejectsQueuedSmallLargeAndMalformedComposites() throws {
        for overlay in [CGRect(x: 0, y: 0, width: 16, height: 16), CGRect(x: 2, y: 2, width: 4, height: 4)] {
            let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
            XCTAssertThrowsError(try encoder.encode(sample(overlay: overlay.dictionaryRepresentation))) {
                XCTAssertEqual($0 as? NativeWindowCaptureError, .sourceUnavailable)
            }
        }
        for overlay: AnyObject in ["invalid" as NSString,
                                   CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 16).dictionaryRepresentation] {
            let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
            XCTAssertThrowsError(try encoder.encode(sample(overlay: overlay))) {
                XCTAssertEqual($0 as? NativeWindowCaptureError, .malformedFrame)
            }
        }
        let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
        XCTAssertNotNil(try encoder.encode(sample(overlay: CGRect.zero.dictionaryRepresentation)))
    }

    func testNativeNullPresenterSentinelIsEmptyButMalformedInfinityIsNot() throws {
        let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
        // Observed from real SCK: no overlay is encoded as (inf, inf, 0, 0),
        // not necessarily CGRect.zero or an absent attachment.
        XCTAssertNotNil(try encoder.encode(sample(overlay: CGRect.null.dictionaryRepresentation)))
        for rect in [CGRect(x: CGFloat.infinity, y: CGFloat.infinity, width: 1, height: 0),
                     CGRect(x: CGFloat.infinity, y: 0, width: 0, height: 0),
                     CGRect(x: -CGFloat.infinity, y: -CGFloat.infinity, width: 0, height: 0),
                     CGRect(x: CGFloat.nan, y: 0, width: 0, height: 0)] {
            XCTAssertThrowsError(try encoder.encode(sample(overlay: rect.dictionaryRepresentation))) {
                XCTAssertEqual($0 as? NativeWindowCaptureError, .malformedFrame)
            }
        }
    }

    func testEncodedByteSinkRefusesOversizedWritesBeforeAllocatingThem() {
        let sink = WindowCaptureJPEGBytes()
        var byte: UInt8 = 0
        withUnsafePointer(to: &byte) { pointer in
            // Only one readable byte: reject by count before dereferencing.
            XCTAssertEqual(sink.append(pointer, count: NativeWindowCaptureLimits.maximumEncodedBytes + 1), 0)
            XCTAssertTrue(sink.exceeded); XCTAssertTrue(sink.data.isEmpty)
            XCTAssertEqual(sink.append(pointer, count: 1), 0)
        }
    }

    func testEncodedByteSinkNeverGrowsPastCapAcrossMultipleWrites() {
        let sink = WindowCaptureJPEGBytes()
        let bytes = Data(repeating: 0, count: NativeWindowCaptureLimits.maximumEncodedBytes)
        bytes.withUnsafeBytes { buffer in
            XCTAssertEqual(sink.append(buffer.baseAddress!, count: bytes.count - 1), bytes.count - 1)
            XCTAssertEqual(sink.append(buffer.baseAddress!, count: 1), 1)
            XCTAssertEqual(sink.append(buffer.baseAddress!, count: 1), 0)
        }
        XCTAssertEqual(sink.data.count, NativeWindowCaptureLimits.maximumEncodedBytes)
        XCTAssertTrue(sink.exceeded)
    }

    func testFailureDiagnosticsContainOnlyBoundedNumericMetadata() throws {
        let diagnostics = WindowCaptureJPEGEncoder.diagnostic(try sample(overlay: "private fixture content" as NSString))
        XCTAssertTrue(diagnostics.contains("buffer=16x16"))
        XCTAssertTrue(diagnostics.contains("status=0"))
        XCTAssertTrue(diagnostics.contains("overlay=invalid"))
        XCTAssertFalse(diagnostics.contains("private fixture content"))
        XCTAssertLessThanOrEqual(diagnostics.count, 512)
        let invalid = try sample()
        CMSampleBufferInvalidate(invalid)
        XCTAssertEqual(WindowCaptureJPEGEncoder.diagnostic(invalid), "valid=0")
    }

    func testInvalidatedSampleIsNotPublished() throws {
        let encoder = WindowCaptureJPEGEncoder(limits: try .init(width: 16, height: 16))
        let buffer = try sample()
        XCTAssertEqual(CMSampleBufferInvalidate(buffer), noErr)
        XCTAssertThrowsError(try encoder.encode(buffer)) {
            XCTAssertEqual($0 as? NativeWindowCaptureError, .malformedFrame)
        }
    }

    private func assertPixels(_ frame: WindowCaptureEncodedFrame, red: Bool,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertLessThanOrEqual(frame.jpeg.count, NativeWindowCaptureLimits.maximumEncodedBytes, file: file, line: line)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(frame.jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg", file: file, line: line)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, frame.width, file: file, line: line)
        XCTAssertEqual(image.height, frame.height, file: file, line: line)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
        }
        for pixel in stride(from: 0, to: rgba.count, by: 4) {
            XCTAssertGreaterThan(rgba[pixel + (red ? 0 : 2)], 220, file: file, line: line)
            XCTAssertLessThan(rgba[pixel + 1], 30, file: file, line: line)
            XCTAssertLessThan(rgba[pixel + (red ? 2 : 0)], 30, file: file, line: line)
        }
    }

    private func sample(width: Int = 16, format: OSType = kCVPixelFormatType_32BGRA,
                        status: Int? = SCFrameStatus.complete.rawValue,
                        rect: CGRect? = .init(x: 0, y: 0, width: 16, height: 16),
                        scale: Double? = 1, redRect: CGRect? = nil, overlay: AnyObject? = nil,
                        time: CMTime = CMTime(value: 1, timescale: 1), ready: Bool = true) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 16, format, nil, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image))
        memset(base, 0, CVPixelBufferGetDataSize(image))
        for y in 0..<16 {
            for x in 0..<width {
                let red = redRect?.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) ?? true
                base.advanced(by: y * CVPixelBufferGetBytesPerRow(image) + x * 4)
                    .storeBytes(of: UInt32(red ? 0xffff0000 : 0xff0000ff).littleEndian, as: UInt32.self)
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                                   formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            dataReady: ready, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &buffer), noErr)
        let result = try XCTUnwrap(buffer)
        let values = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(values, 0), to: CFMutableDictionary.self)
        func set(_ key: SCStreamFrameInfo, _ value: AnyObject) {
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key.rawValue as NSString).toOpaque(),
                                 Unmanaged.passUnretained(value).toOpaque())
        }
        if let status { set(.status, NSNumber(value: status)) }
        if let rect { set(.contentRect, rect.dictionaryRepresentation) }
        if let scale { set(.scaleFactor, NSNumber(value: scale)) }
        set(.contentScale, NSNumber(value: 0.25)) // Must not be used for the crop.
        if let overlay { set(.presenterOverlayContentRect, overlay) }
        return result
    }
}
