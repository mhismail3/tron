import AVFoundation
import CryptoKit
import Foundation
import Darwin

struct WatchRecordingSegment: Codable, Identifiable, Sendable {
    let segment: Int
    let fileName: String
    let byteCount: Int64
    let sha256: String
    let startedMonotonicMilliseconds: Int64
    let durationMilliseconds: Int64
    let pauseBeforeMilliseconds: Int64
    let frameCount: Int64
    let codec: String
    let format: String
    var id: Int { segment }
}

struct WatchRecordingDestinationV1: Codable, Equatable, Sendable {
    let profileId: String
    let machineId: String
    let configurationRevision: Int64
}

struct WatchRecordingManifest: Codable, Identifiable, Sendable {
    let schemaVersion: Int
    let recordingId: UUID
    let startedAt: Date
    var stoppedAt: Date?
    var stopReason: String
    var recoveryStatus: String
    var segments: [WatchRecordingSegment]
    var destination: WatchRecordingDestinationV1? = nil
    var id: UUID { recordingId }

    func captureMetadata(appVersion: String, platformVersion: String, clockOffsetMilliseconds: Int64 = 0) throws -> CaptureMetadataV1 {
        guard let stoppedAt else { throw CaptureMetadataError.recordingNotStopped }
        return CaptureMetadataV1(
            schemaVersion: 1,
            source: .init(appVersion: appVersion, platform: "watchOS", platformVersion: platformVersion),
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            clockOffsetMilliseconds: clockOffsetMilliseconds,
            stopReason: stopReason,
            recoveryStatus: recoveryStatus,
            timeline: segments.map {
                .init(segment: $0.segment, startMonotonicMilliseconds: $0.startedMonotonicMilliseconds,
                      durationMilliseconds: $0.durationMilliseconds, pauseBeforeMilliseconds: $0.pauseBeforeMilliseconds,
                      frameCount: $0.frameCount, codec: $0.codec, format: $0.format)
            })
    }
}

enum CaptureMetadataError: Error { case recordingNotStopped }

struct CaptureMetadataV1: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let appVersion: String
        let platform: String
        let platformVersion: String
    }
    struct TimelineEntry: Codable, Equatable, Sendable {
        let segment: Int
        let startMonotonicMilliseconds: Int64
        let durationMilliseconds: Int64
        let pauseBeforeMilliseconds: Int64
        let frameCount: Int64
        let codec: String
        let format: String
    }
    let schemaVersion: Int
    let source: Source
    let startedAt: Date
    let stoppedAt: Date
    let clockOffsetMilliseconds: Int64
    let stopReason: String
    let recoveryStatus: String
    let timeline: [TimelineEntry]
}

struct RecordingSegmentTransferV1: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let recordingId: UUID
    let segment: Int
    let fileName: String
    let byteCount: Int64
    let sha256: String
    let startedAt: Date
    let stoppedAt: Date
    let stopReason: String
    let recoveryStatus: String
    let startedMonotonicMilliseconds: Int64
    let durationMilliseconds: Int64
    let pauseBeforeMilliseconds: Int64
    let frameCount: Int64
    let codec: String
    let format: String
}

