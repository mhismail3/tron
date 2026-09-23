import CryptoKit
import Darwin
import Foundation
import WatchConnectivity

/// Takes custody synchronously in WCSession's file callback. The temporary
/// callback URL is not durable; move must finish before this method returns.
final class WatchRecordingInbox: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchRecordingInbox()
    private let session = WCSession.default
    private let root: URL?
    private let lock = NSLock()
    private let maximumSegmentBytes: Int64 = 64 * 1_024 * 1_024
    private let maximumInboxBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private let minimumFreeBytes: Int64 = 1 * 1_024 * 1_024 * 1_024

    private override init() {
        if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true) {
            let inbox = support.appendingPathComponent("WatchRecordingInbox", isDirectory: true)
            root = (try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)) == nil ? nil : inbox
        } else {
            root = nil
        }
        super.init()
        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }
    }

    @MainActor
    func persistVerifiedReceipt(recordingDirectory: URL, recordingID: String, receipt: Data) throws {
        guard recordingID == recordingDirectory.lastPathComponent,
              recordingDirectory.deletingLastPathComponent() == root else { throw RecordingInboxError.invalidDestination }
        let receiptURL = recordingDirectory.appendingPathComponent("commit.json")
        try receipt.write(to: receiptURL, options: .atomic)
        try synchronizeFile(receiptURL)
        try synchronizeDirectory(recordingDirectory)
        relayReceipt(recordingID: recordingID, receipt: receipt)
    }

    @MainActor
    func relayReceipt(recordingID: String, receipt: Data) {
        guard WCSession.isSupported(), let value = try? JSONSerialization.jsonObject(with: receipt),
              let receiptObject = value as? [String: Any],
              receiptObject["recordingId"] as? String == recordingID else { return }
        // Application context is coalescing state (the current destination), not
        // a receipt queue. User info preserves every recording's exact receipt.
        session.transferUserInfo(["recordingReceiptId": recordingID, "recordingReceipt": receiptObject])
    }

    @MainActor
    func assignRecording(recordingID: String, profileId: String, machineId: String) throws {
        guard let root, UUID(uuidString: recordingID)?.uuidString.lowercased() == recordingID,
              !profileId.isEmpty, !machineId.isEmpty else { throw RecordingInboxError.invalidDestination }
        let directory = root.appendingPathComponent(recordingID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { throw RecordingInboxError.invalidDestination }
        let assignment = directory.appendingPathComponent("destination.json")
        let data = try JSONSerialization.data(withJSONObject: ["profileId": profileId, "machineId": machineId], options: [.sortedKeys])
        try data.write(to: assignment, options: .atomic)
        try synchronizeFile(assignment)
        try synchronizeDirectory(directory)
        if WCSession.isSupported() {
            session.transferUserInfo(["recordingAssignmentId": recordingID, "recordingAssignmentProfileId": profileId,
                                      "recordingAssignmentMachineId": machineId])
        }
    }

    @MainActor
    func configureRecordingDestination(profileId: String, machineId: String) throws {
        guard !profileId.isEmpty, !machineId.isEmpty,
              WCSession.isSupported() else { throw RecordingInboxError.invalidDestination }
        let defaults = UserDefaults.standard
        let revision = defaults.integer(forKey: "watchRecording.destinationRevision") + 1
        let context: [String: Any] = [
            "recordingDestinationProfileId": profileId,
            "recordingDestinationMachineId": machineId,
            "recordingDestinationRevision": revision
        ]
        try session.updateApplicationContext(context)
        defaults.set(revision, forKey: "watchRecording.destinationRevision")
        defaults.set(profileId, forKey: "watchRecording.destinationProfileId")
        defaults.set(machineId, forKey: "watchRecording.destinationMachineId")
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // Keep all custody work synchronous: returning before the move permits
        // WatchConnectivity to remove its temporary source file.
        lock.lock()
        defer { lock.unlock() }
        guard let metadata = file.metadata,
              let recording = metadata["recordingId"] as? String,
              let uuid = UUID(uuidString: recording), uuid.uuidString.lowercased() == recording,
              let number = metadata["segment"] as? Int, (1...512).contains(number),
              let name = metadata["fileName"] as? String, name == String(format: "%06d.caf", number),
              let size = metadata["byteCount"] as? Int64, size > 0, size <= maximumSegmentBytes,
              let digest = metadata["sha256"] as? String, digest.count == 64 else { return }
        guard let root else { return }
        guard hasAdmissionCapacity(root: root, incomingBytes: size) else {
            UserDefaults.standard.set("Phone storage is low. Free space; the Watch source remains available for retry.", forKey: "watchRecording.inboxIssue")
            return
        }
        let directory = root.appendingPathComponent(recording, isDirectory: true)
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try synchronizeDirectory(root)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            let incoming = try Data(contentsOf: file.fileURL, options: .mappedIfSafe)
            let actualDigest = SHA256.hash(data: incoming).map { String(format: "%02x", $0) }.joined()
            guard Int64(incoming.count) == size, actualDigest == digest else { return }
            let index = directory.appendingPathComponent(String(format: "%06d.json", number))
            if FileManager.default.fileExists(atPath: destination.path) {
                let existing = try Data(contentsOf: destination, options: .mappedIfSafe)
                guard existing.count == incoming.count, SHA256.hash(data: existing).map({ String(format: "%02x", $0) }).joined() == digest else { return }
                if !FileManager.default.fileExists(atPath: index.path) {
                    try persist(metadata, at: index)
                }
                signalDeliveryCoordinator()
                return
            }
            // Publish recovery metadata before move. A crash before the move
            // leaves an index that a repeated Watch transfer can complete.
            try persist(metadata, at: index)
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            try synchronizeFile(destination)
            try synchronizeDirectory(directory)
            UserDefaults.standard.removeObject(forKey: "watchRecording.inboxIssue")
            signalDeliveryCoordinator()
        } catch {
            // Never delete the Watch source or an admitted iPhone copy on error.
        }
    }

    private func signalDeliveryCoordinator() {
        Task { @MainActor in WatchRecordingDeliveryCoordinator.shared.inboxReceived() }
    }

    private func hasAdmissionCapacity(root: URL, incomingBytes: Int64) -> Bool {
        do {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))
            var retained: Int64 = 0
            while let url = enumerator?.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                retained += Int64(values.fileSize ?? 0)
                if retained > maximumInboxBytes { return false }
            }
            let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            guard let free, free >= minimumFreeBytes + incomingBytes,
                  retained <= maximumInboxBytes - incomingBytes else { return false }
            return true
        } catch { return false }
    }

    private func persist(_ metadata: [String: Any], at url: URL) throws {
        let bytes = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes])
        try bytes.write(to: url, options: .atomic)
        try synchronizeFile(url)
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func synchronizeFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

enum RecordingInboxError: Error { case invalidDestination }
