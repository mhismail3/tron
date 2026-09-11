import CoreGraphics
import Foundation
import ImageIO
import TronComputerControl

/// Closed invocation: no target, input, duration, or arbitrary filesystem selector.
enum CaptureQualificationInvocation: Equatable {
    case help, preflight, capture(writeImages: Bool), invalid

    static func parse(_ arguments: [String]) -> Self {
        switch arguments {
        case [], ["--help"], ["-h"]: .help
        case ["--preflight"]: .preflight
        case ["--capture-self-window"]: .capture(writeImages: false)
        case ["--capture-self-window", "--write-images"]: .capture(writeImages: true)
        default: .invalid
        }
    }
}

/// The same entry boundary is exercised offline with native closures that must
/// remain uncalled for help/invalid input. Parsing precedes even NSApplication.
@MainActor
enum CaptureQualificationEntry {
    static func run(arguments: [String], emit: (String) -> Void,
                    preflight: () -> Int32, capture: (Bool) -> Int32) -> Int32 {
        switch CaptureQualificationInvocation.parse(arguments) {
        case .help:
            emit("Usage: TronNativeCaptureQualification --preflight | --capture-self-window [--write-images]")
            return 0
        case .invalid:
            emit("Qualification refused: use --help for the fixed, self-window-only modes.")
            return 2
        case .preflight: return preflight()
        case let .capture(writeImages): return capture(writeImages)
        }
    }
}

enum CaptureQualificationFailure: String, Error, Codable {
    case permissionUnavailable, unsupportedSystem, identityUnavailable, nativeUnavailable
    case deadline, cancelled, frameBudget, invalidJPEG, markerMismatch, dimensionsMismatch
    case lateReadAccepted, sourceCloseNotObserved, stopNotJoined, outputUnavailable
}

enum CaptureQualificationStage: String, Codable, CaseIterable {
    case initial, changed, resized, sourceCloseBaseline
    var pointSize: (width: Int, height: Int) {
        switch self {
        case .initial, .changed: (320, 200)
        case .resized, .sourceCloseBaseline: (200, 320)
        }
    }
}

struct CaptureQualificationRGB: Codable, Equatable {
    let red: Int
    let green: Int
    let blue: Int
}

struct CaptureQualificationFrameEvidence: Codable {
    let stage: CaptureQualificationStage
    let generation: UUID
    let sequence: UInt64
    let width: Int
    let height: Int
    let encodedBytes: Int
    /// Measured 5x5 patch means in top-left, top-right, bottom-left, bottom-right order.
    let samples: [CaptureQualificationRGB]

    var matches: Bool {
        let size = stage.pointSize
        return sequence > 0 && (100...1280).contains(width) && (100...1280).contains(height)
            && (1...2 * 1_024 * 1_024).contains(encodedBytes)
            && abs(width * size.height - height * size.width) <= 2 * max(size.width, size.height)
            && CaptureQualificationJPEG.markersMatch(samples, stage: stage)
    }
}

/// No fixture drawing helpers are used by this oracle. Expected RGB values and
/// patch locations are specified independently of AppKit's drawing implementation.
enum CaptureQualificationJPEG {
    static func markersMatch(_ samples: [CaptureQualificationRGB], stage: CaptureQualificationStage) -> Bool {
        let expected: [[Int]]
        switch stage {
        case .initial: expected = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
        case .changed: expected = [[0, 255, 255], [255, 0, 255], [255, 255, 0], [0, 0, 255]]
        case .resized, .sourceCloseBaseline: expected = [[0, 255, 0], [0, 0, 255], [255, 0, 0], [0, 255, 255]]
        }
        return samples.count == 4 && zip(samples, expected).allSatisfy { actual, wanted in
            zip([actual.red, actual.green, actual.blue], wanted).allSatisfy { (0...255).contains($0) && abs($0 - $1) <= 35 }
        }
    }

