import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import TronMobile

final class WatchRecordingStoreTests: XCTestCase {
    func testSegmentsArePersistedInOrderWithVerifiedBytesAndRecoveryDisposition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WatchRecordingStore(root: root)
        let id = UUID()
        try await store.begin(id: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        do {
            try await store.admitClosedSegment(recordingID: id, number: 513,
                                               startedMonotonicMilliseconds: 0, durationMilliseconds: 0,
                                               pauseBeforeMilliseconds: 0, frameCount: 0)
            XCTFail("segments beyond the Gateway's V1 limit must not be admitted")
        } catch { /* expected bounded recording inventory */ }

        for number in [2, 1] {
            let bytes = Data("segment-\(number)".utf8)
            try FileManager.default.createDirectory(at: store.segmentURL(recordingID: id, number: number).deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: store.segmentURL(recordingID: id, number: number))
            try await store.admitClosedSegment(recordingID: id, number: number,
                                               startedMonotonicMilliseconds: Int64(number * 1_000),
                                               durationMilliseconds: 1_000, pauseBeforeMilliseconds: 0,
                                               frameCount: 48_000)
        }
        try await store.finish(recordingID: id, stoppedAt: Date(timeIntervalSince1970: 1_700_000_002), recovered: true)
        let inventory = try await store.inventory()
        let manifest = try XCTUnwrap(inventory.first)

        XCTAssertEqual(manifest.segments.map(\.segment), [1, 2])
        XCTAssertEqual(manifest.segments.map(\.sha256), [1, 2].map { number in
            SHA256.hash(data: Data("segment-\(number)".utf8)).map { String(format: "%02x", $0) }.joined()
        })
        XCTAssertEqual(manifest.stopReason, "recovered-partial")
        XCTAssertEqual(manifest.recoveryStatus, "interrupted")
        XCTAssertEqual(try Data(contentsOf: store.segmentURL(recordingID: id, number: 1)), Data("segment-1".utf8))
    }

    func testCaptureMetadataMatchesGatewayV1ShapeAndUsesActualTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WatchRecordingStore(root: root)
        let id = UUID()
        try await store.begin(id: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let url = store.segmentURL(recordingID: id, number: 1)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
        try await store.admitClosedSegment(recordingID: id, number: 1,
                                           startedMonotonicMilliseconds: 123, durationMilliseconds: 250,
                                           pauseBeforeMilliseconds: 0, frameCount: 12_000)
        try await store.finish(recordingID: id, stoppedAt: Date(timeIntervalSince1970: 1_700_000_001))
        let inventory = try await store.inventory()
        let manifest = try XCTUnwrap(inventory.first)
        let metadata = try manifest.captureMetadata(appVersion: "1.0", platformVersion: "26.0")
        XCTAssertEqual(metadata.source.platform, "watchOS")
        XCTAssertEqual(metadata.timeline.map(\.segment), [1])
        XCTAssertEqual(metadata.timeline[0].codec, "lpcm")
        XCTAssertEqual(metadata.timeline[0].format, "caf")
        XCTAssertEqual(metadata.timeline[0].startMonotonicMilliseconds, 123)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(metadata)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schemaVersion", "source", "startedAt", "stoppedAt", "clockOffsetMilliseconds", "stopReason", "recoveryStatus", "timeline"]))
        XCTAssertEqual(Set(try XCTUnwrap(object["source"] as? [String: Any]).keys), Set(["appVersion", "platform", "platformVersion"]))
    }

    func testReadableCAFTailIsRecoveredAfterWriterHandleCloses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WatchRecordingStore(root: root)
        let id = UUID()
        try await store.begin(id: id, startedAt: Date())
        let url = store.segmentURL(recordingID: id, number: 1)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            try file.write(from: buffer)
        }
        try await store.recoverUnadmittedSegments(recordingID: id)
        try await store.finish(recordingID: id, stoppedAt: Date(), recovered: true)
        let inventory = try await store.inventory()
        let manifest = try XCTUnwrap(inventory.first)
        XCTAssertEqual(manifest.segments.map(\.segment), [1])
        XCTAssertEqual(manifest.segments[0].frameCount, 4_800)
        XCTAssertEqual(manifest.segments[0].durationMilliseconds, 100)
        XCTAssertEqual(manifest.recoveryStatus, "interrupted")
    }

    func testExistingSourceIsRetainedWhenRecoveryFinalizesManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WatchRecordingStore(root: root)
        let id = UUID()
        try await store.begin(id: id, startedAt: Date())
        let url = store.segmentURL(recordingID: id, number: 1)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data([0x43, 0x41, 0x46, 0x00])
        try original.write(to: url)

        try await store.finish(recordingID: id, stoppedAt: Date(), recovered: true)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let inventory = try await store.inventory()
        let recovered = try XCTUnwrap(inventory.first)
        XCTAssertEqual(recovered.recoveryStatus, "interrupted")
        XCTAssertTrue(recovered.segments.isEmpty, "an unadmitted open tail must not be represented as a complete segment")
    }
}
