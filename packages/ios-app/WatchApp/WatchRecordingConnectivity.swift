import Foundation
import WatchConnectivity

/// Transfers immutable Watch-owned source files after Stop. WatchConnectivity is
/// only a custody hop; transfer completion is never treated as a Gateway receipt.
@MainActor
final class WatchRecordingConnectivity: NSObject, @preconcurrency WCSessionDelegate {
    static let shared = WatchRecordingConnectivity()
    private let session = WCSession.default
    private let destinationKey = "watchRecording.destination.v1"
    private let receiptStatusKey = "watchRecording.receipts.v1"
    private let assignmentStatusKey = "watchRecording.assignments.v1"
    private var pending: [(WatchRecordingManifest, WatchRecordingStore)] = []

    var savedRecordingIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: receiptStatusKey) ?? [])
    }

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    var configuredDestination: WatchRecordingDestinationV1? {
        guard let data = UserDefaults.standard.data(forKey: destinationKey) else { return nil }
        return try? JSONDecoder().decode(WatchRecordingDestinationV1.self, from: data)
    }

    func enqueue(_ manifest: WatchRecordingManifest, store: WatchRecordingStore) async {
        guard WCSession.isSupported() else { return }
        pending.removeAll { $0.0.recordingId == manifest.recordingId }
        pending.append((manifest, store))
        guard session.activationState == .activated else { return }
        drainPending()
    }

    private func drainPending() {
        let queued = pending
        pending.removeAll()
        for (manifest, store) in queued {
            for segment in manifest.segments {
            let url = store.segmentURL(recordingID: manifest.recordingId, number: segment.segment)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let metadata: [String: Any] = [
                "schemaVersion": 1,
                "recordingId": manifest.recordingId.uuidString.lowercased(),
                "segmentCount": manifest.segments.count,
                "segment": segment.segment,
                "fileName": segment.fileName,
                "byteCount": segment.byteCount,
                "sha256": segment.sha256,
                "startedAt": manifest.startedAt.timeIntervalSince1970,
                "stoppedAt": (manifest.stoppedAt ?? Date()).timeIntervalSince1970,
                "stopReason": manifest.stopReason,
                "recoveryStatus": manifest.recoveryStatus,
                "startedMonotonicMilliseconds": segment.startedMonotonicMilliseconds,
                "durationMilliseconds": segment.durationMilliseconds,
                "pauseBeforeMilliseconds": segment.pauseBeforeMilliseconds,
                "frameCount": segment.frameCount,
                "codec": segment.codec,
                "format": segment.format,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "platformVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "destinationProfileId": manifest.destination?.profileId as Any? ?? NSNull(),
                "destinationMachineId": manifest.destination?.machineId as Any? ?? NSNull(),
                "destinationConfigurationRevision": manifest.destination?.configurationRevision as Any? ?? NSNull()
            ]
            session.transferFile(url, metadata: metadata)
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in drainPending() }
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let profileId = applicationContext["recordingDestinationProfileId"] as? String,
              !profileId.isEmpty, let machineId = applicationContext["recordingDestinationMachineId"] as? String,
              !machineId.isEmpty, let revision = applicationContext["recordingDestinationRevision"] as? Int64,
              revision >= 0 else { return }
        let destination = WatchRecordingDestinationV1(profileId: profileId, machineId: machineId,
                                                       configurationRevision: revision)
        guard let data = try? JSONEncoder().encode(destination) else { return }
        UserDefaults.standard.set(data, forKey: destinationKey)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let recordingID = userInfo["recordingAssignmentId"] as? String,
           UUID(uuidString: recordingID)?.uuidString.lowercased() == recordingID,
           let profileID = userInfo["recordingAssignmentProfileId"] as? String, !profileID.isEmpty,
           let machineID = userInfo["recordingAssignmentMachineId"] as? String, !machineID.isEmpty {
            var assignments = UserDefaults.standard.dictionary(forKey: assignmentStatusKey) as? [String: [String: String]] ?? [:]
            assignments[recordingID] = ["profileId": profileID, "machineId": machineID]
            UserDefaults.standard.set(assignments, forKey: assignmentStatusKey)
            return
        }
        guard let recordingID = userInfo["recordingReceiptId"] as? String,
              let uuid = UUID(uuidString: recordingID), uuid.uuidString.lowercased() == recordingID,
              let receipt = userInfo["recordingReceipt"] as? [String: Any],
              receipt["schemaVersion"] as? Int == 1,
              receipt["recordingId"] as? String == recordingID,
              let machineID = receipt["destinationId"] as? String, !machineID.isEmpty,
              receipt["sourceDeviceId"] is String,
              receipt["contentSha256"] is String,
              receipt["totalBytes"] is NSNumber,
              receipt["segmentCount"] is NSNumber,
              let capture = receipt["capture"] as? [String: Any],
              capture["schemaVersion"] as? Int == 1 else { return }
        Task { @MainActor in
            let originalDestination: WatchRecordingDestinationV1?
            if let store = try? WatchRecordingStore() {
                originalDestination = try? await store.destination(recordingID: uuid)
            } else {
                originalDestination = nil
            }
            let assigned = (UserDefaults.standard.dictionary(forKey: self.assignmentStatusKey) as? [String: [String: String]])?[recordingID]
            guard originalDestination?.machineId == machineID || assigned?["machineId"] == machineID else { return }
            var saved = UserDefaults.standard.stringArray(forKey: receiptStatusKey) ?? []
            if !saved.contains(recordingID) { saved.append(recordingID) }
            UserDefaults.standard.set(saved, forKey: receiptStatusKey)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {}
}