    static func inspect(_ frame: NativeWindowCaptureFrame, stage: CaptureQualificationStage) throws -> CaptureQualificationFrameEvidence {
        guard (1...2 * 1_024 * 1_024).contains(frame.jpeg.count),
              (100...1280).contains(frame.width), (100...1280).contains(frame.height),
              let source = CGImageSourceCreateWithData(frame.jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == frame.width, height == frame.height else { throw CaptureQualificationFailure.invalidJPEG }
        // Validate encoded dimensions BEFORE full decode: metadata cannot authorize
        // an unbounded ImageIO allocation or merely relabel a square native canvas.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == width, image.height == height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw CaptureQualificationFailure.invalidJPEG }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw CaptureQualificationFailure.invalidJPEG
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let samples = [(1, 1), (3, 1), (1, 3), (3, 3)].map { x, y in
            var channels = [0, 0, 0]
            for row in (height * y / 4 - 2)...(height * y / 4 + 2) {
                for column in (width * x / 4 - 2)...(width * x / 4 + 2) {
                    for channel in 0..<3 { channels[channel] += Int(pixels[(row * width + column) * 4 + channel]) }
                }
            }
            return CaptureQualificationRGB(red: channels[0] / 25, green: channels[1] / 25, blue: channels[2] / 25)
        }
        return .init(stage: stage, generation: frame.generation, sequence: frame.sequence,
                     width: width, height: height, encodedBytes: frame.jpeg.count, samples: samples)
    }
}

/// Observe the actual producer after its join. Joining and a healthy native
/// retirement are distinct facts; expected source-close errors are phase-local.
struct CaptureQualificationStopInspection {
    let joined: Bool
    let retirementFailure: NativeWindowCaptureError?
    let readFailure: NativeWindowCaptureError?

    static func observe(_ producer: NativeWindowCapture, generation: UUID) async -> Self {
        let joined = await producer.stopAndJoin() == .joined
        let diagnostic = producer.retirementFailure
        do {
            _ = try producer.takeLatestFrame(generation: generation)
            return .init(joined: joined, retirementFailure: diagnostic, readFailure: nil)
        } catch {
            return .init(joined: joined, retirementFailure: diagnostic,
                         readFailure: error as? NativeWindowCaptureError ?? .malformedFrame)
        }
    }

    func require(expected: NativeWindowCaptureError) throws {
        guard joined else { throw CaptureQualificationFailure.stopNotJoined }
        if let retirementFailure { throw retirementFailure }
        guard readFailure == expected else {
            if let readFailure { throw readFailure }
            throw CaptureQualificationFailure.lateReadAccepted
        }
    }
}

struct CaptureQualificationReport: Codable {
    var schema = "tron.native-capture-qualification.v1"
    let mode: String
    var supportedSystem = false
    var screenRecordingPreflight = false
    var frames: [CaptureQualificationFrameEvidence] = []
    var stopJoined = false
    var lateReadRejected = false
    var sourceCloseObserved = false
    var sourceCloseReason: String?
    var sourceStopJoined = false
    var sourceLateReadRejected = false
    var deadlineTriggered = false
    var cancellationObserved = false
    var containmentRequired = false
    var failure: CaptureQualificationFailure?
    var nativeFailure: String?
    var retirementFailure: String?
    var imageDirectory: String?

    var passed: Bool {
        guard schema == "tron.native-capture-qualification.v1", supportedSystem, screenRecordingPreflight,
              failure == nil, nativeFailure == nil, retirementFailure == nil,
              !deadlineTriggered, !cancellationObserved, !containmentRequired else { return false }
        if mode == "preflight" { return frames.isEmpty && imageDirectory == nil }
        guard mode == "capture-self-window", frames.map(\.stage) == CaptureQualificationStage.allCases,
              frames.allSatisfy(\.matches), stopJoined, lateReadRejected, sourceCloseObserved,
              ["sourceUnavailable", "streamFailed"].contains(sourceCloseReason), sourceStopJoined, sourceLateReadRejected else { return false }
        let first = frames[0], changed = frames[1], resized = frames[2], second = frames[3]
        return first.generation == changed.generation && first.generation == resized.generation
            && second.generation != first.generation && first.sequence < changed.sequence && changed.sequence < resized.sequence
            && first.width == changed.width && first.height == changed.height
            && abs(first.width - resized.height) <= 2 && abs(first.height - resized.width) <= 2
            && second.width == resized.width && second.height == resized.height
    }

    func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var object = try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
        object["passed"] = passed
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count < 16 * 1_024 else { throw CaptureQualificationFailure.outputUnavailable }
        return data + Data("\n".utf8)
    }
}
