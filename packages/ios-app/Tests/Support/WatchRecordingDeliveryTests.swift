import CryptoKit
import XCTest
@testable import TronMobile

final class WatchRecordingDeliveryTests: XCTestCase {
    func testSegmentsRemainPendingUntilConfirmedThenFinalizeBecomesEligible() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = (1...2).map { number in
            WatchRecordingFiles(number: number, audioURL: root.appendingPathComponent("\(number).caf"),
                                metadataURL: root.appendingPathComponent("\(number).json"))
        }
        XCTAssertEqual(WatchRecordingDeliveryPlan.pendingSegments(files: files, confirmed: [], active: [] ).map(\.number), [1, 2])
        XCTAssertFalse(WatchRecordingDeliveryPlan.canFinalize(files: files, confirmed: [1], activeFinalize: false))
        XCTAssertEqual(WatchRecordingDeliveryPlan.pendingSegments(files: files, confirmed: [], active: [1]).map(\.number), [2])
        XCTAssertTrue(WatchRecordingDeliveryPlan.canFinalize(files: files, confirmed: [1, 2], activeFinalize: false))
        XCTAssertFalse(WatchRecordingDeliveryPlan.canFinalize(files: files, confirmed: [1, 2], activeFinalize: true))
    }

    func testBackgroundCompletionWaitsForFinishEventAndPriorProcessing() {
        XCTAssertFalse(WatchRecordingDeliveryPlan.mayCompleteBackgroundEvents(didFinishEvents: false, drainBusy: false))
        XCTAssertFalse(WatchRecordingDeliveryPlan.mayCompleteBackgroundEvents(didFinishEvents: true, drainBusy: true))
        XCTAssertTrue(WatchRecordingDeliveryPlan.mayCompleteBackgroundEvents(didFinishEvents: true, drainBusy: false))
    }

    func testDrainCapsGlobalOutstandingWorkAndCoalescesSlots() {
        XCTAssertEqual(WatchRecordingDeliveryPlan.availableSlots(maximum: 2, outstanding: 0), 2)
        XCTAssertEqual(WatchRecordingDeliveryPlan.availableSlots(maximum: 2, outstanding: 3), 0)
        XCTAssertEqual(WatchRecordingDeliveryPlan.retryDelay(afterAttempt: 1), 4)
        XCTAssertEqual(WatchRecordingDeliveryPlan.retryDelay(afterAttempt: 4), 32)
        XCTAssertNil(WatchRecordingDeliveryPlan.retryDelay(afterAttempt: 5))
        XCTAssertTrue(WatchRecordingDeliveryPlan.isAuthorizationFailure(401))
        XCTAssertFalse(WatchRecordingDeliveryPlan.isTransientFailure(401))
        XCTAssertTrue(WatchRecordingDeliveryPlan.isTransientFailure(503))
        XCTAssertFalse(WatchRecordingDeliveryPlan.isTransientFailure(409))
    }

    @MainActor
    func testFinalizeAndReceiptUseGatewayFixtureAndProductionValidators() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = repository.appendingPathComponent("packages/gateway/test-fixtures/watch-recording-v1.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let expectedFinalize = try XCTUnwrap(fixture["finalizeRequest"] as? [String: Any])
        let expectedCapture = try XCTUnwrap(expectedFinalize["capture"] as? [String: Any])
        let expectedReceipt = try XCTUnwrap(fixture["commitReceipt"] as? [String: Any])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("synthetic production helper fixture bytes".utf8)
        let audio = root.appendingPathComponent("000001.caf")
        try bytes.write(to: audio)
        let metadataURL = root.appendingPathComponent("000001.json")
        let metadataObject: [String: Any] = [
            "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "byteCount": bytes.count, "appVersion": "1.0", "platformVersion": "26.0",
            "startedMonotonicMilliseconds": 0, "durationMilliseconds": 1000,
            "pauseBeforeMilliseconds": 0, "frameCount": 48000, "codec": "AAC", "format": "m4a"
        ]
        try JSONSerialization.data(withJSONObject: metadataObject).write(to: metadataURL)
        let files = [WatchRecordingFiles(number: 1, audioURL: audio, metadataURL: metadataURL)]
        let recording = "6f3241c1-496e-4dbd-b452-2c724937f5d0"
        let captureMetadata: [String: Any] = ["startedAt": 1_767_225_600.0, "stoppedAt": 1_767_225_601.0,
                                               "stopReason": "user", "recoveryStatus": "complete"]
        let capture = try WatchRecordingMetadata.captureMetadata(files: files, metadata: captureMetadata)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: capture, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: expectedCapture, options: [.sortedKeys]))
        let profile = GatewayProfile(id: "fixture-profile", label: "Fixture", host: "127.0.0.1", port: 9848,
                                     machineId: "gateway-machine-id", deviceId: "gateway-authenticated-device-id")
        let request = try WatchRecordingDeliveryCoordinator.finalizeRequest(profile: profile,
            deviceID: "gateway-authenticated-device-id", token: "fixture-token", recordingID: recording,
            files: files, metadata: captureMetadata)
        let actualFinalize = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: actualFinalize, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: expectedFinalize, options: [.sortedKeys]))
        var receipt = expectedReceipt
        receipt["contentSha256"] = WatchRecordingDeliveryCoordinator.aggregateDigest(files)
        receipt["totalBytes"] = bytes.count
        receipt["capture"] = capture
        XCTAssertTrue(WatchRecordingDeliveryCoordinator.validateReceipt(receipt, recordingID: recording,
            profile: profile, deviceID: "gateway-authenticated-device-id", files: files, metadata: captureMetadata))
        var mismatchedCaptureReceipt = receipt
        var mismatchedCapture = try XCTUnwrap(mismatchedCaptureReceipt["capture"] as? [String: Any])
        mismatchedCapture["startedAt"] = "2025-01-01T00:00:00.000Z"
        mismatchedCaptureReceipt["capture"] = mismatchedCapture
        XCTAssertFalse(WatchRecordingDeliveryCoordinator.validateReceipt(mismatchedCaptureReceipt, recordingID: recording,
            profile: profile, deviceID: "gateway-authenticated-device-id", files: files, metadata: captureMetadata))
    }

    @MainActor
    func testUnboundRecordingDestinationUsesExactPersistedAssignment() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(WatchRecordingDeliveryCoordinator.destination(folder: folder, metadata: ["destinationProfileId": NSNull(), "destinationMachineId": NSNull()]))
        try JSONSerialization.data(withJSONObject: ["profileId": "paired-profile", "machineId": "paired-machine"])
            .write(to: folder.appendingPathComponent("destination.json"))
        let destination = try XCTUnwrap(WatchRecordingDeliveryCoordinator.destination(folder: folder,
            metadata: ["destinationProfileId": "old-profile", "destinationMachineId": "old-machine"]))
        XCTAssertEqual(destination.profileID, "paired-profile")
        XCTAssertEqual(destination.machineID, "paired-machine")
    }

    func testCaptureDatesUseGatewayCanonicalFractionalUTC() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = ["startedAt": 1_735_689_600.125, "stoppedAt": 1_735_689_601.5]
        let segmentURL = root.appendingPathComponent("000001.json")
        try JSONSerialization.data(withJSONObject: ["appVersion": "1", "platformVersion": "26", "startedMonotonicMilliseconds": 0,
                                                     "durationMilliseconds": 1000, "pauseBeforeMilliseconds": 0,
                                                     "frameCount": 1, "codec": "AAC", "format": "caf"])
            .write(to: segmentURL)
        let files = [WatchRecordingFiles(number: 1, audioURL: root.appendingPathComponent("000001.caf"), metadataURL: segmentURL)]
        let capture = try WatchRecordingMetadata.captureMetadata(files: files, metadata: metadata)
        XCTAssertEqual(capture["startedAt"] as? String, "2025-01-01T00:00:00.125Z")
        XCTAssertEqual(capture["stoppedAt"] as? String, "2025-01-01T00:00:01.500Z")
    }
}
