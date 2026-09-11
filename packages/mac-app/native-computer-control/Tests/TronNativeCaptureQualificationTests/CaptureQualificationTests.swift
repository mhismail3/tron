import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TronComputerControl
@testable import TronNativeCaptureQualification

/// Offline only: no AppKit fixture, preflight, SCK selection/start, or executable
/// launch. Synthetic JPEG bytes are independent of the live fixture's renderer.
final class CaptureQualificationTests: XCTestCase {
    @MainActor
    func testHelpAndInvalidArgumentsCannotReachNativeClosures() {
        let help: [[String]] = [[], ["--help"], ["-h"]]
        let invalid: [[String]] = [["--capture"], ["--preflight", "--write-images"], ["--capture-self-window", "--pid", "1"],
            ["--capture-self-window", "--window", "1"], ["--capture-self-window", "--text", "fixture"],
            ["--capture-self-window", "--deadline-ms", "1"], ["--capture-self-window", "--output", "/private/tmp/output"],
            ["--capture-self-window", "--write-images", "--write-images"], ["--help", "--capture-self-window"],
            ["--write-images"], ["--preflight", "--capture-self-window"]]
        var nativeCalls = 0
        for args in help + invalid {
            var messages: [String] = []
            let status = CaptureQualificationEntry.run(arguments: args, emit: { messages.append($0) },
                preflight: { nativeCalls += 1; return 99 }, capture: { _ in nativeCalls += 1; return 99 })
            XCTAssertEqual(status, help.contains(args) ? 0 : 2)
            XCTAssertEqual(messages.count, 1)
            XCTAssertLessThan(messages[0].utf8.count, 256)
        }
        XCTAssertEqual(nativeCalls, 0)
        var invocations: [String] = []
        for args in [["--preflight"], ["--capture-self-window"], ["--capture-self-window", "--write-images"]] {
            XCTAssertEqual(CaptureQualificationEntry.run(arguments: args, emit: { _ in XCTFail("Unexpected usage") },
                preflight: { invocations.append("preflight"); return 0 },
                capture: { invocations.append($0 ? "images" : "capture"); return 0 }), 0)
        }
        XCTAssertEqual(invocations, ["preflight", "capture", "images"])
    }

    func testRealJPEGDecodeRequiresActualPixelsAndDimensionsNotMetadataEcho() throws {
        let frame = try synthetic(stage: .initial)
        let evidence = try CaptureQualificationJPEG.inspect(frame, stage: .initial)
        XCTAssertTrue(evidence.matches)
        XCTAssertEqual(evidence.width, 320); XCTAssertEqual(evidence.height, 200)
        XCTAssertGreaterThan(evidence.samples[0].red, 220)
        XCTAssertLessThan(evidence.samples[0].blue, 35)
        XCTAssertFalse(try CaptureQualificationJPEG.inspect(frame, stage: .changed).matches, "Stale content must not pass")
        let swapped = NativeWindowCaptureFrame(generation: frame.generation, sequence: 1, jpeg: frame.jpeg, width: 200, height: 320)
        XCTAssertThrowsError(try CaptureQualificationJPEG.inspect(swapped, stage: .resized))
        for bytes in [Data(), Data("not a JPEG".utf8), Data(repeating: 0, count: 2 * 1_024 * 1_024 + 1)] {
            let bad = NativeWindowCaptureFrame(generation: frame.generation, sequence: 1, jpeg: bytes, width: 320, height: 200)
            XCTAssertThrowsError(try CaptureQualificationJPEG.inspect(bad, stage: .initial))
        }
    }

    func testSquareCanvasWrongColorAndWrongOrientationAreNegativeControls() throws {
        for frame in [try synthetic(stage: .initial, width: 320, height: 320),
                      try synthetic(stage: .initial, solid: true),
                      try synthetic(stage: .initial, flipRows: true)] {
            XCTAssertFalse(try CaptureQualificationJPEG.inspect(frame, stage: .initial).matches)
        }
        XCTAssertTrue(try CaptureQualificationJPEG.inspect(synthetic(stage: .resized), stage: .resized).matches)
    }

