import Foundation

package struct AppLogRecord: Codable, Equatable, Sendable {
    package let timestamp: String
    package let level: String
    package let event: String
    package let source: String
    package let message: String
    let process: String
    package let requestID: String?
    package let durationMs: Int?
    package let outcome: String?
    package let code: String?
    package let profileID: String?
    package let connectionID: Int?
    package let lifecycleGeneration: Int?
    package let bootId: String?
    package let sequence: Int?

    package init(timestamp: String, level: String, event: String, source: String, message: String, process: String, requestID: String?, durationMs: Int?, outcome: String?, code: String?, profileID: String?, connectionID: Int?, lifecycleGeneration: Int?, bootId: String? = nil, sequence: Int? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.event = event
        self.source = source
        self.message = message
        self.process = process
        self.requestID = requestID
        self.durationMs = durationMs
        self.outcome = outcome
        self.code = code
        self.profileID = profileID
        self.connectionID = connectionID
        self.lifecycleGeneration = lifecycleGeneration
        self.bootId = bootId
        self.sequence = sequence
    }

    func stamped(bootId: String, sequence: Int) -> AppLogRecord {
        AppLogRecord(timestamp: timestamp, level: level, event: event, source: source, message: message, process: process,
            requestID: requestID, durationMs: durationMs, outcome: outcome, code: code, profileID: profileID,
            connectionID: connectionID, lifecycleGeneration: lifecycleGeneration, bootId: bootId, sequence: sequence)
    }
}

package struct AppLogHeldCursor: Equatable, Sendable, Decodable {
    package let bootId: String?
    package let sequence: Int

    package init(bootId: String?, sequence: Int) {
        self.bootId = bootId
        self.sequence = sequence
    }
}

package struct AppLogUploadBatch: Equatable, Sendable {
    package let bootId: String
    package let firstSequence: Int
    package let lines: [String]
    package let gapFrom: Int?
}

private struct AppLogLineMark: Decodable {
    let bootId: String?
    let sequence: Int?
}