actor WatchRecordingStore {
    nonisolated let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root: URL? = nil) throws {
        let base = try root ?? FileManager.default.url(for: .applicationSupportDirectory,
                                                        in: .userDomainMask, appropriateFor: nil, create: true)
        self.root = base.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: self.root.path)
    }

    func begin(id: UUID, startedAt: Date, destination: WatchRecordingDestinationV1? = nil) throws {
        let volume = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        let available = (volume[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available >= 1_073_741_824 else {
            throw StoreError.insufficientStorage
        }
        let directory = recordingDirectory(id)
        let segmentsDirectory = directory.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
        let protection = [FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.setAttributes(protection, ofItemAtPath: directory.path)
        try FileManager.default.setAttributes(protection, ofItemAtPath: segmentsDirectory.path)
        try Self.synchronizeDirectory(at: root)
        try Self.synchronizeDirectory(at: directory)
        let manifest = WatchRecordingManifest(schemaVersion: 1, recordingId: id, startedAt: startedAt,
                                               stoppedAt: nil, stopReason: "recovered-partial",
                                               recoveryStatus: "interrupted", segments: [], destination: destination)
        try persist(manifest, at: directory)
    }

    nonisolated func segmentURL(recordingID: UUID, number: Int) -> URL {
        root.appendingPathComponent(recordingID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(String(format: "%06d.caf", number))
    }

    func admitClosedSegment(recordingID: UUID, number: Int, startedMonotonicMilliseconds: Int64,
                            durationMilliseconds: Int64, pauseBeforeMilliseconds: Int64,
                            frameCount: Int64) throws {
        guard (1...512).contains(number) else { throw StoreError.segmentLimit }
        let url = segmentURL(recordingID: recordingID, number: number)
        try Self.synchronizeFile(at: url)
        try Self.synchronizeDirectory(at: url.deletingLastPathComponent())
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let segment = WatchRecordingSegment(segment: number, fileName: url.lastPathComponent,
                                            byteCount: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                            startedMonotonicMilliseconds: startedMonotonicMilliseconds,
                                            durationMilliseconds: durationMilliseconds, pauseBeforeMilliseconds: pauseBeforeMilliseconds,
                                            frameCount: frameCount, codec: "lpcm", format: "caf")
        var manifest = try read(recordingID)
        guard !manifest.segments.contains(where: { $0.segment == number }) else { throw StoreError.duplicateSegment }
        manifest.segments.append(segment)
        manifest.segments.sort { $0.segment < $1.segment }
        try persist(manifest, at: recordingDirectory(recordingID))
    }

    func recoverUnadmittedSegments(recordingID: UUID) throws {
        let manifest = try read(recordingID)
        var expected = (manifest.segments.map(\.segment).max() ?? 0) + 1
        var start = manifest.segments.last.map { $0.startedMonotonicMilliseconds + $0.durationMilliseconds } ?? 0
        while expected <= 512 {
            let url = segmentURL(recordingID: recordingID, number: expected)
            guard FileManager.default.fileExists(atPath: url.path) else { break }
            do {
                let audio = try AVAudioFile(forReading: url)
                let frames = Int64(audio.length)
                let sampleRate = audio.processingFormat.sampleRate
                guard frames > 0, sampleRate.isFinite, sampleRate > 0 else { break }
                let duration = Int64(Double(frames) / sampleRate * 1_000)
                try admitClosedSegment(recordingID: recordingID, number: expected,
                                       startedMonotonicMilliseconds: start,
                                       durationMilliseconds: duration, pauseBeforeMilliseconds: 0,
                                       frameCount: frames)
                start += duration
                expected += 1
            } catch { break }
        }
    }

    func finish(recordingID: UUID, stoppedAt: Date, recovered: Bool = false) throws {
        var manifest = try read(recordingID)
        manifest.stoppedAt = stoppedAt
        manifest.stopReason = recovered ? "recovered-partial" : "user"
        manifest.recoveryStatus = recovered ? "interrupted" : "complete"
        try persist(manifest, at: recordingDirectory(recordingID))
    }

    func destination(recordingID: UUID) throws -> WatchRecordingDestinationV1? {
        try read(recordingID).destination
    }

    func inventory() throws -> [WatchRecordingManifest] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.hasDirectoryPath }
            .compactMap { directory in
                guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
                return try? read(id)
            }.sorted { $0.startedAt > $1.startedAt }
    }

    private func recordingDirectory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    private func read(_ id: UUID) throws -> WatchRecordingManifest {
        try decoder.decode(WatchRecordingManifest.self, from: Data(contentsOf: recordingDirectory(id).appendingPathComponent("recording.json")))
    }
    private func persist(_ manifest: WatchRecordingManifest, at directory: URL) throws {
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("recording.json"), options: .atomic)
        try Self.synchronizeFile(at: directory.appendingPathComponent("recording.json"))
        try Self.synchronizeDirectory(at: directory)
    }
    static func synchronizeFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    enum StoreError: Error { case duplicateSegment, recordingNotStopped, insufficientStorage, segmentLimit }
}

/// Tracks segment admissions created in file-close order. The lock protects
/// callback-side append and MainActor-side draining.
private final class SegmentAdmissions: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Error>] = []
    func append(_ task: Task<Void, Error>) { lock.lock(); tasks.append(task); lock.unlock() }
    private func takePending() -> [Task<Void, Error>] {
        lock.lock(); defer { lock.unlock() }
        let pending = tasks
        tasks.removeAll(keepingCapacity: true)
        return pending
    }
    func drain() async throws {
        var firstFailure: Error?
        for task in takePending() {
            do { try await task.value } catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
    }
}

