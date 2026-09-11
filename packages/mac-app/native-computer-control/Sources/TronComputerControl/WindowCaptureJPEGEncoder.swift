import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

internal struct WindowCaptureEncodedFrame {
    let jpeg: Data
    let width: Int
    let height: Int
}

/// Used only on the stream's serial sample queue. No sample/pixel buffer escapes
/// this synchronous call; the bounded JPEG is the only retained frame payload.
internal final class WindowCaptureJPEGEncoder {
    let limits: NativeWindowCaptureLimits
    init(limits: NativeWindowCaptureLimits) { self.limits = limits }

    /// Failure-only numeric diagnostics. Never include pixels, titles, target
    /// identities, attachment descriptions, or arbitrary framework error text.
    static func diagnostic(_ sample: CMSampleBuffer) -> String {
        guard CMSampleBufferIsValid(sample) else { return "valid=0" }
        let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first ?? [:]
        func number(_ value: Any?) -> String {
            guard let value = value as? Double else { return "-" }
            return String(format: "%.17g", value)
        }
        func rectangle(_ value: Any?) -> String {
            guard let value else { return "-" }
            guard let dictionary = value as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return "invalid" }
            return [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].map { number(Double($0)) }.joined(separator: ",")
        }
        let pixel = CMSampleBufferGetImageBuffer(sample)
        let layout = pixel.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0)),stride=\(CVPixelBufferGetBytesPerRow($0)),bytes=\(CVPixelBufferGetDataSize($0)),format=\(CVPixelBufferGetPixelFormatType($0)),planes=\(CVPixelBufferGetPlaneCount($0))" } ?? "none"
        let result = "ready=\(CMSampleBufferDataIsReady(sample)) samples=\(CMSampleBufferGetNumSamples(sample)) timeFinite=\(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)).isFinite) status=\(number(info[.status])) buffer=\(layout) rect=\(rectangle(info[.contentRect])) scale=\(number(info[.scaleFactor])) contentScale=\(number(info[.contentScale])) overlay=\(rectangle(info[.presenterOverlayContentRect]))"
        return String(result.prefix(512))
    }

    func encode(_ sample: CMSampleBuffer) throws -> WindowCaptureEncodedFrame? {
        guard CMSampleBufferIsValid(sample),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.count == 1, let raw = attachments[0][.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { throw NativeWindowCaptureError.malformedFrame }
        // The effect delegate can arrive after a queued composite frame. The
        // privacy-alert setting does not disable camera/presenter composition.
        if let overlay = attachments[0][.presenterOverlayContentRect] {
            guard let dictionary = overlay as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else {
                throw NativeWindowCaptureError.malformedFrame
            }
            // Real SCK reports absent composition as canonical CGRect.null.
            // Accept only its exact empty shape, not arbitrary infinite geometry.
            let nullOverlay = rect.origin.x == .infinity && rect.origin.y == .infinity
                && rect.size.width == 0 && rect.size.height == 0
            guard nullOverlay || (rect.origin.x.isFinite && rect.origin.y.isFinite
                && rect.size.width.isFinite && rect.size.height.isFinite
                && rect.size.width >= 0 && rect.size.height >= 0) else {
                throw NativeWindowCaptureError.malformedFrame
            }
            if rect.size.width > 0 || rect.size.height > 0 { throw NativeWindowCaptureError.sourceUnavailable }
        }
        // Status notifications are not video frames. Startup/idle samples need
        // not carry complete-frame timing, readiness or geometry. The overlay
        // rejection above still applies to queued composition notifications.
        switch status {
        case .idle, .started: return nil
        case .blank, .suspended, .stopped: throw NativeWindowCaptureError.sourceUnavailable
        case .complete: break
        @unknown default: throw NativeWindowCaptureError.malformedFrame
        }
        guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) == 1,
              CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)).isFinite else {
            throw NativeWindowCaptureError.malformedFrame
        }
        // SCK uses CGRect's dictionary representation, not an NSValue. Match
        // Apple's Capturing Screen Content in macOS sample and the offline fixture.
        guard let rectDictionary = attachments[0][.contentRect] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: rectDictionary as CFDictionary),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0,
              let scale = attachments[0][.scaleFactor] as? Double,
              scale.isFinite, (1...4).contains(scale),
              let pixel = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixel) == limits.width, CVPixelBufferGetHeight(pixel) == limits.height,
              CVPixelBufferGetPlaneCount(pixel) == 0 else { throw NativeWindowCaptureError.malformedFrame }
        // SCStream.h defines contentRect in surface points. Multiply by pixel
        // density (scaleFactor), NOT contentScale, which would undo source scaling.
        let scaled = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale)
        // SCK's Float32 content scaling can reconstruct an edge a fraction of
        // one Float ULP outside the actual surface (600pt -> 1280.000066757px).
        // Admit only that numerical error, never a pixel or arbitrary overflow.
        let xError = Double(Float(limits.width).ulp)
        let yError = Double(Float(limits.height).ulp)
        guard scaled.minX >= -xError, scaled.minY >= -yError,
              scaled.maxX <= Double(limits.width) + xError,
              scaled.maxY <= Double(limits.height) + yError else {
            throw NativeWindowCaptureError.malformedFrame
        }
        // Normalize accepted edge roundoff to the surface, then crop inward.
        // Interior fractional edges keep the existing fully-contained-pixel rule.
        let left = ceil(max(0, scaled.minX)), top = ceil(max(0, scaled.minY))
        let right = floor(min(Double(limits.width), scaled.maxX))
        let bottom = floor(min(Double(limits.height), scaled.maxY))
        let cropWidth = right - left
        let cropHeight = bottom - top
        // CGRect.width/height standardize negative sizes. Check signed extents
        // before making a rectangle, or a subpixel region can admit outside pixels.
        guard cropWidth >= 1, cropHeight >= 1 else { throw NativeWindowCaptureError.malformedFrame }
        let crop = CGRect(x: left, y: top, width: cropWidth, height: cropHeight)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
        guard rowBytes >= limits.width * 4,
              rowBytes <= NativeWindowCaptureLimits.maximumRawBytes / limits.height,
              CVPixelBufferGetDataSize(pixel) >= rowBytes * limits.height,
              CVPixelBufferGetDataSize(pixel) <= NativeWindowCaptureLimits.maximumRawBytes else {
            throw NativeWindowCaptureError.malformedFrame
        }
        // SCK's minimumFrameInterval owns cadence. A second clock/drop gate can
        // lose a window's final complete frame when only idle samples follow it.
        guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
            throw NativeWindowCaptureError.malformedFrame
        }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: base, width: limits.width, height: limits.height,
                  bitsPerComponent: 8, bytesPerRow: rowBytes, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let image = context.makeImage(), let content = image.cropping(to: crop) else {
            throw NativeWindowCaptureError.encodingFailed
        }
        return try .init(jpeg: Self.jpeg(content), width: content.width, height: content.height)
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let sink = WindowCaptureJPEGBytes()
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            return Unmanaged<WindowCaptureJPEGBytes>.fromOpaque(info).takeUnretainedValue().append(bytes, count: count)
        }, releaseConsumer: nil)
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(sink).toOpaque(), cbks: &callbacks),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NativeWindowCaptureError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination), !sink.exceeded, !sink.data.isEmpty else {
            throw NativeWindowCaptureError.encodingFailed
        }
        return sink.data
    }
}

/// Stops accepting ImageIO writes at the cap, rather than allocating an unbounded
/// NSMutableData and checking only after the encoder finishes.
internal final class WindowCaptureJPEGBytes {
    private(set) var data = Data()
    private(set) var exceeded = false
    func append(_ bytes: UnsafeRawPointer, count: Int) -> Int {
        guard !exceeded, count >= 0, count <= NativeWindowCaptureLimits.maximumEncodedBytes - data.count else {
            exceeded = true
            return 0
        }
        data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
        return count
    }
}