package actor AppLog {
    static let maximumRecords = 2_000
    static let maximumBufferBytes = 512 * 1_024
    static let maximumFileBytes = 10 * 1_024 * 1_024
    static let maximumSegmentBytes = maximumFileBytes / 2
    static let flushInterval: Duration = .seconds(5)
    static let slowOperationThresholdMilliseconds = 250
    package static let maximumUploadLines = 256
    package static let maximumUploadBytes = 256 * 1_024
    static let maximumLineBytes = 16 * 1_024
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    package static let shared = AppLog()

    private let fileURL: URL
    private let maximumSegmentBytes: Int
    private var recordSlots = [AppLogRecord?](repeating: nil, count: maximumRecords)
    private var recordStart = 0
    private var recordCount = 0
    private var recordBytes = 0
    private var bufferedRecords: [AppLogRecord] = []
    private var bufferedBytes = 0
    private var epoch = AppLog.newEpoch()
    private var nextSequence = 1
    private var unsentLines: [String] = []
    private var unsentFirstSequence = 1
    private var unsentBytes = 0
    private var flushTask: Task<Void, Never>?
    private var didRestore = false

    init(
        fileURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/app.jsonl"),
        maximumSegmentBytes: Int = AppLog.maximumSegmentBytes
    ) {
        self.fileURL = fileURL
        self.maximumSegmentBytes = max(1, maximumSegmentBytes)
    }

    package func recordCausal(
        name: String, outcome: String? = nil, durationMilliseconds: Int? = nil,
        count: Int? = nil, profileID: String? = nil, connectionID: Int? = nil,
        lifecycleGeneration: Int? = nil, requestID: String? = nil, level: String? = nil,
        details: String? = nil
    ) {
        restoreIfNeeded()
        let slow = (durationMilliseconds ?? 0) >= Self.slowOperationThresholdMilliseconds
        let eventLevel = level ?? (outcome == "failure" ? "error" : slow ? "warning" : "info")
        let fields = [outcome.map { "outcome=\($0)" }, details, count.map { "count=\($0)" }, requestID.map { "requestID=\($0)" }]
            .compactMap { $0 }.joined(separator: " ")
        append(AppLogRecord(
            timestamp: Self.timestampFormatter.string(from: Date()),
            level: eventLevel, event: name, source: "app",
            message: fields, process: "ios", requestID: requestID,
            durationMs: durationMilliseconds, outcome: outcome,
            code: nil, profileID: profileID, connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration
        ))
        if eventLevel == "error" { flush() }
    }

    func recordRPC(
        event: String = "rpc.completed",
        method: String, requestID: String, outcome: String, code: String?,
        durationMilliseconds: Int, profileID: String?, connectionID: Int?
    ) {
        restoreIfNeeded()
        append(AppLogRecord(
            timestamp: Self.timestampFormatter.string(from: Date()),
            level: "debug", event: event, source: "rpc",
            message: method, process: "ios", requestID: bounded(requestID),
            durationMs: max(0, durationMilliseconds), outcome: outcome,
            code: code.map { bounded($0) }, profileID: profileID.map { bounded($0) },
            connectionID: connectionID, lifecycleGeneration: nil
        ))
    }

    package func snapshot() -> [AppLogRecord] {
        restoreIfNeeded()
        return (0..<recordCount).compactMap { recordSlots[(recordStart + $0) % Self.maximumRecords] }
    }

    package func flush() {
        restoreIfNeeded()
        guard !bufferedRecords.isEmpty else { return }
        let records = bufferedRecords
        bufferedRecords.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let currentSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
            var lines = encodedLines(records)
            if currentSize + lines.reduce(0, { $0 + $1.count + 1 }) > maximumSegmentBytes {
                let previousURL = fileURL.appendingPathExtension("1")
                if FileManager.default.fileExists(atPath: previousURL.path) {
                    try FileManager.default.removeItem(at: previousURL)
                }
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.moveItem(at: fileURL, to: previousURL)
                }
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                startEpoch()
                lines = encodedLines(records)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            for line in lines { try handle.write(contentsOf: line + Data([0x0A])) }
            try handle.close()
            nextSequence += lines.count
            for line in lines {
                unsentLines.append(String(decoding: line, as: UTF8.self))
                unsentBytes += line.count
            }
            while unsentLines.count > Self.maximumRecords || unsentBytes > Self.maximumBufferBytes {
                unsentBytes -= unsentLines.removeFirst().utf8.count
                unsentFirstSequence += 1
            }
        } catch {
            bufferedRecords = Array((records + bufferedRecords).suffix(Self.maximumRecords))
            bufferedBytes = bufferedRecords.reduce(0) { $0 + estimatedBytes($1) }
            startEpoch()
        }
    }

    package func uploadBatch(after held: AppLogHeldCursor) -> AppLogUploadBatch? {
        flush()
        if held.bootId == epoch, held.sequence + 1 >= unsentFirstSequence {
            let start = held.sequence + 1 - unsentFirstSequence
            guard start < unsentLines.count else { return nil }
            return Self.batch(bootId: epoch, firstSequence: held.sequence + 1, lines: unsentLines[start...], gapFrom: nil)
        }
        let epochs = fileEpochs()
        if let bootId = held.bootId, let index = epochs.firstIndex(where: { $0.id == bootId }) {
            let pending = Self.contiguous(epochs[index].lines, from: held.sequence + 1)
            if !pending.isEmpty {
                return Self.batch(bootId: bootId, firstSequence: held.sequence + 1, lines: pending[...], gapFrom: nil)
            }
            for next in epochs[(index + 1)...] {
                let lines = Self.contiguous(next.lines, from: 1)
                if !lines.isEmpty { return Self.batch(bootId: next.id, firstSequence: 1, lines: lines[...], gapFrom: nil) }
            }
            return nil
        }
        for next in epochs where next.id != held.bootId {
            let lines = Self.contiguous(next.lines, from: 1)
            if !lines.isEmpty {
                return Self.batch(bootId: next.id, firstSequence: 1, lines: lines[...],
                                  gapFrom: held.bootId == nil ? nil : held.sequence)
            }
        }
        return nil
    }

    private func fileEpochs() -> [(id: String, lines: [Int: String])] {
        var epochs: [(id: String, lines: [Int: String])] = []
        for url in [fileURL.appendingPathExtension("1"), fileURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let mark = try? JSONDecoder().decode(AppLogLineMark.self, from: Data(raw)),
                      let bootId = mark.bootId, let sequence = mark.sequence else { continue }
                if epochs.last?.id != bootId { epochs.append((bootId, [:])) }
                if epochs[epochs.count - 1].lines[sequence] == nil {
                    epochs[epochs.count - 1].lines[sequence] = String(decoding: raw, as: UTF8.self)
                }
            }
        }
        return epochs
    }

    private static func contiguous(_ lines: [Int: String], from first: Int) -> [String] {
        var result: [String] = []
        var sequence = first
        while result.count < maximumUploadLines, let line = lines[sequence] {
            result.append(line)
            sequence += 1
        }
        return result
    }

    private static func batch(bootId: String, firstSequence: Int, lines: ArraySlice<String>, gapFrom: Int?) -> AppLogUploadBatch {
        var kept: [String] = []
        var bytes = 0
        for line in lines.prefix(maximumUploadLines) {
            bytes += line.utf8.count
            if !kept.isEmpty, bytes > maximumUploadBytes { break }
            kept.append(line)
        }
        return AppLogUploadBatch(bootId: bootId, firstSequence: firstSequence, lines: kept, gapFrom: gapFrom)
    }

    private func encodedLines(_ records: [AppLogRecord]) -> [Data] {
        records.enumerated().map { offset, record in
            let stamped = record.stamped(bootId: epoch, sequence: nextSequence + offset)
            if let data = try? JSONEncoder().encode(stamped), data.count <= Self.maximumLineBytes { return data }
            let truncated = AppLogRecord(
                timestamp: String(record.timestamp.prefix(64)), level: record.level, event: "log.record-truncated",
                source: "", message: "", process: "ios", requestID: nil, durationMs: nil, outcome: nil, code: nil,
                profileID: nil, connectionID: nil, lifecycleGeneration: nil, bootId: epoch, sequence: nextSequence + offset
            )
            return (try? JSONEncoder().encode(truncated)) ?? Data()
        }
    }

    private func startEpoch() {
        epoch = Self.newEpoch()
        nextSequence = 1
        unsentLines.removeAll()
        unsentFirstSequence = 1
        unsentBytes = 0
    }

    private static func newEpoch() -> String { UUID().uuidString.lowercased() }

    private func restoreIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        let previousURL = fileURL.appendingPathExtension("1")
        for url in [previousURL, fileURL] {
            for line in readTailLines(from: url) {
                guard let record = try? JSONDecoder().decode(AppLogRecord.self, from: line) else { continue }
                appendToRing(record)
            }
        }
    }

    private func readTailLines(from url: URL) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return [] }
        let offset = end > UInt64(Self.maximumBufferBytes) ? end - UInt64(Self.maximumBufferBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              var data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        if offset > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return [] }
            data = Data(data.suffix(from: data.index(after: newline)))
        }
        return data.split(separator: UInt8(10), omittingEmptySubsequences: true).map { Data($0) }
    }

    private func flushAfterInterval() {
        flushTask = nil
        flush()
    }

    private func append(_ record: AppLogRecord) {
        let level = ["debug", "info", "warning", "error"].contains(record.level) ? record.level : "info"
        let admitted = AppLogRecord(
            timestamp: record.timestamp, level: level,
            event: bounded(IOSClientDiagnosticBuffer.redactedMessage(record.event)),
            source: bounded(IOSClientDiagnosticBuffer.redactedMessage(record.source)),
            message: bounded(IOSClientDiagnosticBuffer.redactedMessage(record.message)), process: "ios",
            requestID: record.requestID.map { bounded(IOSClientDiagnosticBuffer.redactedMessage($0)) },
            durationMs: record.durationMs, outcome: record.outcome.map { bounded($0) },
            code: record.code.map { bounded($0) }, profileID: record.profileID.map { bounded($0) },
            connectionID: record.connectionID, lifecycleGeneration: record.lifecycleGeneration
        )
        appendToRing(admitted)
        if level != "debug" {
            bufferedRecords.append(admitted)
            bufferedBytes += estimatedBytes(admitted)
            if bufferedBytes >= Self.maximumBufferBytes { flush() }
            else if flushTask == nil {
                flushTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.flushInterval)
                    await self?.flushAfterInterval()
                }
            }
        }
    }

    private func appendToRing(_ record: AppLogRecord) {
        let bytes = estimatedBytes(record)
        while recordCount > 0 && (recordCount >= Self.maximumRecords || recordBytes + bytes > Self.maximumBufferBytes) {
            if let evicted = recordSlots[recordStart] { recordBytes -= estimatedBytes(evicted) }
            recordSlots[recordStart] = nil
            recordStart = (recordStart + 1) % Self.maximumRecords
            recordCount -= 1
        }
        let slot = (recordStart + recordCount) % Self.maximumRecords
        recordSlots[slot] = record
        recordCount += 1
        recordBytes += bytes
    }

    private func bounded(_ value: String, limit: Int = 512) -> String {
        String(value.prefix(limit))
    }

    private func estimatedBytes(_ record: AppLogRecord) -> Int {
        record.timestamp.utf8.count + record.event.utf8.count + record.source.utf8.count + record.message.utf8.count + 128
    }
}