/// Copies each tap buffer before enqueueing it. The queue is bounded to eight
/// owned snapshots; once enqueued, only `queue` reads or mutates writer state.
/// Queue saturation rejects capture instead of dropping audio silently.
private final class WatchAudioFileWriter: @unchecked Sendable {
    private struct OwnedBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init(copying source: AVAudioPCMBuffer) throws {
            guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { throw WriterError.copyFailed }
            copy.frameLength = source.frameLength
            let channelCount = Int(source.format.channelCount)
            if let sourceChannels = source.floatChannelData, let destinationChannels = copy.floatChannelData {
                let byteCount = Int(source.frameLength) * MemoryLayout<Float>.size
                for channel in 0..<channelCount { memcpy(destinationChannels[channel], sourceChannels[channel], byteCount) }
            } else if let sourceChannels = source.int16ChannelData, let destinationChannels = copy.int16ChannelData {
                let byteCount = Int(source.frameLength) * MemoryLayout<Int16>.size
                for channel in 0..<channelCount { memcpy(destinationChannels[channel], sourceChannels[channel], byteCount) }
            } else {
                throw WriterError.copyFailed
            }
            buffer = copy
        }
    }
    private enum WriterError: Error { case copyFailed, queueFull, segmentLimit }
    private let queue = DispatchQueue(label: "com.tron.watch.recording-writer", qos: .userInitiated)
    private let gate = NSLock()
    private var pending = 0
    private let capacity = 8
    private var file: AVAudioFile?
    private var recordingID: UUID?
    private var root: URL?
    private var segmentNumber = 0
    private var segmentStart: UInt64 = 0
    private var frames: Int64 = 0
    private var segmentPauseBefore: Int64 = 0
    private var pauseBeforeNextSegment: Int64 = 0
    private var failed = false
    private var rotationFrameLimit: Int64 = 0
    private let onClosed: @Sendable (UUID, Int, Int64, Int64, Int64, Int64) -> Void
    private let onFailure: @Sendable () -> Void

    init(onClosed: @escaping @Sendable (UUID, Int, Int64, Int64, Int64, Int64) -> Void,
         onFailure: @escaping @Sendable () -> Void) {
        self.onClosed = onClosed
        self.onFailure = onFailure
    }

    func begin(id: UUID, root: URL) {
        queue.sync { recordingID = id; self.root = root; segmentNumber = 0; frames = 0; failed = false }
    }

    func append(_ source: AVAudioPCMBuffer) {
        gate.lock()
        guard pending < capacity else { gate.unlock(); onFailure(); return }
        pending += 1
        gate.unlock()
        let owned: OwnedBuffer
        do { owned = try OwnedBuffer(copying: source) } catch {
            gate.lock(); pending -= 1; gate.unlock(); onFailure(); return
        }
        queue.async { [self] in
            defer { gate.lock(); pending -= 1; gate.unlock() }
            guard !failed else { return }
            do {
                if file == nil { try open(format: owned.buffer.format) }
                try file?.write(from: owned.buffer)
                frames += Int64(owned.buffer.frameLength)
                if frames >= rotationFrameLimit { closeCurrent() }
            } catch { failed = true; onFailure() }
        }
    }

    func close(pauseMilliseconds: Int64 = 0) {
        queue.sync { closeCurrent(); pauseBeforeNextSegment = pauseMilliseconds }
    }

    func markPauseBeforeNextSegment(_ milliseconds: Int64) {
        queue.sync { pauseBeforeNextSegment = max(0, milliseconds) }
    }

    private func open(format: AVAudioFormat) throws {
        guard let recordingID, let root else { throw WriterError.copyFailed }
        guard segmentNumber < 512 else { throw WriterError.segmentLimit }
        segmentNumber += 1
        segmentStart = DispatchTime.now().uptimeNanoseconds
        frames = 0
        segmentPauseBefore = pauseBeforeNextSegment
        pauseBeforeNextSegment = 0
        rotationFrameLimit = max(1, Int64(format.sampleRate * 60))
        let url = root.appendingPathComponent(recordingID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(String(format: "%06d.caf", segmentNumber))
        file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    private func closeCurrent() {
        guard let descriptor = releaseCurrentFile() else { return }
        onClosed(descriptor.id, descriptor.number, descriptor.start, descriptor.duration, descriptor.pause, descriptor.frames)
    }

    private func releaseCurrentFile() -> (id: UUID, number: Int, start: Int64, duration: Int64, pause: Int64, frames: Int64)? {
        guard let file, let recordingID else { return nil }
        self.file = nil
        let closedFrames = frames
        let descriptor = (recordingID, segmentNumber, Int64(segmentStart / 1_000_000),
                          Int64(Double(closedFrames) / file.processingFormat.sampleRate * 1_000),
                          segmentPauseBefore, closedFrames)
        return descriptor // the local file reference is released before its caller admits this file.
    }
}

@MainActor
@Observable
final class WatchRecordingCoordinator {
    enum State: Equatable { case idle, preparing, recording, paused, finalizing, interrupted(String), failed(String) }
    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var recent: [WatchRecordingManifest] = []

    private let store: WatchRecordingStore?
    private let engine = AVAudioEngine()
    private var writer: WatchAudioFileWriter!
    private let admissions = SegmentAdmissions()
    private var recordingID: UUID?
    private var pausedAt: UInt64?
    private var timer: Timer?
    private var audioObservers: [NSObjectProtocol] = []

    init() {
        let availableStore = try? WatchRecordingStore()
        store = availableStore
        let admissions = admissions
        writer = WatchAudioFileWriter(onClosed: { [weak store = availableStore] id, number, start, duration, pause, frames in
            guard let store else { return }
            admissions.append(Task {
                try await store.admitClosedSegment(recordingID: id, number: number,
                                                     startedMonotonicMilliseconds: start,
                                                     durationMilliseconds: duration,
                                                     pauseBeforeMilliseconds: pause, frameCount: frames)
            })
        }, onFailure: { [weak self] in
            Task { @MainActor in await self?.failCapture("Watch storage is full or unavailable. Earlier audio remains saved.") }
        })
        if availableStore == nil { state = .failed("Watch storage is unavailable. Free storage and reopen Tron.") }
        observeAudioSessionChanges()
    }

    func load() async {
        guard let store else { state = .failed("Watch storage is unavailable. Free storage and reopen Tron."); return }
        do {
            recent = try await store.inventory()
            for item in recent where item.stoppedAt == nil {
                try await store.recoverUnadmittedSegments(recordingID: item.recordingId)
                try await store.finish(recordingID: item.recordingId, stoppedAt: Date(), recovered: true)
            }
            recent = try await store.inventory()
            for item in recent where item.stoppedAt != nil {
                await WatchRecordingConnectivity.shared.enqueue(item, store: store)
            }
        } catch { state = .failed("Your recordings could not be opened. Free storage and reopen Tron.") }
    }

    func start() async {
        guard state == .idle || isTerminal else { return }
        guard let store else { state = .failed("Watch storage is unavailable. Free storage and reopen Tron."); return }
        state = .preparing
        do {
            let allowed = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard allowed else { state = .failed("Microphone access is needed to record. Enable it in Watch Settings."); return }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
            let id = UUID()
            try await store.begin(id: id, startedAt: Date(), destination: WatchRecordingConnectivity.shared.configuredDestination)
            recordingID = id
            writer.begin(id: id, root: store.root)
            elapsed = 0
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: engine.inputNode.inputFormat(forBus: 0)) { [writer] buffer, _ in writer.append(buffer) }
            engine.prepare()
            try engine.start()
            state = .recording
            startTimer()
        } catch { await failCapture("Recording could not start. Check microphone access and available storage.") }
    }

    func pause() async {
        guard state == .recording else { return }
        engine.pause()
        writer.close()
        do { try await admissions.drain() } catch {
            await failCapture("A completed audio segment could not be saved. Earlier audio is preserved.")
            return
        }
        pausedAt = DispatchTime.now().uptimeNanoseconds
        timer?.invalidate(); timer = nil
        state = .paused
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func resume() async {
        guard state == .paused else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if let pausedAt {
                let milliseconds = Int64((DispatchTime.now().uptimeNanoseconds - pausedAt) / 1_000_000)
                // Fence the writer before callbacks resume; otherwise the first new
                // buffer can open a segment before its preceding pause is recorded.
                writer.markPauseBeforeNextSegment(milliseconds)
                self.pausedAt = nil
            }
            try engine.start()
            state = .recording
            startTimer()
        } catch { await failCapture("Recording was interrupted and could not resume. Your saved audio is preserved.") }
    }

    func stop() async {
        guard state == .recording || state == .paused else { return }
        state = .finalizing
        timer?.invalidate(); timer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        writer.close()
        do {
            try await admissions.drain()
            if let id = recordingID, let store {
                try await store.finish(recordingID: id, stoppedAt: Date())
                recent = try await store.inventory()
                if let manifest = recent.first(where: { $0.recordingId == id }) {
                    await WatchRecordingConnectivity.shared.enqueue(manifest, store: store)
                }
            }
            state = .idle
        } catch { state = .failed("Your recording is on this Watch, but finishing its details failed.") }
    }

    private func observeAudioSessionChanges() {
        let center = NotificationCenter.default
        audioObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.state == .recording else { return }; await self.failCapture("Audio was interrupted. Your completed segments remain saved on Watch.") }
        })
        audioObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.state == .recording else { return }; await self.failCapture("The audio route changed. Your completed segments remain saved on Watch.") }
        })
        audioObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; await self.failCapture("Audio services stopped. Your completed segments remain saved on Watch.") }
        })
    }

    private var isTerminal: Bool { if case .failed = state { return true }; if case .interrupted = state { return true }; return false }
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, self.state == .recording else { return }; self.elapsed += 1 }
        }
    }
    private func failCapture(_ message: String) async {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        writer.close()
        try? await admissions.drain()
        timer?.invalidate(); timer = nil
        if let id = recordingID, let store { try? await store.finish(recordingID: id, stoppedAt: Date(), recovered: true); recent = (try? await store.inventory()) ?? recent }
        state = .interrupted(message)
    }
}