    func testJoinedProducerCannotHideRetirementDiagnosticOrWrongPhaseFailure() async throws {
        let cases: [(NativeWindowCaptureError?, NativeWindowCaptureError?)] = [
            (nil, nil), (nil, .stopFailed), (.sourceUnavailable, nil),
            (.streamFailed, nil), (.sourceUnavailable, .stopFailed)
        ]
        for (earlyFailure, diagnostic) in cases {
            let stream = QualificationStopStream(diagnostic: diagnostic)
            let producer = NativeWindowCapture(platform: QualificationStopPlatform(stream: stream),
                                               limits: try .init(width: 16, height: 16))
            guard case let .available(generation) = await producer.start() else {
                return XCTFail("Offline producer did not start")
            }
            if let earlyFailure { stream.fail(earlyFailure) }
            let inspection = await CaptureQualificationStopInspection.observe(producer, generation: generation)
            XCTAssertTrue(inspection.joined)
            XCTAssertEqual(inspection.retirementFailure, diagnostic)
            XCTAssertEqual(inspection.readFailure, earlyFailure ?? .stopped)
            if earlyFailure == nil && diagnostic == nil {
                XCTAssertNoThrow(try inspection.require(expected: .stopped))
            } else {
                XCTAssertThrowsError(try inspection.require(expected: .stopped))
            }
            if let earlyFailure {
                if diagnostic == nil { XCTAssertNoThrow(try inspection.require(expected: earlyFailure)) }
                else { XCTAssertThrowsError(try inspection.require(expected: earlyFailure)) }
            }
        }
    }