package final class AppLogSignposts: PerformanceSignposting, @unchecked Sendable {
    private struct OpenInterval {
        let operation: PerformanceOperation
        let startedAt: ContinuousClock.Instant
    }

    private let base: any PerformanceSignposting
    private let log: AppLog
    private let lock = NSLock()
    private var openIntervals: [Int: OpenInterval] = [:]
    private var backgroundedIntervals: Set<Int> = []
    private var signedAtBackgroundIntervals: Set<Int> = []
    private var nextIntervalID = 1

    package init(base: any PerformanceSignposting, log: AppLog) {
        self.base = base
        self.log = log
    }

    package func begin(_ operation: PerformanceOperation) -> PerformanceInterval {
        let interval = base.begin(operation)
        let startedAt = ContinuousClock().now
        let trackedID = lock.withLock { () -> Int in
            defer { nextIntervalID += 1 }
            openIntervals[nextIntervalID] = OpenInterval(operation: operation, startedAt: startedAt)
            return nextIntervalID
        }
        return PerformanceInterval(operation: operation, state: interval.state,
            measuredStart: startedAt, trackedID: trackedID)
    }

    package func end(_ interval: PerformanceInterval, result: PerformanceResult, metrics: PerformanceMetrics) {
        base.end(interval, result: result, metrics: metrics)
        let disposition = takeTracked(interval)
        guard let started = interval.measuredStart, disposition != .signedAtBackground else { return }
        let duration = diagnosticMilliseconds(started.duration(to: ContinuousClock().now))
        guard duration >= AppLog.slowOperationThresholdMilliseconds else { return }
        let outcome = disposition == .backgrounded ? "backgrounded"
            : (result == .success ? "success" : "failure")
        Task {
            await log.recordCausal(name: "operation.\(interval.operation)",
                outcome: outcome, durationMilliseconds: duration,
                count: metrics.itemCount,
                level: result == .failure && disposition != .backgrounded ? "error" : "warning")
        }
    }

    package func endOpenIntervalsAtBackground() {
        let now = ContinuousClock().now
        let signed = lock.withLock { () -> [OpenInterval] in
            backgroundedIntervals.formUnion(openIntervals.keys)
            var signed: [OpenInterval] = []
            var signedIDs: [Int] = []
            for (id, interval) in openIntervals {
                guard diagnosticMilliseconds(interval.startedAt.duration(to: now))
                    >= AppLog.slowOperationThresholdMilliseconds else { continue }
                signed.append(interval)
                signedIDs.append(id)
            }
            signedAtBackgroundIntervals.formUnion(signedIDs)
            openIntervals.removeAll()
            return signed
        }
        guard !signed.isEmpty else { return }
        for interval in signed {
            let duration = diagnosticMilliseconds(interval.startedAt.duration(to: now))
            Task {
                await log.recordCausal(name: "operation.\(interval.operation)",
                    outcome: "backgrounded", durationMilliseconds: duration, level: "warning")
            }
        }
    }

    private enum IntervalDisposition {
        case owner
        case backgrounded
        case signedAtBackground
    }

    private func takeTracked(_ interval: PerformanceInterval) -> IntervalDisposition {
        guard let id = interval.trackedID else { return .owner }
        return lock.withLock {
            openIntervals.removeValue(forKey: id)
            guard backgroundedIntervals.remove(id) != nil else { return .owner }
            return signedAtBackgroundIntervals.remove(id) != nil ? .signedAtBackground : .backgrounded
        }
    }
}
