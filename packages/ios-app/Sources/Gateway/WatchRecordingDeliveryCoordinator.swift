import CryptoKit
import Foundation
import Observation

struct WatchRecordingDeliveryPlan {
    static func availableSlots(maximum: Int, outstanding: Int) -> Int { max(0, maximum - outstanding) }
    static func retryDelay(afterAttempt attempts: Int) -> TimeInterval? {
        guard (1..<5).contains(attempts) else { return nil }
        return TimeInterval(min(60, 2 << min(attempts, 5)))
    }
    static func isAuthorizationFailure(_ status: Int) -> Bool { status == 401 || status == 403 }
    static func isTransientFailure(_ status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }
    static func mayCompleteBackgroundEvents(didFinishEvents: Bool, drainBusy: Bool) -> Bool {
        didFinishEvents && !drainBusy
    }
    static func pendingSegments(files: [WatchRecordingFiles], confirmed: Set<Int>, active: [Int]) -> [WatchRecordingFiles] {
        let inFlight = Set(active)
        return files.filter { !confirmed.contains($0.number) && !inFlight.contains($0.number) }
    }
    static func canFinalize(files: [WatchRecordingFiles], confirmed: Set<Int>, activeFinalize: Bool) -> Bool {
        !activeFinalize && !files.isEmpty && files.allSatisfy { confirmed.contains($0.number) }
    }
}

struct WatchRecordingFiles {
    let number: Int
    let audioURL: URL
    let metadataURL: URL
}

/// Owns the durable HTTP protocol for Watch recordings; task descriptions make
/// background URLSession work recoverable without persisting credentials.
@MainActor
@Observable
final class WatchRecordingDeliveryCoordinator: NSObject {
    static let shared = WatchRecordingDeliveryCoordinator(profiles: GatewayProfileStore())
    private let maximumOutstandingTasks = 2
    private(set) var status = "Watch recordings remain on this iPhone until a Mac receipt is verified."
    private let profiles: GatewayProfileStore
    private let root: URL
    private let stateURL: URL
    private var confirmed: [String: Set<Int>] = [:]
    private var attempts: [String: Int] = [:]
    private var retryNotBefore: [String: Date] = [:]
    private var busy = false
    private var drainRequested = false
    private var backgroundEventsFinished = false
    private var session: URLSession!
    private var responseData: [Int: Data] = [:]
    private var finishEvents: (() -> Void)?

    init(profiles: GatewayProfileStore) {
        self.profiles = profiles
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        root = support.appendingPathComponent("WatchRecordingInbox", isDirectory: true)
        stateURL = support.appendingPathComponent("WatchRecordingDelivery.json")
        super.init()
        if FileManager.default.fileExists(atPath: stateURL.path) {
            if let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode([String: [Int]].self, from: data) {
                confirmed = state.mapValues(Set.init)
            } else {
                status = "Delivery state is unreadable. Originals are retained; retry is available."
            }
        }
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.tron.mobile.watch-recording-upload.v1")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // A serial main-operation delegate queue preserves callback order and enforces
        // the synchronous MainActor delegate handling below.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
    }