    func testReportRequiresBothLifetimesMarkersResizeAndJoinedRejection() throws {
        let baseline = try report()
        XCTAssertTrue(baseline.passed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: baseline.json()) as? [String: Any])
        XCTAssertEqual(object["passed"] as? Bool, true)
        XCTAssertLessThan(try baseline.json().count, 16 * 1_024)
        for changes: [String: Any] in [
            ["stopJoined": false], ["lateReadRejected": false], ["sourceCloseObserved": false],
            ["sourceCloseReason": "stopped"], ["sourceStopJoined": false], ["sourceLateReadRejected": false],
            ["deadlineTriggered": true], ["cancellationObserved": true], ["containmentRequired": true],
            ["screenRecordingPreflight": false], ["supportedSystem": false], ["frames": []],
            ["failure": "markerMismatch"], ["retirementFailure": "stopFailed"], ["schema": "other"]
        ] {
            XCTAssertFalse(try replacing(baseline, changes).passed, "Accepted \(changes)")
        }
        var frames = try XCTUnwrap(object["frames"] as? [[String: Any]])
        frames[3]["generation"] = frames[0]["generation"]
        XCTAssertFalse(try replacing(baseline, ["frames": frames]).passed, "One stopped lifetime cannot qualify source closure")
        frames = try XCTUnwrap(object["frames"] as? [[String: Any]])
        frames[1]["sequence"] = frames[0]["sequence"]
        XCTAssertFalse(try replacing(baseline, ["frames": frames]).passed)
        frames = try XCTUnwrap(object["frames"] as? [[String: Any]])
        frames[2]["width"] = 400; frames[2]["height"] = 640
        XCTAssertFalse(try replacing(baseline, ["frames": frames]).passed, "Aspect alone cannot prove controlled transpose")
    }

    func testPreflightEvidenceIsNotCaptureQualificationAndReportBytesAreBounded() throws {
        var value = CaptureQualificationReport(mode: "preflight")
        XCTAssertFalse(value.passed)
        value.supportedSystem = true; value.screenRecordingPreflight = true
        XCTAssertTrue(value.passed)
        XCTAssertFalse(try replacing(value, ["mode": "capture-self-window"]).passed)
        var oversized = try report()
        oversized.imageDirectory = String(repeating: "x", count: 16 * 1_024)
        XCTAssertThrowsError(try oversized.json())
    }

    func testReportWireBoundIncludesFinalNewline() throws {
        var value = CaptureQualificationReport(mode: "preflight")
        value.imageDirectory = ""
        let overhead = try value.json().count
        value.imageDirectory = String(repeating: "x", count: 16 * 1_024 - overhead)
        let exact = try value.json()
        XCTAssertEqual(exact.count, 16 * 1_024)
        XCTAssertEqual(exact.last, 10)
        value.imageDirectory?.append("x")
        XCTAssertThrowsError(try value.json())
    }

    func testImagesUseFreshPrivateRootFixedExclusiveNamesAndByteBounds() throws {
        var images: CaptureQualificationImages? = try .init()
        let root = try XCTUnwrap(images?.path)
        defer { images = nil; try? FileManager.default.removeItem(atPath: root) }
        XCTAssertTrue(root.hasPrefix("/private/tmp/tron-capture-qualification."))
        var info = stat()
        XCTAssertEqual(lstat(root, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let bytes = try synthetic(stage: .initial).jpeg
        try images?.write(bytes, stage: .initial)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root + "/initial.jpg")), bytes)
        XCTAssertEqual(lstat(root + "/initial.jpg", &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertThrowsError(try images?.write(bytes, stage: .initial))
        XCTAssertThrowsError(try images?.write(Data(), stage: .changed))
        XCTAssertThrowsError(try images?.write(Data(repeating: 0, count: 2 * 1_024 * 1_024 + 1), stage: .changed))
        try FileManager.default.createSymbolicLink(atPath: root + "/changed.jpg", withDestinationPath: root + "/initial.jpg")
        XCTAssertThrowsError(try images?.write(bytes, stage: .changed))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root + "/initial.jpg")), bytes)
    }

    func testImagesRejectReplacedDirectoryWithoutFollowingIt() throws {
        var images: CaptureQualificationImages? = try .init()
        let root = try XCTUnwrap(images?.path), moved = root + "-moved"
        defer {
            images = nil
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: moved)
        }
        try FileManager.default.moveItem(atPath: root, toPath: moved)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try images?.write(Data([1]), stage: .initial))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved), [])
    }

    private func report() throws -> CaptureQualificationReport {
        var value = CaptureQualificationReport(mode: "capture-self-window")
        value.supportedSystem = true; value.screenRecordingPreflight = true
        let first = UUID(), second = UUID()
        value.frames = try CaptureQualificationStage.allCases.enumerated().map { index, stage in
            try CaptureQualificationJPEG.inspect(synthetic(stage: stage, generation: index == 3 ? second : first,
                                                           sequence: UInt64(index + 1)), stage: stage)
        }
        value.stopJoined = true; value.lateReadRejected = true; value.sourceCloseObserved = true
        value.sourceCloseReason = "sourceUnavailable"; value.sourceStopJoined = true; value.sourceLateReadRejected = true
        return value
    }

    private func replacing(_ report: CaptureQualificationReport, _ changes: [String: Any]) throws -> CaptureQualificationReport {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: report.json()) as? [String: Any])
        value.merge(changes) { _, new in new }
        return try JSONDecoder().decode(CaptureQualificationReport.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func synthetic(stage: CaptureQualificationStage, generation: UUID = UUID(), sequence: UInt64 = 1,
                           width suppliedWidth: Int? = nil, height suppliedHeight: Int? = nil,
                           solid: Bool = false, flipRows: Bool = false) throws -> NativeWindowCaptureFrame {
        let portrait = stage == .resized || stage == .sourceCloseBaseline
        let width = suppliedWidth ?? (portrait ? 200 : 320), height = suppliedHeight ?? (portrait ? 320 : 200)
        let colors: [[UInt8]]
        switch stage {
        case .initial: colors = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
        case .changed: colors = [[0, 255, 255], [255, 0, 255], [255, 255, 0], [0, 0, 255]]
        case .resized, .sourceCloseBaseline: colors = [[0, 255, 0], [0, 0, 255], [255, 0, 0], [0, 255, 255]]
        }
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    let row = flipRows ? height - y - 1 : y
                    let index = solid ? 0 : (row < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                    for channel in 0..<3 { buffer[(y * width + x) * 4 + channel] = colors[index][channel] }
                    buffer[(y * width + x) * 4 + 3] = 255
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: rgba as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return .init(generation: generation, sequence: sequence, jpeg: data as Data, width: width, height: height)
    }
}

/// Only the SDK-facing producer is replaced; the qualifier's actual outcome
/// inspection/admission reads the real NativeWindowCapture result and diagnostics.
private struct QualificationStopPlatform: NativeWindowCapturePlatform {
    let stream: QualificationStopStream
    func validate() throws {}
    func makeStream(limits: NativeWindowCaptureLimits,
                    output: @escaping @Sendable (NativeWindowCaptureOutput) -> Void) throws -> any NativeWindowCaptureStream {
        stream.install(output)
        return stream
    }
}
private final class QualificationStopStream: NativeWindowCaptureStream, @unchecked Sendable {
    let retirementFailure: NativeWindowCaptureError?
    private let lock = NSLock()
    private var output: (@Sendable (NativeWindowCaptureOutput) -> Void)?
    init(diagnostic: NativeWindowCaptureError?) { retirementFailure = diagnostic }
    func install(_ value: @escaping @Sendable (NativeWindowCaptureOutput) -> Void) { lock.withLock { output = value } }
    func fail(_ error: NativeWindowCaptureError) { lock.withLock { output }?(.failed(error)) }
    func start() async throws {}
    func requestStop() {}
    func stopAndJoin() async -> NativeWindowCaptureJoin { .joined }
}