    func restoreAndDrain() { drain() }
    func retry() { attempts.removeAll(); retryNotBefore.removeAll(); drain() }
    func inboxReceived() { drain() }
    func setStatus(_ value: String) { status = value }

    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundEventsFinished = false
        finishEvents = completion
        completeBackgroundEventsIfReady()
        drain()
    }

    private func drain() {
        guard !busy else { drainRequested = true; return }
        busy = true
        drainRequested = false
        Task { @MainActor in
            defer {
                busy = false
                completeBackgroundEventsIfReady()
                if drainRequested { drain() }
            }
            do {
                try profiles.reload()
                let tasks = await session.allTasks
                let active = Set(tasks.compactMap { parse($0.taskDescription)?.key })
                let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                var scheduled = 0
                var availableSlots = WatchRecordingDeliveryPlan.availableSlots(maximum: maximumOutstandingTasks,
                                                                                 outstanding: tasks.filter { parse($0.taskDescription) != nil }.count)
                for folder in folders where availableSlots > 0 && (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let id = folder.lastPathComponent
                    guard let inventory = try? Self.recordingFiles(in: folder), !inventory.isEmpty,
                          let metadata = try? Self.json(inventory[0].metadataURL),
                          let destination = Self.destination(folder: folder, metadata: metadata),
                          let profile = profiles.profiles.first(where: { $0.id == destination.profileID && $0.machineId == destination.machineID }),
                          profile.isEnabled, let deviceID = profile.deviceId, let token = profiles.token(for: profile),
                          let count = metadata["segmentCount"] as? Int, count == inventory.count,
                          inventory.enumerated().allSatisfy({ $0.element.number == $0.offset + 1 }) else { continue }
                    if Self.receiptIsValid(at: folder.appendingPathComponent("commit.json"), files: inventory, profile: profile) { continue }
                    let accepted = confirmed[id] ?? []
                    let pending = WatchRecordingDeliveryPlan.pendingSegments(files: inventory, confirmed: accepted,
                                                                             active: tasks.compactMap { parse($0.taskDescription) }.filter { $0.recordingID == id }.compactMap(\.segment))
                    for file in pending where availableSlots > 0 {
                        let key = "\(id):\(file.number)"
                        guard !active.contains(key), (attempts[key] ?? 0) < 5, (retryNotBefore[key] ?? .distantPast) <= Date(),
                              let request = try? Self.segmentRequest(profile: profile, file: file, recordingID: id, token: token) else { continue }
                        attempts[key, default: 0] += 1
                        let task = session.uploadTask(with: request, fromFile: file.audioURL)
                        task.taskDescription = Self.description(recordingID: id, segment: file.number)
                        task.resume(); scheduled += 1; availableSlots -= 1
                    }
                    if availableSlots > 0, WatchRecordingDeliveryPlan.canFinalize(files: inventory, confirmed: accepted,
                                                              activeFinalize: active.contains("\(id):finalize")) {
                        let key = "\(id):finalize"
                        guard !active.contains(key), (attempts[key] ?? 0) < 5, (retryNotBefore[key] ?? .distantPast) <= Date(),
                              let request = try? Self.finalizeRequest(profile: profile, deviceID: deviceID, token: token, recordingID: id, files: inventory, metadata: metadata) else { continue }
                        attempts[key, default: 0] += 1
                        let body = folder.appendingPathComponent("finalize-request.json")
                        guard (try? request.httpBody?.write(to: body, options: .atomic)) != nil else { continue }
                        var fileRequest = request
                        fileRequest.httpBody = nil
                        let task = session.uploadTask(with: fileRequest, fromFile: body)
                        task.taskDescription = Self.description(recordingID: id, segment: nil)
                        task.resume(); scheduled += 1; availableSlots -= 1
                    }
                }
                if scheduled > 0 { status = "Uploading Watch recordings in the background. Originals remain retained." }
                else if tasks.isEmpty { status = "No recordings are ready for delivery. Watch and iPhone originals are retained." }
                persistState()
            } catch {
                status = "Gateway profiles could not be reloaded. Recordings remain retained."
            }
        }
    }

    private func completeBackgroundEventsIfReady() {
        guard WatchRecordingDeliveryPlan.mayCompleteBackgroundEvents(didFinishEvents: backgroundEventsFinished, drainBusy: busy),
              let completion = finishEvents else { return }
        finishEvents = nil
        completion()
    }

    private func scheduleRetry(for task: URLSessionTask) {
        guard let key = parse(task.taskDescription),
              let delay = WatchRecordingDeliveryPlan.retryDelay(afterAttempt: attempts[key.key] ?? 0) else { return }
        retryNotBefore[key.key] = Date().addingTimeInterval(TimeInterval(delay))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            drain()
        }
    }

    private func taskFinished(_ task: URLSessionTask, data: Data) {
        defer { drain() }
        guard let key = parse(task.taskDescription), let http = task.response as? HTTPURLResponse,
              data.count <= 256 * 1024, (key.segment == nil ? http.statusCode == 200 : http.statusCode == 201),
              let folder = try? Self.folder(root: root, id: key.recordingID),
              let files = try? Self.recordingFiles(in: folder), !files.isEmpty,
              let metadata = try? Self.json(files[0].metadataURL) else {
            if let http = task.response as? HTTPURLResponse, WatchRecordingDeliveryPlan.isAuthorizationFailure(http.statusCode) {
                status = "Gateway authorization needs attention. Originals remain retained."
            } else if let http = task.response as? HTTPURLResponse,
                      WatchRecordingDeliveryPlan.isTransientFailure(http.statusCode) {
                status = "Gateway is temporarily unavailable. Originals remain retained; delivery will retry."
                scheduleRetry(for: task)
            } else {
                status = "Delivery needs attention. Originals remain retained for a manual retry."
            }
            return
        }
        if let segment = key.segment {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let receipt = object["receipt"] as? [String: Any],
                  receipt["recordingId"] as? String == key.recordingID,
                  receipt["segment"] as? Int == segment,
                  let file = files.first(where: { $0.number == segment }),
                  let segmentMetadata = try? Self.json(file.metadataURL),
                  (receipt["size"] as? NSNumber)?.intValue == (segmentMetadata["byteCount"] as? Int),
                  receipt["sha256"] as? String == (segmentMetadata["sha256"] as? String) else { status = "Invalid segment response; originals retained."; return }
            confirmed[key.recordingID, default: []].insert(segment)
            attempts.removeValue(forKey: key.key)
            retryNotBefore.removeValue(forKey: key.key)
            persistState()
        } else {
            guard let destination = Self.destination(folder: folder, metadata: metadata),
                  let profile = profiles.profiles.first(where: { $0.id == destination.profileID && $0.machineId == destination.machineID }),
                  let deviceID = profile.deviceId,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let receipt = object["receipt"] as? [String: Any],
                  Self.validateReceipt(receipt, recordingID: key.recordingID, profile: profile, deviceID: deviceID, files: files, metadata: metadata),
                  let bytes = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) else { status = "Invalid final receipt; originals retained."; return }
            do {
                try WatchRecordingInbox.shared.persistVerifiedReceipt(recordingDirectory: folder, recordingID: key.recordingID, receipt: bytes)
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("finalize-request.json"))
                status = "A Mac receipt was verified. Watch and iPhone originals remain retained."
            } catch { status = "Could not persist verified receipt; originals retained." }
        }
    }

    private func persistState() {
        let value = confirmed.mapValues { $0.sorted() }
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            status = "Could not persist delivery progress. Originals remain retained; retry is available."
        }
    }

    private func parse(_ description: String?) -> (recordingID: String, segment: Int?, key: String)? {
        guard let description, let data = description.data(using: .utf8),
              let value = try? JSONDecoder().decode(TaskDescription.self, from: data) else { return nil }
        return (value.recordingID, value.segment, "\(value.recordingID):\(value.segment.map(String.init) ?? "finalize")")
    }

    private struct TaskDescription: Codable { let recordingID: String; let segment: Int? }
    private static func description(recordingID: String, segment: Int?) -> String {
        guard let data = try? JSONEncoder().encode(TaskDescription(recordingID: recordingID, segment: segment)),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func recordingFiles(in folder: URL) throws -> [WatchRecordingFiles] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).compactMap { url in
            guard url.pathExtension == "caf", let number = Int(url.deletingPathExtension().lastPathComponent) else { return nil }
            let metadata = folder.appendingPathComponent(String(format: "%06d.json", number))
            return FileManager.default.fileExists(atPath: metadata.path) ? WatchRecordingFiles(number: number, audioURL: url, metadataURL: metadata) : nil
        }.sorted { $0.number < $1.number }
    }
    static func destination(folder: URL, metadata: [String: Any]) -> (profileID: String, machineID: String)? {
        let assignmentURL = folder.appendingPathComponent("destination.json")
        if FileManager.default.fileExists(atPath: assignmentURL.path) {
            guard let assignment = try? json(assignmentURL),
                  let profileID = assignment["profileId"] as? String, !profileID.isEmpty,
                  let machineID = assignment["machineId"] as? String, !machineID.isEmpty else { return nil }
            return (profileID, machineID)
        }
        guard let profileID = metadata["destinationProfileId"] as? String,
              let machineID = metadata["destinationMachineId"] as? String else { return nil }
        return (profileID, machineID)
    }

    private static func json(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return object
    }
    private static func folder(root: URL, id: String) throws -> URL {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw URLError(.badURL) }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    private static func segmentRequest(profile: GatewayProfile, file: WatchRecordingFiles, recordingID: String, token: String) throws -> URLRequest {
        var request = try request(profile: profile, path: "/v1/recordings/\(recordingID)/segments/\(file.number)", token: token)
        let info = try json(file.metadataURL)
        let size = (try FileManager.default.attributesOfItem(atPath: file.audioURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= 64 * 1024 * 1024, let digest = info["sha256"] as? String else { throw URLError(.badServerResponse) }
        request.httpMethod = "PUT"; request.setValue(String(size), forHTTPHeaderField: "X-Recording-Size"); request.setValue(digest, forHTTPHeaderField: "X-Recording-SHA256"); request.setValue("\(size)", forHTTPHeaderField: "Content-Length")
        return request
    }
    static func finalizeRequest(profile: GatewayProfile, deviceID: String, token: String, recordingID: String, files: [WatchRecordingFiles], metadata: [String: Any]) throws -> URLRequest {
        let capture = try WatchRecordingMetadata.captureMetadata(files: files, metadata: metadata)
        var request = try request(profile: profile, path: "/v1/recordings/\(recordingID)/finalize", token: token)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "segmentCount": files.count, "capture": capture])
        _ = deviceID
        return request
    }
    private static func request(profile: GatewayProfile, path: String, token: String) throws -> URLRequest {
        guard let url = profile.httpURL(path: path), url.host == profile.host, url.port == profile.port else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 120); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); return request
    }
    static func aggregateDigest(_ files: [WatchRecordingFiles]) -> String {
        var aggregate = Data()
        for file in files {
            guard let bytes = try? Data(contentsOf: file.audioURL), let meta = try? json(file.metadataURL) else { return "" }
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard hash == meta["sha256"] as? String else { return "" }
            aggregate.append(Data("\(file.number):\(hash):\(bytes.count)\n".utf8))
        }
        return SHA256.hash(data: aggregate).map { String(format: "%02x", $0) }.joined()
    }
    static func validateReceipt(_ receipt: [String: Any], recordingID: String, profile: GatewayProfile, deviceID: String, files: [WatchRecordingFiles], metadata: [String: Any]) -> Bool {
        guard Set(receipt.keys) == Set(["schemaVersion", "recordingId", "destinationId", "sourceDeviceId", "finalizedAt", "contentSha256", "totalBytes", "segmentCount", "capture"]),
              receipt["schemaVersion"] as? Int == 1, receipt["recordingId"] as? String == recordingID,
              receipt["destinationId"] as? String == profile.machineId, receipt["sourceDeviceId"] as? String == deviceID,
              receipt["segmentCount"] as? Int == files.count,
              (receipt["totalBytes"] as? NSNumber)?.intValue == files.reduce(0, { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.audioURL.path)[.size] as? NSNumber)?.intValue ?? 0) }),
              receipt["contentSha256"] as? String == aggregateDigest(files),
              let stamp = receipt["finalizedAt"] as? String,
              Self.parseCanonicalDate(stamp) != nil,
              let capture = try? WatchRecordingMetadata.captureMetadata(files: files, metadata: metadata),
              let a = try? JSONSerialization.data(withJSONObject: capture, options: [.sortedKeys]),
              let b = try? JSONSerialization.data(withJSONObject: receipt["capture"] as Any, options: [.sortedKeys]) else { return false }
        return a == b
    }
    private static func parseCanonicalDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value), WatchRecordingMetadata.canonicalDate(date) == value else { return nil }
        return date
    }
    private static func receiptIsValid(at url: URL, files: [WatchRecordingFiles], profile: GatewayProfile) -> Bool {
        guard !files.isEmpty, let receipt = try? json(url),
              let first = try? json(files[0].metadataURL), let device = profile.deviceId,
              validateReceipt(receipt, recordingID: url.deletingLastPathComponent().lastPathComponent, profile: profile, deviceID: device, files: files, metadata: first) else { return false }
        return true
    }
}

extension WatchRecordingDeliveryCoordinator: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            let prior = responseData[dataTask.taskIdentifier] ?? Data()
            guard prior.count + data.count <= 256 * 1024 else { return }
            responseData[dataTask.taskIdentifier] = prior + data
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            let data = responseData.removeValue(forKey: task.taskIdentifier) ?? Data()
            if error == nil { taskFinished(task, data: data) }
            else { status = "Delivery failed; source copies are retained and will retry."; scheduleRetry(for: task); drain() }
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundEventsFinished = true
            completeBackgroundEventsIfReady()
        }
    }
}

extension URLSession {
    fileprivate var allTasks: [URLSessionTask] { get async { await withCheckedContinuation { continuation in getAllTasks { continuation.resume(returning: $0) } } } }
}
